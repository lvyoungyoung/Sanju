import Foundation

struct StudySceneMatchSettings: Decodable, Equatable {
    let sceneID: UUID
    let threshold: Double
    let canAdjust: Bool
    let matchedCount: Int
    var needsPreparation: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case sceneID = "scene_id"
        case threshold
        case canAdjust = "can_adjust"
        case matchedCount = "matched_count"
        case needsPreparation = "needs_preparation"
    }
}

enum StudyMatchRange {
    // Left is stricter; right includes more related sentences.
    static let thresholds: [Double] = [0.48, 0.46, 0.44, 0.42, 0.40, 0.38, 0.36]
    static let defaultIndex = 3

    static func index(for threshold: Double) -> Int {
        thresholds.indices.min { abs(thresholds[$0] - threshold) < abs(thresholds[$1] - threshold) } ?? defaultIndex
    }

    static func threshold(at position: Double) -> Double {
        guard position.isFinite else { return thresholds[defaultIndex] }
        return thresholds[Int(min(Double(thresholds.count - 1), max(0, position.rounded())))]
    }
}

struct StudySceneMatchSettingsRequest: Encodable {
    let p_scene_id: String
    let p_threshold: Double?
}

struct PrepareStudySceneMatchingRequest: Encodable {
    let scene_id: String
    let prepare_only = true
}

protocol StudySceneMatchSettingsServicing {
    func fetchStudySceneMatchSettings(session: SupabaseSession, sceneID: UUID) async throws -> StudySceneMatchSettings
    func updateStudySceneMatchSettings(session: SupabaseSession, sceneID: UUID, threshold: Double) async throws -> StudySceneMatchSettings
    func prepareStudySceneMatching(session: SupabaseSession, sceneID: UUID) async throws
}

extension StudySceneMatchSettingsServicing {
    func prepareStudySceneMatching(session: SupabaseSession, sceneID: UUID) async throws {
        throw SupabaseServiceError.invalidResponse
    }
    func fetchStudySceneMatchSettings(session: SupabaseSession, sceneID: UUID) async throws -> StudySceneMatchSettings {
        throw SupabaseServiceError.invalidResponse
    }

    func updateStudySceneMatchSettings(session: SupabaseSession, sceneID: UUID, threshold: Double) async throws -> StudySceneMatchSettings {
        throw SupabaseServiceError.invalidResponse
    }
}
