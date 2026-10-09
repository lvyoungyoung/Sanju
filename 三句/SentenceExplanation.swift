import CryptoKit
import Combine
import Foundation

nonisolated struct SentenceExplanation: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        let title: String
        let explanation: String
    }

    struct Example: Codable, Equatable, Sendable {
        let english: String
        let chinese: String
    }

    struct Exercise: Codable, Equatable, Sendable {
        let prompt: String
        let sentence: String
        let options: [String]
        let answerIndex: Int
        let explanation: String
    }

    let version: Int
    let points: [Point]
    let examples: [Example]
    let exercise: Exercise

    var isValid: Bool {
        func valid(_ text: String, _ limit: Int) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= limit
        }
        return version == 1 && (1...4).contains(points.count)
            && points.allSatisfy { valid($0.title, 120) && valid($0.explanation, 800) }
            && examples.count == 2 && examples.allSatisfy { valid($0.english, 300) && valid($0.chinese, 400) }
            && Set(examples.map { $0.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == 2
            && valid(exercise.prompt, 200) && valid(exercise.sentence, 300)
            && exercise.sentence.components(separatedBy: "____").count == 2
            && exercise.options.count == 4 && exercise.options.allSatisfy { valid($0, 100) }
            && Set(exercise.options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == 4
            && exercise.options.indices.contains(exercise.answerIndex) && valid(exercise.explanation, 800)
    }
}

nonisolated struct SentenceExplanationRequest: Codable, Equatable, Sendable {
    let sentenceID: UUID
    let english: String
    let chinese: String
    let language: String
    let generate: Bool

    func cacheKey(owner: String) -> String {
        let components = [owner.lowercased(), "1", english, chinese, language]
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct SentenceExplanationResponse: Decodable {
    let explanation: SentenceExplanation?
}

nonisolated struct SentenceExerciseAttempt {
    private(set) var selectedIndex: Int?

    mutating func select(_ index: Int, exercise: SentenceExplanation.Exercise) {
        guard selectedIndex == nil, exercise.options.indices.contains(index) else { return }
        selectedIndex = index
    }

    mutating func reset() { selectedIndex = nil }
}

/// Account-scoped files keep saved explanations available offline; exercise answers are never stored.
actor SentenceExplanationCache {
    static let shared = SentenceExplanationCache()
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("SentenceExplanations", isDirectory: true)) {
        self.directory = directory
    }

    func load(key: String) -> SentenceExplanation? {
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent(key + ".json"))
            let result = try JSONDecoder().decode(SentenceExplanation.self, from: data)
            return result.isValid ? result : nil
        } catch {
            return nil
        }
    }

    func save(_ explanation: SentenceExplanation, key: String) {
        guard explanation.isValid else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(explanation).write(to: directory.appendingPathComponent(key + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // The cloud result is already durable; a local cache failure must not discard it.
            #if DEBUG
            print("[SentenceExplanation] Local cache write failed: \(error)")
            #endif
        }
    }
}

@MainActor
final class SentenceExplanationModel: ObservableObject {
    @Published private(set) var explanation: SentenceExplanation?
    @Published private(set) var isLoading = false
    @Published private(set) var isGenerating = false
    @Published private(set) var errorMessage: String?
    private var revision = UUID()

    func reset() {
        revision = UUID()
        explanation = nil
        errorMessage = nil
        isLoading = false
        isGenerating = false
    }

    func load(generate: Bool, operation: () async throws -> SentenceExplanation?) async {
        guard !isLoading, explanation == nil else { return }
        let revision = revision
        isLoading = true
        isGenerating = generate
        errorMessage = nil
        defer { if self.revision == revision { isLoading = false; isGenerating = false } }
        do {
            let result = try await operation()
            try Task.checkCancellation()
            guard self.revision == revision else { return }
            if let result, !result.isValid { throw URLError(.cannotParseResponse) }
            if generate && result == nil { throw URLError(.cannotParseResponse) }
            explanation = result
        } catch is CancellationError {
            return
        } catch {
            guard self.revision == revision, !Task.isCancelled else { return }
            if case SupabaseServiceError.apiError(let message) = error,
               (message.contains("explanation_rate_limited") || message == "rate_limit_exceeded") {
                errorMessage = L10n.string("sentence_detail.rate_limited", "解析次数较多，请稍后再试。")
            } else if case SupabaseServiceError.apiError(let message) = error,
                      message.contains("explanation_in_progress") {
                errorMessage = L10n.string("sentence_detail.in_progress", "这句话正在解析，请稍后重试。")
            } else if (error as? URLError)?.code == .notConnectedToInternet {
                errorMessage = L10n.string("sentence_detail.offline", "请连接网络后再获取解析。")
            } else {
                errorMessage = L10n.string("sentence_detail.analysis_failed", "暂时无法获取解析，请稍后重试。")
            }
        }
    }
}
