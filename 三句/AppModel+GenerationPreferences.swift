import Foundation

extension AppModel {
    func configureGenerationPreferenceSync() {
        generationPreferenceSync = GenerationPreferenceSync(defaults: defaults, fetch: { [weak self] owner in
            guard let self else { throw CancellationError() }
            let session = try await preferenceSession(for: owner)
            guard let profile = try await supabaseService.fetchProfile(session: session) else {
                throw SupabaseServiceError.invalidResponse
            }
            return GenerationPreferences(
                level: EnglishLevel(rawValue: profile.englishLevel) ?? .simple
            )
        }, save: { [weak self] owner, value in
            guard let self else { throw CancellationError() }
            let session = try await preferenceSession(for: owner)
            guard try await supabaseService.updateProfile(session: session, englishLevel: value.level) != nil else {
                throw SupabaseServiceError.invalidResponse
            }
        })
        generationPreferenceSync?.onChange = { [weak self] value in
            guard let self else { return }
            englishLevel = value.level
            defaults.set(value.level.rawValue, forKey: AppStorageKey.englishLevel)
        }
        let owner = (supabaseSession ?? loadStoredSession()).flatMap { $0.isAnonymous ? nil : $0.userID }
        generationPreferenceSync?.activate(userID: owner)
    }

    func preferenceSession(for owner: String) async throws -> SupabaseSession {
        guard isNetworkAvailable, let current = supabaseSession,
              !current.isAnonymous, current.userID == owner else { throw CancellationError() }
        return try await ensureFreshSessionIfNeeded(current)
    }
}
