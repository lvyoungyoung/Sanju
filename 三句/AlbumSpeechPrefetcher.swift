import Foundation

/// Keeps only the visible album's rolling audio window. A foreground reader can
/// adopt an in-flight stream, including its prefix, without another HTTP request.
@MainActor
final class AlbumSpeechPrefetcher {
    struct Request: Equatable {
        let text: String
        let voice: SpeechVoice
        let owner: String
    }

    typealias Fetch = (Request, @escaping @MainActor (Data) -> Void) async throws -> Data
    typealias AudioStream = AsyncThrowingStream<Data, Error>

    private final class Flight {
        let request: Request
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var audio = Data()
        var playback: AudioStream.Continuation?
        var isCancelled = false

        init(_ request: Request) { self.request = request }
    }

    private let cache: SpeechAudioCache
    private let namespace: String
    private let fetch: Fetch
    private let timeout: Duration
    private var pending: [Request] = []
    private var current: Flight?
    private var isEnabled = false
    private var foregroundBusy = false
    private var cooldownUntil: ContinuousClock.Instant?

    init(cache: SpeechAudioCache, namespace: String, timeout: Duration = .seconds(20), fetch: @escaping Fetch) {
        self.cache = cache
        self.namespace = namespace
        self.timeout = timeout
        self.fetch = fetch
    }

    func updateWindow(currentText: String, upcoming: [String], voice: SpeechVoice, owner: String, enabled: Bool) {
        let currentText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        var requests: [Request] = []
        for text in upcoming.prefix(AlbumFlipDeck.lookaheadCount) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 500, text != currentText else { continue }
            let request = Request(text: text, voice: voice, owner: owner)
            if !requests.contains(request) { requests.append(request) }
        }
        if let flight = current {
            let isVisible = flight.request == Request(text: currentText, voice: voice, owner: owner)
            if !isVisible && !requests.contains(flight.request) { cancel(flight) }
        }
        pending = requests.filter { $0 != current?.request }
        setEnabled(enabled)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled, let flight = current, flight.playback == nil {
            if !pending.contains(flight.request) { pending.insert(flight.request, at: 0) }
            cancel(flight)
        }
        startNextIfNeeded()
    }

    func setForegroundBusy(_ busy: Bool) {
        foregroundBusy = busy
        startNextIfNeeded()
    }

    func takeOver(text: String, voice: SpeechVoice, owner: String) -> AudioStream? {
        guard let flight = current,
              flight.request == Request(text: text, voice: voice, owner: owner),
              flight.playback == nil else { return nil }
        let (stream, continuation) = AudioStream.makeStream()
        flight.playback = continuation
        if !flight.audio.isEmpty { continuation.yield(flight.audio) }
        continuation.onTermination = { [weak self, weak flight] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor [weak self, weak flight] in
                guard let self, let flight, self.current === flight else { return }
                self.cancel(flight)
                self.startNextIfNeeded()
            }
        }
        return stream
    }

    func cancelPlayback() {
        if let flight = current, flight.playback != nil { cancel(flight) }
    }

    func cancelAll() {
        isEnabled = false
        pending.removeAll()
        cooldownUntil = nil
        if let flight = current { cancel(flight) }
    }

    private func cancel(_ flight: Flight, error: Error = CancellationError()) {
        flight.isCancelled = true
        flight.deadline?.cancel()
        flight.task?.cancel()
        flight.playback?.finish(throwing: error)
        if current === flight { current = nil }
    }

    private func startNextIfNeeded() {
        guard isEnabled, !foregroundBusy, current == nil, !pending.isEmpty,
              cooldownUntil.map({ .now >= $0 }) ?? true else { return }
        let flight = Flight(pending.removeFirst())
        current = flight
        flight.deadline = Task { [weak self] in
            do { try await Task.sleep(for: self?.timeout ?? .seconds(20)) } catch { return }
            guard let self, current === flight else { return }
            cooldownUntil = .now.advanced(by: .seconds(60))
            cancel(flight, error: CloudSpeechError.stream(code: "speech_prefetch_timeout"))
        }
        flight.task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                flight.deadline?.cancel()
                if current === flight {
                    current = nil
                    startNextIfNeeded()
                }
            }
            let request = flight.request
            let key = SpeechAudioCache.key(text: request.text, scope: "\(namespace)|\(request.owner)", voice: request.voice)
            do {
                if let cached = await cache.load(key) {
                    try Task.checkCancellation()
                    guard !flight.isCancelled else { return }
                    flight.audio = cached
                    flight.playback?.yield(cached)
                } else {
                    try Task.checkCancellation()
                    let audio = try await fetch(request) { chunk in
                        guard !flight.isCancelled else { return }
                        flight.audio.append(chunk)
                        flight.playback?.yield(chunk)
                    }
                    try Task.checkCancellation()
                    guard !flight.isCancelled else { return }
                    guard !audio.isEmpty, audio.count.isMultiple(of: 2),
                          audio.count <= SpeechAudioStream.maximumBytes else { throw CloudSpeechError.invalidAudio }
                    await cache.save(audio, key: key)
                    try Task.checkCancellation()
#if DEBUG
                    print("[SpeechFlow] Album lookahead audio cached; voice=\(request.voice.rawValue)")
#endif
                }
                flight.playback?.finish()
            } catch {
                flight.playback?.finish(throwing: error)
                guard !flight.isCancelled else { return }
                // Swiping repeatedly must not exhaust the speech budget during an outage.
                cooldownUntil = .now.advanced(by: .seconds(60))
#if DEBUG
                print("[SpeechFlow] Album prefetch paused; manual playback remains available: \(error.localizedDescription)")
#endif
            }
        }
    }
}
