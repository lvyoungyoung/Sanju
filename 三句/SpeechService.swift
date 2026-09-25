import AVFoundation
import Combine
import Foundation

@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var loadingText: String?
    @Published private(set) var loadingVoice: SpeechVoice?
    @Published private(set) var selectedVoice: SpeechVoice
    @Published var preferenceSyncStatus: SpeechPreferenceSyncStatus = .local
    var onVoiceSelection: ((SpeechVoice) -> Void)?
    @Published private(set) var isUsingSystemVoice = false
    var sessionProvider: (() async throws -> SupabaseSession)?
    var ownerProvider: (() -> String)?

    private let synthesizer = AVSpeechSynthesizer()
    private let audioSession = SpeechAudioSession()
    private let cloud = CloudSpeechClient()
    private let cache: SpeechAudioCache
    private let albumFetchOverride: AlbumSpeechPrefetcher.Fetch?
    private var albumPrefetchID: UUID?
    private var albumPrefetchWindow: (current: String, upcoming: [String], enabled: Bool)?
    private lazy var albumPrefetcher = AlbumSpeechPrefetcher(cache: cache, namespace: cloud.cacheNamespace) { [weak self] request, onAudio in
        guard let self else { throw CancellationError() }
        if let albumFetchOverride { return try await albumFetchOverride(request, onAudio) }
        guard ownerProvider?() == request.owner, let sessionProvider else { throw CloudSpeechError.noSession }
        let auth = try await sessionProvider()
        try Task.checkCancellation()
        guard auth.userID == request.owner, ownerProvider?() == request.owner else { throw CancellationError() }
        let audio = try await cloud.stream(text: request.text, voice: request.voice, auth: auth) { chunk in
            try Task.checkCancellation()
            guard self.ownerProvider?() == request.owner else { throw CancellationError() }
            onAudio(chunk)
        }
        guard ownerProvider?() == request.owner else { throw CancellationError() }
        return audio
    }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let defaults: UserDefaults
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var requestTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var requestID = UUID()
    @Published private(set) var activeText: String?
    private var activeVoice: SpeechVoice?
    private var pendingBytes = Data()
    private var scheduledBuffers = 0
    private var sourceCompleted = false
    private var systemUtterance: AVSpeechUtterance?

    init(defaults: UserDefaults = .standard, cache: SpeechAudioCache = SpeechAudioCache(),
         albumPrefetchFetch: AlbumSpeechPrefetcher.Fetch? = nil) {
        self.defaults = defaults
        self.cache = cache
        self.albumFetchOverride = albumPrefetchFetch
        let preferences = SpeechPreferences(defaults: defaults)
        selectedVoice = preferences.voice
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
    }

    func beginAlbumSpeechPrefetch() -> UUID {
        cancelAlbumSpeechPrefetch()
        let id = UUID()
        albumPrefetchID = id
        return id
    }

    func updateAlbumSpeechPrefetch(id: UUID, current: String, upcoming: [String], enabled: Bool) {
        guard albumPrefetchID == id else { return }
        albumPrefetchWindow = (current, upcoming, enabled)
        refreshAlbumSpeechPrefetch()
    }

    func prioritizeAlbumCurrentSentence(id: UUID) {
        guard albumPrefetchID == id else { return }
        albumPrefetcher.setForegroundBusy(true)
    }

    func pauseAlbumSpeechPrefetch(id: UUID) {
        guard albumPrefetchID == id else { return }
        albumPrefetchWindow?.enabled = false
        albumPrefetcher.setEnabled(false)
    }

    func endAlbumSpeechPrefetch(id: UUID) {
        guard albumPrefetchID == id else { return }
        cancelAlbumSpeechPrefetch()
    }

    func cancelAlbumSpeechPrefetch() {
        albumPrefetchID = nil
        albumPrefetchWindow = nil
        albumPrefetcher.cancelAll()
    }

    private func refreshAlbumSpeechPrefetch() {
        guard albumPrefetchID != nil, let window = albumPrefetchWindow, let owner = ownerProvider?() else { return }
        albumPrefetcher.updateWindow(currentText: window.current, upcoming: window.upcoming,
                                    voice: selectedVoice, owner: owner, enabled: window.enabled)
    }

    func setVoice(_ voice: SpeechVoice) {
        guard voice != selectedVoice else { return }
        if let onVoiceSelection {
            onVoiceSelection(voice)
        } else {
            applyVoice(voice)
            defaults.set(voice.rawValue, forKey: SpeechPreferenceKey.voice)
        }
    }

    func applyVoice(_ voice: SpeechVoice) {
        guard voice != selectedVoice else { return }
        albumPrefetcher.cancelAll()
        stop()
        selectedVoice = voice
        refreshAlbumSpeechPrefetch()
    }

    func preview(_ voice: SpeechVoice) {
        speak(SpeechPreferences.previewText, voice: voice)
    }

    func speak(_ text: String, voice overrideVoice: SpeechVoice? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = overrideVoice ?? selectedVoice
        guard !text.isEmpty else { return }
        if activeText == text, activeVoice == voice, requestTask != nil { return }
        stopPlayback()
        albumPrefetcher.setForegroundBusy(true)
        activeText = text
        activeVoice = voice
        loadingText = text
        loadingVoice = voice
        isUsingSystemVoice = false
        let id = requestID
        let owner = ownerProvider?() ?? "local"
        let key = cacheKey(text: text, owner: owner, voice: voice)
        let prefetchedStream = albumPrefetcher.takeOver(text: text, voice: voice, owner: owner)
        let startedAt = Date()
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestID == id {
                    loadingText = nil
                    loadingVoice = nil
                    requestTask = nil
                    deadlineTask?.cancel()
                    deadlineTask = nil
                    albumPrefetcher.setForegroundBusy(false)
                }
            }
            do {
                if let audio = await cache.load(key) {
                    try Task.checkCancellation()
                    guard requestID == id else { return }
                    try await play(audio, id: id)
                    finishSource()
#if DEBUG
                    print("[SpeechFlow] Playing cached MiMo audio")
#endif
                    return
                }
                if let prefetchedStream {
                    for try await chunk in prefetchedStream {
                        try Task.checkCancellation()
                        guard requestID == id else { return }
                        try await play(chunk, id: id)
                        loadingText = nil
                        loadingVoice = nil
                    }
                    try Task.checkCancellation()
                    guard requestID == id else { return }
                    finishSource()
#if DEBUG
                    print("[SpeechFlow] Playback adopted album lookahead request")
#endif
                    return
                }
                guard let sessionProvider else { throw CloudSpeechError.noSession }
                let auth = try await sessionProvider()
                try Task.checkCancellation()
                guard requestID == id else { return }
                var receivedAudio = false
                let audio = try await cloud.stream(text: text, voice: voice, auth: auth) { [weak self] chunk in
                    try Task.checkCancellation()
                    guard let self, self.requestID == id else { throw CancellationError() }
                    try await self.play(chunk, id: id)
                    if !receivedAudio {
                        receivedAudio = true
#if DEBUG
                        print("[SpeechFlow] MiMo first audio: \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
#endif
                    }
                    self.loadingText = nil
                    self.loadingVoice = nil
                }
                try Task.checkCancellation()
                guard requestID == id else { return }
                finishSource()
                deadlineTask?.cancel()
                await cache.save(audio, key: cacheKey(text: text, owner: auth.userID, voice: voice))
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
#if DEBUG
                print("[SpeechFlow] Cloud unavailable; using system voice: \(error.localizedDescription)")
#endif
                playSystemSpeech(text)
            }
        }
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(18)) } catch { return }
            guard let self, self.requestID == id else { return }
            self.stopPlayback()
            self.playSystemSpeech(text)
        }
    }

    func stop() {
        stopPlayback()
        albumPrefetcher.setForegroundBusy(false)
    }

    private func stopPlayback() {
        requestID = UUID()
        albumPrefetcher.cancelPlayback()
        requestTask?.cancel()
        requestTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        player.stop()
        engine.stop()
        systemUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        pendingBytes.removeAll()
        scheduledBuffers = 0
        sourceCompleted = false
        activeText = nil
        activeVoice = nil
        loadingText = nil
        loadingVoice = nil
        deactivateAudioSession()
    }

    private func cacheKey(text: String, owner: String, voice: SpeechVoice) -> String {
        SpeechAudioCache.key(text: text, scope: "\(cloud.cacheNamespace)|\(owner)", voice: voice)
    }

    private func play(_ chunk: Data, id: UUID) async throws {
        if !engine.isRunning {
            try await audioSession.activate()
            try Task.checkCancellation()
            guard requestID == id else { throw CancellationError() }
        }
        pendingBytes.append(chunk)
        let frames = pendingBytes.count / 2
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { throw CloudSpeechError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(frames)
        pendingBytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in 0..<frames {
                let bits = UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
                samples[index] = Float(Int16(bitPattern: bits)) / 32768
            }
        }
        pendingBytes = Data(pendingBytes.suffix(pendingBytes.count % 2))
        if !engine.isRunning {
            try engine.start()
        }
        scheduledBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == id else { return }
                self.scheduledBuffers -= 1
                self.releaseCloudAudioIfFinished()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func finishSource() {
        sourceCompleted = true
        releaseCloudAudioIfFinished()
    }

    private func releaseCloudAudioIfFinished() {
        guard sourceCompleted, scheduledBuffers == 0 else { return }
        player.stop()
        engine.stop()
        activeText = nil
        deactivateAudioSession()
    }

    private func playSystemSpeech(_ text: String) {
        // Invalidate callbacks for partial cloud audio before starting the fallback.
        albumPrefetcher.cancelPlayback()
        albumPrefetcher.setForegroundBusy(false)
        requestID = UUID()
        requestTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        loadingText = nil
        loadingVoice = nil
        isUsingSystemVoice = true
        activeText = text
        player.stop()
        engine.stop()
        scheduledBuffers = 0
        pendingBytes.removeAll()
        let id = requestID
        fallbackTask = Task { [weak self] in
            guard let self else { return }
            do { try await audioSession.activate() }
            catch {
#if DEBUG
                print("[SpeechFlow] System voice audio activation failed: \(error.localizedDescription)")
#endif
            }
            guard !Task.isCancelled, requestID == id else { return }
            speakWithSystemVoice(text)
            fallbackTask = nil
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice()
        utterance.rate = 0.42
        utterance.pitchMultiplier = 1.02
        utterance.volume = 1
        utterance.prefersAssistiveTechnologySettings = true
        utterance.preUtteranceDelay = 0.02
        utterance.postUtteranceDelay = 0.08
        systemUtterance = utterance
        synthesizer.speak(utterance)
    }

    @objc nonisolated private func audioInterrupted(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              type == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor [weak self] in self?.stop() }
    }

    private func deactivateAudioSession() {
        audioSession.deactivate()
    }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let preferredIdentifiers = [
            "com.apple.voice.enhanced.en-US.Samantha",
            "com.apple.voice.enhanced.en-US.Alex",
            "com.apple.voice.compact.en-US.Samantha"
        ]

        for identifier in preferredIdentifiers {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                return voice
            }
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishSystemSpeech(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishSystemSpeech(utterance)
    }

    private nonisolated func finishSystemSpeech(_ utterance: AVSpeechUtterance) {
        let completedID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.systemUtterance.map(ObjectIdentifier.init) == completedID else { return }
            self.systemUtterance = nil
            self.activeText = nil
            self.deactivateAudioSession()
        }
    }
}
