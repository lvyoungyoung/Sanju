import Foundation
import UIKit

struct GenerationEnrichmentSnapshot: Decodable {
    let status: String
    let attempt: Int
    let report: Report?

    struct Report: Decodable {
        let version: Int
        let stages: [Stage]
    }

    struct Stage: Decodable {
        let stage: String
        let outcome: String
        let ms: Double
    }
}

enum GenerationEnrichmentTiming {
    static func isStagingURL(_ value: String?) -> Bool {
        guard let value, let url = URL(string: value), url.scheme == "https",
              let host = url.host else { return false }
        return ["api-staging.sanju.cc", "spb-bp1364k407p37qn7.supabase.opentrust.net"].contains(host)
    }

    static func lines(for snapshot: GenerationEnrichmentSnapshot) -> [String] {
        guard let report = snapshot.report, report.version == 1, report.stages.count <= 32,
              snapshot.attempt > 0, snapshot.attempt <= 100_000 else { return [] }
        let stages: Set<String> = ["claim", "metadata_generate", "metadata_reuse", "metadata_checkpoint",
                                   "sentence_embedding", "purpose_embedding", "embeddings_parallel",
                                   "publish_and_match", "retry_state", "job_total"]
        let outcomes: Set<String> = ["success", "completed", "failed", "lease_lost"]
        var seen = Set<String>()
        return report.stages.compactMap { stage in
            guard stages.contains(stage.stage), outcomes.contains(stage.outcome), seen.insert(stage.stage).inserted,
                  stage.ms.isFinite, stage.ms >= 0, stage.ms <= 3_600_000 else { return nil }
            let duration = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), stage.ms)
            return "background.\(stage.stage) ms=\(duration) outcome=\(stage.outcome) attempt=\(snapshot.attempt)"
        }
    }

    @MainActor
    static func observe(
        isActive: () -> Bool,
        fetchSnapshot: () async throws -> GenerationEnrichmentSnapshot?,
        output: (String) -> Void,
        wait: () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
        budget: Duration = .seconds(90)
    ) async {
        let deadline = ContinuousClock.now + budget
        while !Task.isCancelled, isActive(), ContinuousClock.now < deadline {
            do {
                let snapshot = try await fetchSnapshot()
                guard !Task.isCancelled, isActive() else { return }
                if let snapshot, snapshot.report != nil {
                    let lines = lines(for: snapshot)
                    if lines.isEmpty { output("background.timings_unavailable (invalid diagnostic report)") }
                    else { lines.forEach(output) }
                    return
                }
                try await wait()
            } catch {
                guard !Task.isCancelled, isActive(), !(error is CancellationError),
                      (error as? URLError)?.code != .cancelled else { return }
                output("background.timings_unavailable (check staging migration, function deployment and network)")
                return
            }
        }
        if !Task.isCancelled, isActive() {
            output("background.observation_timeout (diagnostics only; generation and background work are not cancelled)")
        }
    }
}

extension AppModel {
    func observeGeneratedSentenceEnrichment(session: SupabaseSession, memoryID: UUID, guestJobID: String?, requestID: String) {
        #if DEBUG && STAGING
        guard GenerationEnrichmentTiming.isStagingURL(Bundle.main.supabaseURL) else { return }
        let service = supabaseService
        Task { [weak self] in
            await GenerationEnrichmentTiming.observe(
                isActive: { [weak self] in
                    guard let self else { return false }
                    return self.supabaseSession?.accessToken == session.accessToken
                        && self.supabaseSession?.userID == session.userID
                        && UIApplication.shared.applicationState == .active
                },
                fetchSnapshot: {
                    try await service.fetchGenerationEnrichmentTiming(
                        session: session,
                        memoryID: session.isAnonymous ? nil : memoryID,
                        guestJobID: session.isAnonymous ? guestJobID : nil
                    )
                },
                output: { GenerationTiming.log(requestID: requestID, $0) }
            )
        }
        #endif
    }
}
