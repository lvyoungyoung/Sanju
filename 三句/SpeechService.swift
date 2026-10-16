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
    var accountRevisionProvider: (() -> Int)?
    @Published private(set) var playbackError: CloudSpeechError?
    @Published private(set) var playbackErrorRequest: SpeechRequest?

    private let synthesizer = AVSpeechSynthesizer()
    private let audioSession = SpeechAudioSession()
    private let cloud = CloudSpeechClient()
    private let cache: SpeechAudioCache
    private let albumFetchOverride: AlbumSpeechPrefetcher.Fetch?
    private var albumPrefetchID: UUID?
    private var albumPrefetchWindow: (current: String, upcoming: [String], enabled: Bool)?
    private var requestPrefetchWindow: (current: SpeechRequest?, upcoming: [SpeechRequest], enabled: Bool)?
    private lazy var albumPrefetcher = AlbumSpeechPrefetcher(cache: cache, namespace: cloud.cacheNamespace) { [weak self] request, onAudio in
        guard let self else { throw CancellationError() }
        guard isCurrent(request.speech) else { throw CancellationError() }
        if let albumFetchOverride {
            let audio = try await albumFetchOverride(request) { chunk in
                guard self.isCurrent(request.speech) else { return }
                onAudio(chunk)
            }
            guard isCurrent(request.speech) else { throw CancellationError() }
            return audio
        }
        guard isCurrent(request.speech), let sessionProvider else { throw CloudSpeechError.noSession }
        let auth = try await sessionProvider()
        try Task.checkCancellation()
        guard auth.userID == request.owner, isCurrent(request.speech) else { throw CancellationError() }
        let receiveAudio: (Data) async throws -> Void = { chunk in
            try Task.checkCancellation()
            guard self.isCurrent(request.speech) else { throw CancellationError() }
            onAudio(chunk)
        }
        let audio = try await request.usesLegacyAPI
            ? cloud.stream(text: request.text, voice: request.voice, auth: auth, onAudio: receiveAudio)
            : cloud.stream(request: request.speech, auth: auth, onAudio: receiveAudio)
        guard isCurrent(request.speech) else { throw CancellationError() }
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
    @Published private(set) var activeRequest: SpeechRequest?
    @Published private(set) var sequenceRequests: [SpeechRequest] = []
    private var sequenceID = UUID()
    private var sequenceIndex = 0
    private var sequenceGapTask: Task<Void, Never>?
    private var pendingBytes = Data()
    private var scheduledBuffers = 0
    private var hasScheduledCloudAudio = false
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
        requestPrefetchWindow = nil
        albumPrefetchWindow = (current, upcoming, enabled)
        refreshAlbumSpeechPrefetch()
    }

    func updateAlbumSpeechPrefetch(id: UUID, current: SpeechRequest?, upcoming: [SpeechRequest], enabled: Bool) {
        guard albumPrefetchID == id else { return }
        albumPrefetchWindow = nil
        requestPrefetchWindow = (current, upcoming, enabled)
        refreshAlbumSpeechPrefetch()
    }

    func accountDidChange() {
        stop()
        playbackError = nil
        playbackErrorRequest = nil
        cancelAlbumSpeechPrefetch()
    }

    func dismissPlaybackError() { playbackError = nil; playbackErrorRequest = nil }

    private func isCurrent(_ request: SpeechRequest) -> Bool {
        (ownerProvider?() ?? "local") == request.owner &&
            (accountRevisionProvider?() ?? 0) == request.accountRevision
    }

    func prioritizeAlbumCurrentSentence(id: UUID) {
        guard albumPrefetchID == id else { return }
        albumPrefetcher.setForegroundBusy(true)
    }

    func pauseAlbumSpeechPrefetch(id: UUID) {
        guard albumPrefetchID == id else { return }
        albumPrefetchWindow?.enabled = false
        requestPrefetchWindow?.enabled = false
        albumPrefetcher.setEnabled(false)
    }

    func endAlbumSpeechPrefetch(id: UUID) {
        guard albumPrefetchID == id else { return }
        cancelAlbumSpeechPrefetch()
    }

    func cancelAlbumSpeechPrefetch() {
        albumPrefetchID = nil
        albumPrefetchWindow = nil
        requestPrefetchWindow = nil
        albumPrefetcher.cancelAll()
    }

    private func refreshAlbumSpeechPrefetch() {
        if albumPrefetchID != nil, let window = requestPrefetchWindow {
            albumPrefetcher.updateWindow(current: window.current.flatMap { isCurrent($0) ? $0 : nil },
                upcoming: window.upcoming.filter { isCurrent($0) }, enabled: window.enabled)
            return
        }
        guard albumPrefetchID != nil, let window = albumPrefetchWindow, let owner = ownerProvider?() else { return }
        albumPrefetcher.updateWindow(currentText: window.current, upcoming: window.upcoming,
                                    voice: selectedVoice, owner: owner, enabled: window.enabled,
                                    accountRevision: accountRevisionProvider?() ?? 0)
    }

    func setVoice(_ voice: SpeechVoice) {
        guard voice != selectedVoice else { return }
        if !sequenceRequests.isEmpty { stop() }
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
        if let window = requestPrefetchWindow {
            func updated(_ request: SpeechRequest) -> SpeechRequest {
                guard request.language == .english else { return request }
                return .english(request.text, voice: voice, owner: request.owner, accountRevision: request.accountRevision)
            }
            requestPrefetchWindow = (window.current.map(updated), window.upcoming.map(updated), window.enabled)
        }
        refreshAlbumSpeechPrefetch()
    }

    func preview(_ voice: SpeechVoice) {
        stop()
        activeText = SpeechPreferences.previewText
        activeVoice = voice
        loadingText = SpeechPreferences.previewText
        loadingVoice = voice
        isUsingSystemVoice = false
        let id = requestID
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestID == id {
                    loadingText = nil
                    loadingVoice = nil
                    requestTask = nil
                }
            }
            do {
                let audio = try await Task.detached(priority: .userInitiated) {
                    try SpeechPreviewAudio.load(voice)
                }.value
                try Task.checkCancellation()
                guard requestID == id else { return }
                try await play(audio, id: id)
                finishSource()
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                // A system voice would misrepresent the selected preview voice.
                stop()
#if DEBUG
                print("[SpeechFlow] Bundled voice preview unavailable: \(error.localizedDescription)")
#endif
            }
        }
    }

    func speak(_ text: String, voice overrideVoice: SpeechVoice? = nil) {
        cancelSequence()
        speak(.english(text, voice: overrideVoice ?? selectedVoice, owner: ownerProvider?() ?? "local",
                       accountRevision: accountRevisionProvider?() ?? 0), usesLegacyAPI: true)
    }

    func speak(_ request: SpeechRequest) {
        cancelSequence()
        speak(request, usesLegacyAPI: false)
    }

    func speakSequence(_ requests: [SpeechRequest]) {
        stop()
        guard !requests.isEmpty else { return }
        guard requests.allSatisfy({ isCurrent($0) }) else { accountDidChange(); return }
        if let invalid = requests.first(where: { !$0.isValid }) {
            playbackErrorRequest = invalid
            playbackError = .descriptorMismatch
            return
        }
        sequenceRequests = requests
        speak(requests[0], usesLegacyAPI: false)
    }

    private func cancelSequence() {
        sequenceID = UUID()
        sequenceGapTask?.cancel()
        sequenceGapTask = nil
        sequenceIndex = 0
        if !sequenceRequests.isEmpty { sequenceRequests = [] }
    }

    private func advanceSequence(after completed: SpeechRequest?) {
        guard sequenceRequests.indices.contains(sequenceIndex),
              completed == sequenceRequests[sequenceIndex], sequenceGapTask == nil else { return }
        guard sequenceRequests.allSatisfy({ isCurrent($0) }) else { accountDidChange(); return }
        guard sequenceIndex + 1 < sequenceRequests.count else { cancelSequence(); return }
        let id = sequenceID
        let playbackID = requestID
        // Keep the full sequence published during the natural pause between turns.
        sequenceGapTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled, sequenceID == id, requestID == playbackID else { return }
            sequenceGapTask = nil
            guard sequenceRequests.allSatisfy({ isCurrent($0) }) else { accountDidChange(); return }
            sequenceIndex += 1
            speak(sequenceRequests[sequenceIndex], usesLegacyAPI: false)
        }
    }

    func request(sentence: SentenceRecord, context: MemoryContentContext) -> SpeechRequest {
        request(text: sentence.targetText, context: context)
    }

    func request(text: String, context: MemoryContentContext) -> SpeechRequest {
        SpeechRequest(text: text, language: context.targetLanguage, teachingLocale: context.teachingLocale,
                      owner: ownerProvider?() ?? "local", accountRevision: accountRevisionProvider?() ?? 0,
                      descriptor: context.targetLanguage == .english ? .english(selectedVoice) : nil)
    }

    private func speak(_ request: SpeechRequest, usesLegacyAPI: Bool) {
        guard request.isValid else {
            stop(); playbackErrorRequest = request; playbackError = .descriptorMismatch; return
        }
        guard isCurrent(request) else { accountDidChange(); return }
        let text = request.text
        let voice = request.descriptor.legacyVoice
        if activeRequest == request, requestTask != nil { return }
        stopPlayback()
        activeRequest = request
        playbackError = nil
        playbackErrorRequest = nil
        albumPrefetcher.setForegroundBusy(true)
        activeText = text
        activeVoice = voice
        loadingText = text
        loadingVoice = voice
        isUsingSystemVoice = false
        let id = requestID
        let key = SpeechAudioCache.key(request: request, environment: cloud.cacheNamespace)
        let prefetchedStream = albumPrefetcher.takeOver(request: request)
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
                if let audio = await cache.load(request: request, environment: cloud.cacheNamespace) {
                    try Task.checkCancellation()
                    guard requestID == id, isCurrent(request) else { return }
                    try await play(audio, id: id)
                    finishSource()
#if DEBUG
                    print("[SpeechFlow] Playing cached MiMo audio")
#endif
                    return
                }
                // A cache miss also suspends; cancellation may have replaced this playback.
                try Task.checkCancellation()
                guard requestID == id, isCurrent(request) else { return }
                if let prefetchedStream {
                    for try await chunk in prefetchedStream {
                        try Task.checkCancellation()
                        guard requestID == id, isCurrent(request) else { return }
                        try await play(chunk, id: id)
                        loadingText = nil
                        loadingVoice = nil
                    }
                    try Task.checkCancellation()
                    guard requestID == id, isCurrent(request) else { return }
                    finishSource()
#if DEBUG
                    print("[SpeechFlow] Playback adopted album lookahead request")
#endif
                    return
                }
                guard let sessionProvider else { throw CloudSpeechError.noSession }
                let auth = try await sessionProvider()
                try Task.checkCancellation()
                guard requestID == id, isCurrent(request), auth.userID == request.owner else { return }
                var receivedAudio = false
                let onAudio: (Data) async throws -> Void = { [weak self] chunk in
                    try Task.checkCancellation()
                    guard let self, self.requestID == id, self.isCurrent(request) else { throw CancellationError() }
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
                let audio = try await usesLegacyAPI
                    ? cloud.stream(text: text, voice: voice ?? .mia, auth: auth, onAudio: onAudio)
                    : cloud.stream(request: request, auth: auth, onAudio: onAudio)
                try Task.checkCancellation()
                guard requestID == id, isCurrent(request) else { return }
                finishSource()
                deadlineTask?.cancel()
                await cache.save(audio, key: key)
            } catch {
                guard !Task.isCancelled, requestID == id, isCurrent(request) else { return }
                if !sequenceRequests.isEmpty, error is CancellationError { stop(); return }
#if DEBUG
                print("[SpeechFlow] Cloud unavailable; using system voice: \(error.localizedDescription)")
#endif
                playSystemSpeech(request)
            }
        }
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(18)) } catch { return }
            guard let self, self.requestID == id, self.isCurrent(request) else { return }
            self.stopPlayback()
            self.playSystemSpeech(request)
        }
    }

    func stop() {
        cancelSequence()
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
        hasScheduledCloudAudio = false
        sourceCompleted = false
        activeText = nil
        activeVoice = nil
        activeRequest = nil
        loadingText = nil
        loadingVoice = nil
        isUsingSystemVoice = false
        deactivateAudioSession()
    }

    private func play(_ chunk: Data, id: UUID) async throws {
        if let activeRequest, !isCurrent(activeRequest) { accountDidChange(); throw CancellationError() }
        if !engine.isRunning {
            try await audioSession.activate()
            try Task.checkCancellation()
            guard requestID == id else { throw CancellationError() }
            if let activeRequest, !isCurrent(activeRequest) { accountDidChange(); throw CancellationError() }
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
        hasScheduledCloudAudio = true
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
        if !sequenceRequests.isEmpty, !hasScheduledCloudAudio || !pendingBytes.isEmpty {
            playbackErrorRequest = activeRequest
            playbackError = .invalidAudio
            stop()
            return
        }
        sourceCompleted = false
        let completed = activeRequest
        player.stop()
        engine.stop()
        activeText = nil
        activeRequest = nil
        deactivateAudioSession()
        advanceSequence(after: completed)
    }

    private func playSystemSpeech(_ request: SpeechRequest) {
        guard isCurrent(request) else { accountDidChange(); return }
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
        activeText = request.text
        activeRequest = request
        player.stop()
        engine.stop()
        scheduledBuffers = 0
        hasScheduledCloudAudio = false
        sourceCompleted = false
        pendingBytes.removeAll()
        let id = requestID
        fallbackTask = Task { [weak self] in
            guard let self else { return }
            do { try await audioSession.activate() }
            catch {
#if DEBUG
                print("[SpeechFlow] System voice audio activation failed: \(error.localizedDescription)")
#endif
                guard !Task.isCancelled, requestID == id else { return }
                if !sequenceRequests.isEmpty {
                    playbackErrorRequest = request
                    playbackError = .invalidAudio
                    stop()
                    return
                }
            }
            guard !Task.isCancelled, requestID == id else { return }
            guard isCurrent(request) else { accountDidChange(); return }
            speakWithSystemVoice(request)
            fallbackTask = nil
        }
    }

    private func speakWithSystemVoice(_ request: SpeechRequest) {
        guard let voice = preferredVoice(for: request) else {
            playbackErrorRequest = request
            playbackError = .noMatchingSystemVoice
            stop()
            isUsingSystemVoice = false
            return
        }
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = voice
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

    private func preferredVoice(for request: SpeechRequest) -> AVSpeechSynthesisVoice? {
        if request.language.rawValue != "en" {
            let available = AVSpeechSynthesisVoice.speechVoices()
            guard let locale = request.preferredSystemLocale(available: available.map(\.language)) else { return nil }
            return available.first { $0.language == locale }
        }
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

        guard let voice = AVSpeechSynthesisVoice(language: "en-US"), voice.language == "en-US" else { return nil }
        return voice
    }

}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishSystemSpeech(utterance, completed: true)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishSystemSpeech(utterance, completed: false)
    }

    private nonisolated func finishSystemSpeech(_ utterance: AVSpeechUtterance, completed: Bool) {
        let completedID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.systemUtterance.map(ObjectIdentifier.init) == completedID else { return }
            guard completed else { self.stop(); return }
            let request = self.activeRequest
            self.systemUtterance = nil
            self.activeText = nil
            self.activeRequest = nil
            self.deactivateAudioSession()
            self.advanceSequence(after: request)
        }
    }
}
