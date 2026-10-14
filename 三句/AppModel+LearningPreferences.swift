import Foundation
import Combine

extension AppModel {
    var learningSelection: LearningSelection { learningPreferences.selection }
    var explanationLanguage: SupportLanguage { learningSelection.explanationLanguage }
    var currentGenerationSpec: GenerationSpec {
        GenerationSpec(selection: learningSelection, level: learningPreferences.level(for: learningSelection.targetLanguage))
    }
    var showsJapaneseReadings: Bool {
        get { defaults.object(forKey: "sanju.japanese.readings") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sanju.japanese.readings"); objectWillChange.send() }
    }

    func configureLearningPreferenceSync() {
        let initial = LearningPreferences.legacy(level: LearningLevel(legacyValue: englishLevel.rawValue))
        learningPreferenceSync = LearningPreferenceSync(defaults: defaults, initial: initial, fetch: { [weak self] owner in
            guard let self, let service = supabaseService as? LanguagePreferenceServicing else { throw LanguageContractError.unavailable }
            return try await service.getLearningPreferences(session: preferenceSession(for: owner))
        }, save: { [weak self] owner, patch in
            guard let self, let service = supabaseService as? LanguagePreferenceServicing else { throw LanguageContractError.unavailable }
            return try await service.updateLearningPreferences(session: preferenceSession(for: owner), patch: patch)
        })
        learningPreferenceSync?.onChange = { [weak self] value in
            guard let self else { return }
            learningPreferences = value
        }
        learningPreferenceSync?.onError = { [weak self] error in
            if let contractError = error as? LanguageContractError {
                self?.languagePreferenceError = contractError.localizedDescription
            } else {
                self?.languagePreferenceError = error == nil ? nil : L10n.string("language.sync.pending", "语言设置已保存在本机，联网后将重试同步。")
            }
        }
        if let value = learningPreferenceSync?.value { learningPreferences = value }
        if let stored = defaults.string(forKey: "sanju.study.language"), let language = LearningLanguage(rawValue: stored) {
            studyLanguage = language
        } else { studyLanguage = learningSelection.targetLanguage }
        let owner = (supabaseSession ?? loadStoredSession()).flatMap { $0.isAnonymous ? nil : $0.userID }
        learningPreferenceSync?.activate(userID: owner)
        if learningPreferenceSync?.hasInvalidCache == true { languagePreferenceError = LanguageContractError.corruptContent.localizedDescription }
    }

    func selectLearningLanguage(_ selection: LearningSelection) throws {
        try selection.validate()
        guard languageCapabilities.permits(selection) else { throw LanguageContractError.unavailable }
        guard let learningPreferenceSync else { throw LanguageContractError.unavailable }
        try learningPreferenceSync.select(selection)
        defaults.set(true, forKey: "sanju.learning.selection.confirmed")
    }

    func selectLearningLevel(_ level: LearningLevel) {
        let language = learningSelection.targetLanguage
        learningPreferenceSync?.select(level: level, language: language)
        if language == .english, let legacy = EnglishLevel(rawValue: level.legacyValue) {
            generationPreferenceSync?.select(GenerationPreferences(level: legacy))
        }
    }

    func refreshLanguageCapabilities() async {
        let revision = accountRequests.revision
        do {
            guard let service = supabaseService as? LanguagePreferenceServicing else { return }
            let session = try await ensureValidSession()
            let requestRevision = accountRequests.revision
            let owner = session.userID
            let result = try await service.getLanguageCapabilities(session: session)
            guard supabaseSession?.userID == owner,
                  requestRevision == accountRequests.revision,
                  result.schemaVersion == 1, result.catalogVersion == LanguageCatalog.version else { return }
            languageCapabilities = result
        } catch {
            // Fail closed for new generation only; historical reads remain available.
            if revision == accountRequests.revision { languageCapabilities = .unavailable }
        }
    }
}
