import Foundation

/// Keeps the search index following the chosen folders while the app runs: a file that is added,
/// edited, moved or deleted is reflected in the chunks, keyword index and vectors within seconds,
/// instead of at the next nightly cycle.
///
/// Starting also does a catch-up: whatever changed while nothing was watching (the app was closed, the
/// Mac was asleep, the folder was on a disconnected drive) is reconciled once, so the index is right
/// from the first second rather than after the next nightly run.
///
/// Changes are applied by `Runtime.syncChanged`, which takes turns with a running cycle. Paths that
/// arrive while a sync is busy are merged and handled in the next round. Folders that cannot be
/// watched (they do not exist yet) are simply covered by the cycle, which stays the full,
/// authoritative reconciliation.
public final class LiveSync: @unchecked Sendable {
    private let runtime: Runtime
    private let quietPeriod: TimeInterval
    private let catchUpOnStart: Bool
    private let onSynced: (@Sendable (IngestReport) -> Void)?
    private var watcher: FolderWatcher?
    private let lock = NSLock()
    private var pending = Set<String>()
    private var draining: Task<Void, Never>?

    /// `onSynced` is called after every batch that changed something or failed.
    public init(runtime: Runtime, quietPeriod: TimeInterval = 5, catchUpOnStart: Bool = true, onSynced: (@Sendable (IngestReport) -> Void)? = nil) {
        self.runtime = runtime
        self.quietPeriod = quietPeriod
        self.catchUpOnStart = catchUpOnStart
        self.onSynced = onSynced
    }

    deinit { stop() }

    /// Starts watching the configured folders. Returns false when there is nothing to watch.
    @discardableResult
    public func start() -> Bool {
        guard watcher == nil else { return true }
        let roots = runtime.folderConnectors().map(\.root.path)
        let w = FolderWatcher(roots: roots, quietPeriod: quietPeriod) { [weak self] paths in self?.enqueue(paths) }
        guard w.start() else { return false }
        watcher = w
        // After the watcher is running, so a change made during the catch-up is not missed: it is
        // queued behind it and handled in the next round.
        if catchUpOnStart { enqueue(roots.filter { FileManager.default.fileExists(atPath: $0) }) }
        return true
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        lock.lock(); pending.removeAll(); let task = draining; draining = nil; lock.unlock()
        task?.cancel()
    }

    var isWatching: Bool { watcher != nil }

    /// Queues paths for the next sync. Also the entry point tests use in place of real events.
    func enqueue(_ paths: [String]) {
        let connectors = runtime.folderConnectors()
        let relevant = paths.filter { p in connectors.contains { $0.scopedPath(for: p) != nil } }
        guard !relevant.isEmpty else { return }
        lock.lock()
        pending.formUnion(relevant)
        if draining == nil { draining = Task { [weak self] in await self?.drain() } }
        lock.unlock()
    }

    /// Takes everything queued so far, or clears `draining` and returns nil when there is nothing.
    private func takeBatch() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        if pending.isEmpty { draining = nil; return nil }
        defer { pending.removeAll() }
        return Array(pending)
    }

    private func drain() async {
        while !Task.isCancelled, let batch = takeBatch() {
            let report = await runtime.syncChanged(paths: batch)
            let touched = report.survivors + report.junk + report.sensitive + report.failed + report.deleted
            if touched > 0 || !report.sourceErrors.isEmpty { onSynced?(report) }
        }
    }
}
