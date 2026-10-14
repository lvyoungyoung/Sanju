import CryptoKit
import Combine
import Foundation

nonisolated struct SentenceExplanation: Codable, Equatable, Sendable {
    static let formatVersion = 2
    static let multilingualFormatVersion = 3

    struct Point: Codable, Equatable, Sendable {
        let title: String
        let explanation: String
        let example: Example
    }

    struct Example: Codable, Equatable, Sendable {
        let targetText: String
        let translationText: String
        let isLegacy: Bool
        var english: String { targetText }
        var chinese: String { translationText }

        init(english: String, chinese: String) {
            targetText = english; translationText = chinese; isLegacy = true
        }

        init(targetText: String, translationText: String) {
            self.targetText = targetText; self.translationText = translationText; isLegacy = false
        }

        private enum CodingKeys: String, CodingKey { case english, chinese, targetText, translationText }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            isLegacy = !values.contains(.targetText) && !values.contains(.translationText)
            if !isLegacy && (values.contains(.english) || values.contains(.chinese)) {
                throw DecodingError.dataCorruptedError(forKey: .targetText, in: values, debugDescription: "Ambiguous example schema")
            }
            targetText = try values.decode(String.self, forKey: isLegacy ? .english : .targetText)
            translationText = try values.decode(String.self, forKey: isLegacy ? .chinese : .translationText)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(targetText, forKey: isLegacy ? .english : .targetText)
            try values.encode(translationText, forKey: isLegacy ? .chinese : .translationText)
        }
    }

    let version: Int
    let points: [Point]
    var targetLanguage: LearningLanguage? = nil
    var explanationLanguage: SupportLanguage? = nil
    var exampleTranslationLanguage: SupportLanguage? = nil

    var isValid: Bool {
        func valid(_ text: String, _ limit: Int) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= limit
        }
        let validFormat = version == Self.formatVersion
            ? targetLanguage == nil && explanationLanguage == nil && exampleTranslationLanguage == nil && points.allSatisfy { $0.example.isLegacy }
            : version == Self.multilingualFormatVersion && targetLanguage != nil && explanationLanguage != nil && exampleTranslationLanguage != nil && points.allSatisfy { !$0.example.isLegacy }
        return validFormat && (1...4).contains(points.count)
            && points.allSatisfy {
                valid($0.title, 120) && valid($0.explanation, 800)
                    && valid($0.example.english, 300) && valid($0.example.chinese, 400)
            }
            && Set(points.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == points.count
            && Set(points.map { $0.example.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == points.count
    }
}

nonisolated struct SentenceExplanationRequestV3: Encodable, Equatable, Sendable {
    let sentenceID: UUID
    let targetText: String
    let translationText: String
    let targetLanguage: LearningLanguage
    let translationLanguage: SupportLanguage
    let teachingLocale: TeachingLocale
    let contentVersion: Int
    let contentSchemaVersion: Int
    let explanationLanguage: SupportLanguage
    let exampleTranslationLanguage: SupportLanguage
    let generate: Bool

    private enum CodingKeys: String, CodingKey {
        case sentenceID, explanationLanguage, exampleTranslationLanguage, generate, source
        case targetText, translationText, targetLanguage, translationLanguage, teachingLocale
        case contentVersion, contentSchemaVersion
    }

    func encode(to encoder: Encoder) throws {
        var body = encoder.container(keyedBy: CodingKeys.self)
        try body.encode(sentenceID, forKey: .sentenceID)
        try body.encode(explanationLanguage, forKey: .explanationLanguage)
        try body.encode(exampleTranslationLanguage, forKey: .exampleTranslationLanguage)
        try body.encode(generate, forKey: .generate)
        var source = body.nestedContainer(keyedBy: CodingKeys.self, forKey: .source)
        try source.encode(targetText, forKey: .targetText)
        try source.encode(translationText, forKey: .translationText)
        try source.encode(targetLanguage, forKey: .targetLanguage)
        try source.encode(translationLanguage, forKey: .translationLanguage)
        try source.encode(teachingLocale, forKey: .teachingLocale)
        try source.encode(contentVersion, forKey: .contentVersion)
        try source.encode(contentSchemaVersion, forKey: .contentSchemaVersion)
    }

    var supportsExplanation: Bool {
        LanguageCatalog.supportsExplanation(target: targetLanguage, support: explanationLanguage)
    }

    var isValid: Bool {
        let locales = ["en": "en-US", "es": "es-419", "ja": "ja-JP", "fr": "fr-FR"]
        let validLegacy = contentSchemaVersion != 1 || (targetLanguage == .english &&
            translationLanguage == .simplifiedChinese && teachingLocale == .americanEnglish && contentVersion == 1)
        return !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && targetText.utf16.count <= 1000 &&
            translationText.utf16.count <= 1000 && contentVersion > 0 && [1, 2].contains(contentSchemaVersion) &&
            locales[targetLanguage.rawValue] == teachingLocale.rawValue && validLegacy && supportsExplanation &&
            (exampleTranslationLanguage == explanationLanguage || (targetLanguage == .english &&
                explanationLanguage == .english && exampleTranslationLanguage == .simplifiedChinese))
    }

    func accepts(_ explanation: SentenceExplanation) -> Bool {
        isValid && explanation.isValid && explanation.version == SentenceExplanation.multilingualFormatVersion &&
            explanation.targetLanguage == targetLanguage && explanation.explanationLanguage == explanationLanguage &&
            explanation.exampleTranslationLanguage == exampleTranslationLanguage
    }

    func cacheKey(owner: String, environment: String) -> String {
        let components = [environment, owner.lowercased(), "3", "1", String(contentSchemaVersion), String(contentVersion),
                          targetText, translationText, targetLanguage.rawValue, translationLanguage.rawValue,
                          teachingLocale.rawValue, explanationLanguage.rawValue, exampleTranslationLanguage.rawValue]
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var legacyRequest: SentenceExplanationRequest? {
        guard targetLanguage == .english, translationLanguage == .simplifiedChinese,
              teachingLocale == .americanEnglish, contentVersion == 1,
              exampleTranslationLanguage == .simplifiedChinese,
              [.english, .simplifiedChinese].contains(explanationLanguage) else { return nil }
        return .init(sentenceID: sentenceID, english: targetText, chinese: translationText,
                     language: explanationLanguage == .english ? "en" : "zh", generate: generate)
    }

    func adaptingLegacy(_ explanation: SentenceExplanation) -> SentenceExplanation? {
        guard legacyRequest != nil, explanation.version == 2, explanation.isValid else { return nil }
        let adapted = SentenceExplanation(version: 3, points: explanation.points.map {
            .init(title: $0.title, explanation: $0.explanation,
                  example: .init(targetText: $0.example.english, translationText: $0.example.chinese))
        }, targetLanguage: targetLanguage, explanationLanguage: explanationLanguage,
           exampleTranslationLanguage: exampleTranslationLanguage)
        return accepts(adapted) ? adapted : nil
    }
}

nonisolated enum SentenceExplanationError: Error { case unsupportedLanguage }

nonisolated struct SentenceExplanationRequest: Codable, Equatable, Sendable {
    let sentenceID: UUID
    let english: String
    let chinese: String
    let language: String
    let generate: Bool

    func cacheKey(owner: String) -> String {
        let components = [owner.lowercased(), String(SentenceExplanation.formatVersion), english, chinese, language]
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct SentenceExplanationResponse: Decodable {
    let explanation: SentenceExplanation?
}

/// Account- and format-scoped files keep complete explanations available offline.
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
            if case SentenceExplanationError.unsupportedLanguage = error {
                errorMessage = L10n.string("sentence_detail.unsupported_language", "此句暂不支持所选讲解语言，请在设置中选择中文或英文。")
            } else if case SupabaseServiceError.apiError(let message) = error,
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
