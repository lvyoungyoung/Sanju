import Foundation

nonisolated struct LearningPreferences: Codable, Equatable, Sendable {
    var selection: LearningSelection
    var levels: [String: LearningLevel]
    init(selection: LearningSelection, levels: [String: LearningLevel]) {
        self.selection = selection; self.levels = levels
    }
    private enum CodingKeys: String, CodingKey { case selection, levels }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selection = try values.decode(LearningSelection.self, forKey: .selection)
        levels = try values.decode([String: LearningLevel].self, forKey: .levels)
        try selection.validate()
        guard levels.keys.allSatisfy({ LearningLanguage(rawValue: $0) != nil }) else {
            throw LanguageContractError.invalidContext
        }
    }
    func level(for language: LearningLanguage) -> LearningLevel {
        let stored = levels[language.rawValue] ?? .beginner
        return stored == .advanced ? .intermediate : stored
    }
    static func legacy(level: LearningLevel = .beginner) -> Self {
        Self(selection: .legacyEnglish(explanationLanguage: InterfaceLanguageStore.resolvedCode == "en" ? .english : .simplifiedChinese),
             levels: [LearningLanguage.english.rawValue: level])
    }
}

nonisolated struct RemoteLearningPreferences: Decodable {
    struct Selection: Decodable {
        let mode: LearningSelection.Mode
        let targetLanguage: LearningLanguage
        let translationLanguage: SupportLanguage
        let explanationLanguage: SupportLanguage
        let revision: Int
        var value: LearningSelection {
            LearningSelection(mode: mode, targetLanguage: targetLanguage,
                              translationLanguage: translationLanguage, explanationLanguage: explanationLanguage)
        }
    }
    struct Language: Decodable {
        let targetLanguage: LearningLanguage
        let level: LearningLevel
        let levelRevision: Int
        let speechVoice: String?
        let voiceRevision: Int
    }
    let schemaVersion: Int
    let selection: Selection?
    let languages: [Language]
    func validate() throws {
        guard schemaVersion == 1, Set(languages.map(\.targetLanguage)).count == languages.count else {
            throw LanguageContractError.unsupportedVersion
        }
        try selection?.value.validate()
    }
}

nonisolated struct LearningPreferencePatch: Encodable {
    struct Selection: Encodable {
        let mode: LearningSelection.Mode
        let targetLanguage: LearningLanguage
        let translationLanguage: SupportLanguage
        let explanationLanguage: SupportLanguage
        let expectedRevision: Int
        init(_ selection: LearningSelection, expectedRevision: Int) {
            mode = selection.mode; targetLanguage = selection.targetLanguage
            translationLanguage = selection.translationLanguage; explanationLanguage = selection.explanationLanguage
            self.expectedRevision = expectedRevision
        }
    }
    struct Language: Encodable {
        let targetLanguage: LearningLanguage
        let level: LearningLevel
        let expectedLevelRevision: Int
    }
    var selection: Selection? = nil
    var language: Language? = nil
}

nonisolated struct LanguageCapabilities: Decodable, Sendable {
    struct Combination: Decodable, Sendable {
        let targetLanguage: LearningLanguage
        let translationLanguage: SupportLanguage
        let teachingLocale: TeachingLocale
        let canRead: Bool
        let canGenerate: Bool
    }
    let schemaVersion: Int
    let catalogVersion: Int
    let voiceCatalogVersion: Int
    let combinations: [Combination]
    static let unavailable = Self(schemaVersion: 1, catalogVersion: 1, voiceCatalogVersion: 1, combinations: [])
    func permits(_ selection: LearningSelection) -> Bool {
        guard schemaVersion == 1, catalogVersion == LanguageCatalog.version else { return false }
        return combinations.contains { $0.targetLanguage == selection.targetLanguage &&
            $0.translationLanguage == selection.translationLanguage &&
            $0.teachingLocale == selection.targetLanguage.teachingLocale && $0.canGenerate }
    }
}

protocol LanguagePreferenceServicing {
    func getLearningPreferences(session: SupabaseSession) async throws -> RemoteLearningPreferences
    func updateLearningPreferences(session: SupabaseSession, patch: LearningPreferencePatch) async throws -> RemoteLearningPreferences
    func getLanguageCapabilities(session: SupabaseSession) async throws -> LanguageCapabilities
}
