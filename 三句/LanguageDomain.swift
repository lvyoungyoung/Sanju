import Foundation

nonisolated enum LearningLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en", spanish = "es", japanese = "ja", french = "fr"
    var id: String { rawValue }
    var displayTitle: String { SupportLanguage(rawValue: rawValue)!.displayTitle }
    var teachingLocale: TeachingLocale { LanguageCatalog.defaultTeachingLocale(self) }
}

nonisolated enum SupportLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans", english = "en", spanish = "es", japanese = "ja", french = "fr"
    var id: String { rawValue }
    var displayTitle: String {
        switch self {
        case .simplifiedChinese: return L10n.string("language.chinese", "简体中文")
        case .english: return L10n.string("language.english", "英语")
        case .spanish: return L10n.string("language.spanish", "西班牙语")
        case .japanese: return L10n.string("language.japanese", "日语")
        case .french: return L10n.string("language.french", "法语")
        }
    }
}

nonisolated enum TeachingLocale: String, Codable, Sendable {
    case americanEnglish = "en-US", latinAmericanSpanish = "es-419", standardJapanese = "ja-JP", franceFrench = "fr-FR"
}

nonisolated enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var displayTitle: String {
        switch self {
        case .system: return L10n.string("language.system", "跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

nonisolated enum LearningLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case starter, beginner, intermediate, advanced
    var id: String { rawValue }
    static var selectable: [Self] { [.starter, .beginner, .intermediate] }
    var displayTitle: String {
        switch self {
        case .starter: return L10n.string("english_level.starter", "启蒙")
        case .beginner: return L10n.string("english_level.simple", "初级")
        case .intermediate, .advanced: return L10n.string("english_level.intermediate", "中级")
        }
    }
    init(legacyValue: String) {
        switch legacyValue {
        case "启蒙": self = .starter
        case "中等", "高级": self = .intermediate
        default: self = .beginner
        }
    }
    var legacyValue: String {
        switch self { case .starter: return "启蒙"; case .beginner: return "简单"; case .intermediate, .advanced: return "中等" }
    }
}

nonisolated enum LanguageContractError: Error, LocalizedError {
    case unsupportedVersion, unsupportedCombination, invalidContext, unavailable, corruptContent
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return L10n.string("language.error.version", "此内容需要更新 App 后查看。")
        case .unsupportedCombination, .invalidContext: return L10n.string("language.error.pair", "请选择支持的学习语言与讲解语言组合。")
        case .unavailable: return L10n.string("language.error.unavailable", "此语言尚未开放，请稍后再试。")
        case .corruptContent: return L10n.string("language.error.content", "内容暂时无法读取，原有数据已保留。")
        }
    }
}

nonisolated enum LanguageCatalog {
    private struct Catalog: Decodable {
        struct Language: Decodable { let id: LearningLanguage; let teachingLocale: TeachingLocale }
        struct Pair: Decodable { let targetLanguage: LearningLanguage; let supportLanguage: SupportLanguage }
        let catalogVersion: Int
        let learningLanguages: [Language]
        let generationPairs: [Pair]
        let legacyExplanationPairs: [Pair]
    }
    // Generated, build-validated resource; failure is a programming error, never a user-data fallback.
    private static let catalog = try! JSONDecoder().decode(Catalog.self, from: Data(LanguageCatalogResource.json.utf8))
    static var version: Int { catalog.catalogVersion }
    static func supportsGeneration(target: LearningLanguage, support: SupportLanguage) -> Bool {
        catalog.generationPairs.contains { $0.targetLanguage == target && $0.supportLanguage == support }
    }
    static func supportsExplanation(target: LearningLanguage, support: SupportLanguage) -> Bool {
        supportsGeneration(target: target, support: support) || catalog.legacyExplanationPairs.contains {
            $0.targetLanguage == target && $0.supportLanguage == support
        }
    }
    static func targets(for support: SupportLanguage) -> [LearningLanguage] {
        LearningLanguage.allCases.filter { supportsGeneration(target: $0, support: support) }
    }
    static func defaultTeachingLocale(_ language: LearningLanguage) -> TeachingLocale {
        catalog.learningLanguages.first { $0.id == language }!.teachingLocale
    }
}

nonisolated struct LearningSelection: Codable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable { case standard, legacyEnglish }
    let mode: Mode
    let targetLanguage: LearningLanguage
    let translationLanguage: SupportLanguage
    let explanationLanguage: SupportLanguage

    static func standard(target: LearningLanguage, support: SupportLanguage) throws -> Self {
        let value = Self(mode: .standard, targetLanguage: target, translationLanguage: support, explanationLanguage: support)
        try value.validate()
        return value
    }
    static func legacyEnglish(explanationLanguage: SupportLanguage) -> Self {
        Self(mode: .legacyEnglish, targetLanguage: .english, translationLanguage: .simplifiedChinese,
             explanationLanguage: explanationLanguage == .english ? .english : .simplifiedChinese)
    }
    func validate() throws {
        guard LanguageCatalog.supportsGeneration(target: targetLanguage, support: translationLanguage) else {
            throw LanguageContractError.unsupportedCombination
        }
        switch mode {
        case .standard:
            guard explanationLanguage == translationLanguage else { throw LanguageContractError.invalidContext }
        case .legacyEnglish:
            guard targetLanguage == .english, translationLanguage == .simplifiedChinese,
                  [.english, .simplifiedChinese].contains(explanationLanguage) else { throw LanguageContractError.invalidContext }
        }
    }
}

nonisolated struct MemoryContentContext: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let targetLanguage: LearningLanguage
    let translationLanguage: SupportLanguage
    let teachingLocale: TeachingLocale
    static let legacyEnglish = Self(schemaVersion: 2, targetLanguage: .english, translationLanguage: .simplifiedChinese, teachingLocale: .americanEnglish)
    var isLegacyCompatible: Bool { self == .legacyEnglish }
    init(schemaVersion: Int = 2, targetLanguage: LearningLanguage, translationLanguage: SupportLanguage, teachingLocale: TeachingLocale) {
        self.schemaVersion = schemaVersion; self.targetLanguage = targetLanguage
        self.translationLanguage = translationLanguage; self.teachingLocale = teachingLocale
    }
    func validate() throws {
        guard schemaVersion == 2 else { throw LanguageContractError.unsupportedVersion }
        guard teachingLocale == targetLanguage.teachingLocale,
              LanguageCatalog.supportsGeneration(target: targetLanguage, support: translationLanguage) else {
            throw LanguageContractError.invalidContext
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, targetLanguage, translationLanguage, teachingLocale }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
                  targetLanguage: try c.decode(LearningLanguage.self, forKey: .targetLanguage),
                  translationLanguage: try c.decode(SupportLanguage.self, forKey: .translationLanguage),
                  teachingLocale: try c.decode(TeachingLocale.self, forKey: .teachingLocale))
        try validate()
    }
}
