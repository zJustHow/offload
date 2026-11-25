import CoreServices
import Foundation

/// Reports which paths changed under some folders, once they have been quiet for a while.
///
/// FSEvents delivers every write of a file as it happens; reading a file mid-save (or mid-download)
/// would index half of it, and a note being typed into would be re-read on every keystroke's
/// autosave. So each path is held back until it has had no event for `quietPeriod`. Debouncing is
/// per path, not global: one file that never stops changing cannot starve all the others.
///
/// Events can be lost (the machine sleeps, a volume goes away, the kernel drops events). In those
/// cases FSEvents says so, and the affected folder is reported as a whole so the caller re-reads it.
/// A full `cycle` remains the safety net for anything that still slips through.
public final class FolderWatcher: @unchecked Sendable {
    public let roots: [String]
    private let quietPeriod: TimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "offload.folder-watcher")
    private var stream: FSEventStreamRef?
    private var lastSeen: [String: Date] = [:]
    private var timer: DispatchWorkItem?

    /// `onChange` is called on a private queue with the paths that have settled, sorted.
    public init(roots: [String], quietPeriod: TimeInterval = 5, onChange: @escaping @Sendable ([String]) -> Void) {
        self.roots = roots
        self.quietPeriod = quietPeriod
        self.onChange = onChange
    }

    deinit { stop() }

    /// Starts watching the roots that exist. Returns false when none could be watched.
    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        let existing = roots.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return false }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.record(paths: Array(paths.prefix(count)), flags: (0..<min(count, paths.count)).map { eventFlags[$0] })
        }
        guard let s = FSEventStreamCreate(
            nil, callback, &context, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    public func stop() {
        if let s = stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
        queue.sync { timer?.cancel(); timer = nil; lastSeen.removeAll() }
    }

    // MARK: - Debouncing (runs on `queue`)

    /// Public for tests: feeds events as FSEvents would deliver them.
    func record(paths: [String], flags: [FSEventStreamEventFlags]) {
        queue.async { [self] in
            let now = Date()
            for (path, flag) in zip(paths, flags) where Self.isRelevant(flag) { lastSeen[path] = now }
            schedule(after: quietPeriod)
        }
    }

    /// A folder's own "modified" event only means an entry came or went, which the entry's own
    /// event already says; rescanning the whole folder for it would be wasted work. Created, removed
    /// and renamed folders are real changes, and the "events were dropped" flags demand a rescan.
    static func isRelevant(_ flags: FSEventStreamEventFlags) -> Bool {
        let isDirectory = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        guard isDirectory else { return true }
        let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        return flags & (structural | lost) != 0
    }

    private func schedule(after delay: TimeInterval) {
        guard timer == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        timer = item
        queue.asyncAfter(deadline: .now() + max(delay, 0.01), execute: item)
    }

    private func flush() {
        timer = nil
        let now = Date()
        var ready: [String] = []
        var nextDue: Date?
        for (path, seen) in lastSeen {
            let due = seen.addingTimeInterval(quietPeriod)
            if due <= now { ready.append(path) } else { nextDue = min(nextDue ?? due, due) }
        }
        for path in ready { lastSeen[path] = nil }
        if let nextDue { schedule(after: nextDue.timeIntervalSince(now)) }
        if !ready.isEmpty { onChange(ready.sorted()) }
    }
}
