import Foundation

struct StudySceneEnrichmentStatus: Decodable, Equatable {
    let pendingCount: Int
    let completedCount: Int
    let failedCount: Int
    let retryAfterSeconds: Int

    var isPending: Bool { pendingCount > 0 }
    var pollingDelay: Int { min(30, max(3, retryAfterSeconds)) }
}

struct StudySceneEnrichmentResponse: Decodable {
    let enrichment: StudySceneEnrichmentStatus
}

struct StudySceneEnrichmentRequest: Encodable {
    let scene_id: String
    let enrichment_status_only = true
}
