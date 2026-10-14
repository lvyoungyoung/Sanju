import Foundation

@MainActor
final class LearningPreferenceSync {
    private struct Cached: Codable {
        var value: LearningPreferences
        var pendingSelection = false
        var pendingLevels: Set<String> = []
    }
    private let defaults: UserDefaults
    private let fetch: (String) async throws -> RemoteLearningPreferences
    private let save: (String, LearningPreferencePatch) async throws -> RemoteLearningPreferences
    private(set) var value: LearningPreferences
    private var owner: String?
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private var taskID = UUID()
    private var rerun = false
    var onChange: ((LearningPreferences) -> Void)?
    var onError: ((Error?) -> Void)?
    nonisolated deinit { task?.cancel() }

    init(defaults: UserDefaults, initial: LearningPreferences,
         fetch: @escaping (String) async throws -> RemoteLearningPreferences,
         save: @escaping (String, LearningPreferencePatch) async throws -> RemoteLearningPreferences) {
        self.defaults = defaults; self.fetch = fetch; self.save = save
        value = initial
        if let cached = read(nil) { value = cached.value }
        else { write(Cached(value: initial), owner: nil) }
    }
    func activate(userID: String?) {
        guard owner != userID else { refresh(); return }
        task?.cancel(); task = nil; taskID = UUID(); rerun = false
        owner = userID; revision = UUID()
        let cached = read(userID) ?? Cached(value: read(nil)?.value ?? value)
        write(cached, owner: userID); apply(cached.value)
        refresh()
    }
    func select(_ selection: LearningSelection) throws {
        guard !hasInvalidCache else { throw LanguageContractError.corruptContent }
        try selection.validate()
        var cached = read(owner) ?? Cached(value: value)
        cached.value.selection = selection; cached.pendingSelection = owner != nil
        change(cached)
    }
    func select(level: LearningLevel, language: LearningLanguage) {
        guard !hasInvalidCache else { onError?(LanguageContractError.corruptContent); return }
        var cached = read(owner) ?? Cached(value: value)
        cached.value.levels[language.rawValue] = level
        if owner != nil { cached.pendingLevels.insert(language.rawValue) }
        change(cached)
    }
    private func change(_ cached: Cached) {
        revision = UUID(); write(cached, owner: owner); apply(cached.value); refresh()
    }
    private func apply(_ value: LearningPreferences) { self.value = value; onChange?(value) }
    func refresh() {
        guard owner != nil else { return }
        rerun = true
        guard task == nil else { return }
        let identifier = UUID()
        taskID = identifier
        task = Task { [weak self] in
            guard let self else { return }
            defer { if taskID == identifier { task = nil } }
            while rerun && !Task.isCancelled {
                rerun = false
                await synchronize()
            }
        }
    }
    func waitForSync() async { await task?.value }
    private func synchronize(retryingConflict: Bool = false) async {
        guard let owner, let cached = read(owner) else { return }
        let revision = revision
        do {
            var remote = try await fetch(owner)
            try remote.validate()
            try check(owner, revision)
            // Existing accounts win on login; only explicit edits or absent server fields are written.
            if cached.pendingSelection || remote.selection == nil {
                remote = try await save(owner, LearningPreferencePatch(selection: .init(cached.value.selection, expectedRevision: remote.selection?.revision ?? 0)))
                try check(owner, revision)
            }
            for (key, level) in cached.value.levels.sorted(by: { $0.key < $1.key }) {
                guard let language = LearningLanguage(rawValue: key) else { throw LanguageContractError.invalidContext }
                let old = remote.languages.first { $0.targetLanguage == language }
                if cached.pendingLevels.contains(key) || old == nil {
                    remote = try await save(owner, LearningPreferencePatch(language: .init(targetLanguage: language, level: level, expectedLevelRevision: old?.levelRevision ?? 0)))
                    try check(owner, revision)
                }
            }
            try remote.validate()
            var result = cached.value
            if let selection = remote.selection { result.selection = selection.value }
            for language in remote.languages { result.levels[language.targetLanguage.rawValue] = language.level }
            write(Cached(value: result), owner: owner); apply(result); onError?(nil)
        } catch is CancellationError {
            // A later explicit choice/account switch owns the next synchronization pass.
        } catch {
            guard self.owner == owner, self.revision == revision else { return }
            if !retryingConflict, case SupabaseServiceError.apiError(let message) = error,
               message.contains("preference_revision_conflict") {
                await synchronize(retryingConflict: true)
                return
            }
            onError?(error)
        }
    }
    private func check(_ owner: String, _ revision: UUID) throws {
        try Task.checkCancellation()
        guard self.owner == owner, self.revision == revision else { throw CancellationError() }
    }
    private func key(_ owner: String?) -> String { "sanju.learning-preferences.v1.\(owner ?? "guest")" }
    var hasInvalidCache: Bool { defaults.data(forKey: key(owner)) != nil && read(owner) == nil }
    private func read(_ owner: String?) -> Cached? {
        guard let data = defaults.data(forKey: key(owner)) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }
    private func write(_ cached: Cached, owner: String?) {
        guard defaults.data(forKey: key(owner)) == nil || read(owner) != nil else {
            onError?(LanguageContractError.corruptContent)
            return
        }
        if let data = try? JSONEncoder().encode(cached) { defaults.set(data, forKey: key(owner)) }
    }
}
