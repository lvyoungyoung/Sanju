import Foundation

nonisolated enum SpeechPreferenceSyncStatus {
    case local, syncing, synced, pending
}

/// Serializes preference requests and ignores responses for an account we left.
@MainActor
final class SpeechPreferenceSync {
    typealias Fetch = (String) async throws -> SpeechVoice?
    typealias Save = (String, SpeechVoice, Bool) async throws -> SpeechVoice

    var onVoiceChange: ((SpeechVoice) -> Void)?
    var onStatusChange: ((SpeechPreferenceSyncStatus) -> Void)?
    private(set) var voice: SpeechVoice
    private(set) var status: SpeechPreferenceSyncStatus = .local {
        didSet { onStatusChange?(status) }
    }
    private let defaults: UserDefaults
    private let fetch: Fetch
    private let save: Save
    private var owner: String?
    private var revision = UUID()
    private var needsAnotherPass = false
    private var task: Task<Void, Never>?

    init(defaults: UserDefaults, fetch: @escaping Fetch, save: @escaping Save) {
        self.defaults = defaults
        self.fetch = fetch
        self.save = save
        voice = SpeechPreferences(defaults: defaults).voice
    }

    func activate(userID: String?) {
        guard owner != userID else { return }
        owner = userID
        revision = UUID()
        apply(userID.flatMap { cached($0)?.voice } ?? SpeechPreferences(defaults: defaults).voice)
        status = userID == nil ? .local : .syncing
        refresh()
    }

    func select(_ voice: SpeechVoice) {
        guard self.voice != voice else { return }
        revision = UUID()
        apply(voice)
        guard let owner else {
            defaults.set(voice.rawValue, forKey: SpeechPreferenceKey.voice)
            status = .local
            return
        }
        cache(voice, pending: true, for: owner)
        refresh()
    }

    func refresh() {
        guard owner != nil else { return }
        needsAnotherPass = true
        status = .syncing
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            while needsAnotherPass {
                // Coalesce rapid selections without dropping changes made during a request.
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
                needsAnotherPass = false
                await synchronize()
            }
        }
    }

    func waitForSync() async {
        await task?.value
    }

    private func synchronize() async {
        guard let owner else { return }
        let revision = revision
        let requestedVoice = voice
        do {
            let resolved: SpeechVoice
            if cached(owner)?.pending == true {
                resolved = try await save(owner, requestedVoice, false)
            } else if let remote = try await fetch(owner) {
                resolved = remote
            } else {
                guard isCurrent(owner, revision) else { return }
                // Seed an unset account without overwriting a concurrent device's choice.
                resolved = try await save(owner, requestedVoice, true)
            }
            guard isCurrent(owner, revision) else { return }
            cache(resolved, pending: false, for: owner)
            apply(resolved)
            status = .synced
        } catch {
            guard isCurrent(owner, revision) else { return }
            status = .pending
#if DEBUG
            print("[SpeechFlow] Voice preference sync deferred: \(error.localizedDescription)")
#endif
        }
    }

    private func isCurrent(_ owner: String, _ revision: UUID) -> Bool {
        self.owner == owner && self.revision == revision
    }

    private func apply(_ voice: SpeechVoice) {
        self.voice = voice
        onVoiceChange?(voice)
    }

    private func cacheKey(_ owner: String) -> String { "sanju.speech.account.\(owner)" }

    private func cached(_ owner: String) -> (voice: SpeechVoice, pending: Bool)? {
        guard let values = defaults.dictionary(forKey: cacheKey(owner)),
              let rawVoice = values["voice"] as? String,
              let voice = SpeechVoice(rawValue: rawVoice) else { return nil }
        return (voice, values["pending"] as? Bool ?? false)
    }

    private func cache(_ voice: SpeechVoice, pending: Bool, for owner: String) {
        defaults.set(["voice": voice.rawValue, "pending": pending], forKey: cacheKey(owner))
    }
}
