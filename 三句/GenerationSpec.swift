import Foundation

nonisolated struct GenerationSpec: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let catalogVersion: Int
    let targetLanguage: LearningLanguage
    let translationLanguage: SupportLanguage
    let teachingLocale: TeachingLocale
    let level: LearningLevel
    let generationFormat: String

    init(selection: LearningSelection, level: LearningLevel) {
        schemaVersion = 1; catalogVersion = LanguageCatalog.version
        targetLanguage = selection.targetLanguage; translationLanguage = selection.translationLanguage
        teachingLocale = selection.targetLanguage.teachingLocale; self.level = level
        generationFormat = "dual_tabs_v1"
    }
    var context: MemoryContentContext {
        MemoryContentContext(targetLanguage: targetLanguage, translationLanguage: translationLanguage, teachingLocale: teachingLocale)
    }
    func validate() throws {
        guard schemaVersion == 1, catalogVersion == LanguageCatalog.version, generationFormat == "dual_tabs_v1" else {
            throw LanguageContractError.unsupportedVersion
        }
        try context.validate()
    }
}

nonisolated struct GenerationRequestSnapshot: Codable, Hashable, Sendable {
    let owner: String
    let accountRevision: UUID
    let requestID: UUID
    let guestJobID: UUID?
    let spec: GenerationSpec
    let imageDigest: String
    let createdAt: Date
}
