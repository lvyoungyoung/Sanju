import Foundation

struct GenerationPreferences: Codable, Equatable {
    let level: EnglishLevel
}

/// Owns preference reads and writes so an older profile response cannot undo a selection.
@MainActor
final class GenerationPreferenceSync {
    nonisolated deinit { task?.cancel() }

    private struct Cached: Codable {
        let value: GenerationPreferences
        let pending: Bool
    }

    var onChange: ((GenerationPreferences) -> Void)?
    private(set) var value: GenerationPreferences
    private let defaults: UserDefaults
    private let fetch: (String) async throws -> GenerationPreferences
    private let save: (String, GenerationPreferences) async throws -> Void
    private var owner: String?
    private var revision = UUID()
    private var needsAnotherPass = false
    private var task: Task<Void, Never>?

    init(defaults: UserDefaults, fetch: @escaping (String) async throws -> GenerationPreferences,
         save: @escaping (String, GenerationPreferences) async throws -> Void) {
        self.defaults = defaults
        self.fetch = fetch
        self.save = save
        value = GenerationPreferences(
            level: EnglishLevel(rawValue: defaults.string(forKey: AppStorageKey.englishLevel) ?? "") ?? .simple
        )
        if cached(nil) == nil { cache(value, pending: false, owner: nil) }
    }

    func activate(userID: String?) {
        guard owner != userID else { return }
        owner = userID
        revision = UUID()
        apply(cached(userID)?.value ?? cached(nil)?.value ?? GenerationPreferences(level: .simple))
        refresh()
    }

    func select(_ value: GenerationPreferences) {
        revision = UUID()
        apply(value)
        cache(value, pending: owner != nil, owner: owner)
        refresh()
    }

    func refresh() {
        guard owner != nil else { return }
        needsAnotherPass = true
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            while needsAnotherPass {
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { return }
                needsAnotherPass = false
                await synchronize()
            }
        }
    }

    func waitForSync() async { await task?.value }

    private func synchronize() async {
        guard let owner else { return }
        let revision = revision
        let requested = value
        do {
            let resolved: GenerationPreferences
            if cached(owner)?.pending == true {
                try await save(owner, requested)
                resolved = requested
            } else {
                resolved = try await fetch(owner)
            }
            guard self.owner == owner, self.revision == revision else { return }
            cache(resolved, pending: false, owner: owner)
            apply(resolved)
        } catch {
            // Keep the pending record for reconnection, foregrounding or next launch.
        }
    }

    private func apply(_ value: GenerationPreferences) {
        self.value = value
        onChange?(value)
    }

    private func key(_ owner: String?) -> String { "sanju.generation.preferences.\(owner ?? "guest")" }
    private func cached(_ owner: String?) -> Cached? {
        guard let data = defaults.data(forKey: key(owner)) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }
    private func cache(_ value: GenerationPreferences, pending: Bool, owner: String?) {
        defaults.set(try? JSONEncoder().encode(Cached(value: value, pending: pending)), forKey: key(owner))
    }
}
