import Foundation

extension SupabaseService: LanguagePreferenceServicing {
    func getLearningPreferences(session: SupabaseSession) async throws -> RemoteLearningPreferences {
        let result: RemoteLearningPreferences = try await contentRPC(session: session,
            name: "get_learning_preferences_v1", payload: [String: String]())
        try result.validate()
        return result
    }

    func updateLearningPreferences(session: SupabaseSession, patch: LearningPreferencePatch) async throws -> RemoteLearningPreferences {
        let result: RemoteLearningPreferences = try await contentRPC(session: session,
            name: "update_learning_preferences_v1", payload: ["p_patch": patch])
        try result.validate()
        return result
    }

    func getLanguageCapabilities(session: SupabaseSession) async throws -> LanguageCapabilities {
        let result: LanguageCapabilities = try await contentRPC(session: session,
            name: "get_language_capabilities_v1", payload: ["p_catalog_version": LanguageCatalog.version])
        guard result.schemaVersion == 1, result.catalogVersion == LanguageCatalog.version else {
            throw LanguageContractError.unsupportedVersion
        }
        for combination in result.combinations {
            try MemoryContentContext(targetLanguage: combination.targetLanguage,
                translationLanguage: combination.translationLanguage, teachingLocale: combination.teachingLocale).validate()
        }
        return result
    }
}
