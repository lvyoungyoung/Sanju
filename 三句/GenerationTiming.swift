import Foundation

/// Debug-only output. The timer carries no photos, sentence text or account identifiers.
@MainActor
final class GenerationTiming {
    let requestID: String
    private let startedAt = ContinuousClock.now
    private var stageStartedAt = ContinuousClock.now
    private var stage = "client_checks"

    // This value-only timer needs no executor-bound cleanup on synchronous release.
    nonisolated deinit {}

    init(requestID: String = UUID().uuidString.lowercased()) {
        self.requestID = requestID
        Self.log(requestID: requestID, "BEGIN")
    }

    func start(_ nextStage: String) {
        let now = ContinuousClock.now
        Self.log(requestID: requestID, "\(stage) ms=\(Self.milliseconds(stageStartedAt.duration(to: now)))")
        stage = nextStage
        stageStartedAt = now
        Self.log(requestID: requestID, "START \(nextStage)")
    }

    func finish(outcome: String) {
        let now = ContinuousClock.now
        Self.log(requestID: requestID, "\(stage) ms=\(Self.milliseconds(stageStartedAt.duration(to: now)))")
        Self.log(requestID: requestID, "END outcome=\(outcome) client_total_ms=\(Self.milliseconds(startedAt.duration(to: now)))")
    }

    static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), max(0, value))
    }

    static func log(requestID: String, _ message: String) {
        #if DEBUG
        print("[GenerationTiming] request=\(requestID) \(message)")
        #endif
    }

    static let serverStages: Set<String> = [
        "setup", "auth", "profile", "request_decode", "existing_result", "concurrency_slot",
        "job_claim", "guest_image_upload", "moderation", "prompt", "mimo", "kimi",
        "model_result", "result_prepare", "image_upload", "finalize", "diagnostics",
        "read_result", "error_handling", "release_slot", "background_dispatch", "total"
    ]

    // Allowlist and validate metadata before printing anything received over the network.
    static func serverDurations(_ value: String) -> [(stage: String, milliseconds: Double)] {
        guard value.utf8.count <= 8_192 else { return [] }
        var seen = Set<String>()
        return value.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, serverStages.contains(name), !seen.contains(name),
                  let parameter = parts.dropFirst().first(where: { $0.hasPrefix("dur=") }),
                  let duration = Double(parameter.dropFirst(4)), duration.isFinite,
                  duration >= 0, duration <= 3_600_000 else { return nil }
            seen.insert(name)
            return (name, duration)
        }
    }

    static func logResponse(_ response: URLResponse, requestID: String, elapsed: Duration) {
        #if DEBUG
        let http = response as? HTTPURLResponse
        log(requestID: requestID, "http_round_trip ms=\(milliseconds(elapsed)) status=\(http?.statusCode ?? 0)")
        let stages = serverDurations(http?.value(forHTTPHeaderField: "Server-Timing") ?? "")
        guard http?.value(forHTTPHeaderField: "X-Sanju-Generation-Timing") == "1", !stages.isEmpty else {
            log(requestID: requestID, "server_timings_unavailable (check deployed generate-memory-v2 and proxy headers)")
            return
        }
        for item in stages {
            let duration = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), item.milliseconds)
            log(requestID: requestID, "server.\(item.stage) ms=\(duration)")
        }
        #endif
    }
}
