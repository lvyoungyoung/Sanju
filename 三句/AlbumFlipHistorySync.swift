import Foundation

@MainActor
final class AlbumFlipHistorySync {
    typealias Fetch = (String) async throws -> [AlbumFlipProgress]
    typealias Upload = (String, [AlbumFlipEvent]) async throws -> [AlbumFlipProgress]

    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private let fetch: Fetch
    private let upload: Upload
    private let canUpload: (String, AlbumFlipEvent) -> Bool
    private let debounce: Duration
    private var owner: String?
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private var needsAnotherPass = false
    private var needsFetch = false

    init(defaults: UserDefaults, debounce: Duration = .seconds(2),
         canUpload: @escaping (String, AlbumFlipEvent) -> Bool = { _, _ in true },
         fetch: @escaping Fetch, upload: @escaping Upload) {
        self.defaults = defaults
        self.debounce = debounce
        self.canUpload = canUpload
        self.fetch = fetch
        self.upload = upload
    }

    func activate(userID: String?) {
        guard owner != userID else { return }
        task?.cancel()
        task = nil
        revision = UUID()
        owner = userID
        needsAnotherPass = false
        needsFetch = false
        refresh()
    }

    func refresh() {
        needsFetch = true
        uploadPending()
    }

    func uploadPending() {
        guard let owner else { return }
        needsAnotherPass = true
        guard task == nil else { return }
        let revision = revision
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == revision { task = nil } }
            do {
                try await Task.sleep(for: debounce)
                let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: owner)
                while needsAnotherPass {
                    try check(owner, revision)
                    needsAnotherPass = false
                    let shouldFetch = needsFetch
                    needsFetch = false
                    while true {
                        let batch = Array(store.read().pending.filter { self.canUpload(owner, $0) }
                            .sorted(by: AlbumFlipEvent.precedes).prefix(100))
                        guard !batch.isEmpty else { break }
                        let remote = try await upload(owner, batch)
                        try check(owner, revision)
                        store.merge(remote, acknowledging: batch)
                        onChange?()
                    }
                    if shouldFetch {
                        let remote = try await fetch(owner)
                        try check(owner, revision)
                        store.merge(remote)
                        onChange?()
                    }
                }
            } catch {
                // The durable, account-scoped outbox retries on foreground/network/next swipe.
#if DEBUG
                if !(error is CancellationError) {
                    print("[AlbumFlip] History sync deferred: \(error.localizedDescription)")
                }
#endif
            }
        }
    }

    func waitForSync() async { await task?.value }

    private func check(_ owner: String, _ revision: UUID) throws {
        try Task.checkCancellation()
        guard self.owner == owner, self.revision == revision else { throw CancellationError() }
    }
}
