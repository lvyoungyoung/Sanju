import Foundation

extension AppModel {
    func configureSpeechPreferenceSync() {
        speechPreferenceSync = SpeechPreferenceSync(
            defaults: defaults,
            fetch: { [weak self] owner in
                guard let self else { throw CancellationError() }
                let session = try await speechPreferenceSession(for: owner)
                return try await supabaseService.fetchSpeechVoice(session: session)
            },
            save: { [weak self] owner, voice, onlyIfUnset in
                guard let self else { throw CancellationError() }
                let session = try await speechPreferenceSession(for: owner)
                return try await supabaseService.updateSpeechVoice(
                    session: session, voice: voice, onlyIfUnset: onlyIfUnset
                )
            }
        )
        speechPreferenceSync?.onVoiceChange = { [weak speech] voice in
            speech?.applyVoice(voice)
        }
        speechPreferenceSync?.onStatusChange = { [weak speech] status in
            speech?.preferenceSyncStatus = status
        }
        speech.onVoiceSelection = { [weak self] voice in
            self?.speechPreferenceSync?.select(voice)
        }
    }

    private func speechPreferenceSession(for owner: String) async throws -> SupabaseSession {
        guard isNetworkAvailable,
              let current = supabaseSession,
              !current.isAnonymous, current.userID == owner else { throw CancellationError() }
        if current.expiresAt > Date().addingTimeInterval(60) { return current }
        let fresh = try await supabaseService.refreshSession(refreshToken: current.refreshToken)
        guard supabaseSession?.userID == owner,
              supabaseSession?.isAnonymous == false,
              supabaseSession?.refreshToken == current.refreshToken,
              fresh.userID == owner, !fresh.isAnonymous else { throw CancellationError() }
        supabaseSession = fresh
        persistSession()
        return fresh
    }
}
