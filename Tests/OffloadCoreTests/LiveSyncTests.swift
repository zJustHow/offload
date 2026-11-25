import CoreServices
import XCTest
@testable import OffloadCore

/// Following the folders as they change: path-scoped reads, applying a handful of changed paths,
/// the debouncing watcher, and the whole thing running against real file-system events.
final class LiveSyncTests: XCTestCase {
    var dir: URL!
    var home: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
        dir = tmp.appendingPathComponent("offload-live-\(UUID().uuidString)")
        home = tmp.appendingPathComponent("offload-live-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: home)
    }

    /// The path as FSEvents (and a directory walk) report it: symlinks resolved.
    func path(_ name: String) -> String { FilesConnector.realPath(dir.path) + "/" + name }

    func write(_ name: String, _ text: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove(_ name: String) throws { try FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }

    func model() -> MockModel {
        MockModel { _ in #"{"summary":"The user keeps notes about their rental and travel plans.","title":"Notes","junk":false,"sensitive":false}"# }
    }

    func pipeline(_ model: LanguageModel, store: KnowledgeStore) -> IngestPipeline {
        IngestPipeline(store: store, triager: Triager(model: model), indexer: Indexer(store: store, embedder: HashingEmbedder()))
    }

    /// Polls until `condition` holds (real file-system events arrive on their own schedule).
    func eventually(timeout: TimeInterval = 20, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return try condition()
    }

    func runtime(_ m: LanguageModel) throws -> Runtime {
        var cfg = OffloadConfig()
        cfg.folders = [dir.path]
        cfg.embedding = EmbeddingProfile(kind: .hashing)
        return try Runtime(paths: AppPaths(support: home), config: cfg, models: (m, m, m))
    }

    /// What the first cycle (or onboarding) does for a folder.
    func firstRead(_ rt: Runtime, _ m: LanguageModel) async throws -> IngestReport {
        try await IngestPipeline(store: rt.store, triager: Triager(model: m), indexer: rt.indexer).run(connectors: rt.connectors())
    }

    // MARK: - Scoped reads

    func testScopedRefsAgreeWithAFullScan() throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        try write("deep/er/b.txt", "Bravo note with enough text to pass the empty check easily.")
        try write(".hidden/c.md", "Hidden folder content that a full scan never lists at all.")
        try write("node_modules/pkg/d.md", "Dependency documentation that a full scan never lists either.")
        try write("e.bin", "unsupported extension that no listing includes")
        let connector = FilesConnector(root: dir)
        let full = try connector.scan()
        XCTAssertEqual(Set(full.map(\.key)), [path("a.md"), path("deep/er/b.txt")])

        // The whole folder, a subfolder and a single file all give exactly what the full scan gave.
        XCTAssertEqual(Set(try connector.refs(under: dir.path).map(\.key)), Set(full.map(\.key)))
        XCTAssertEqual(try connector.refs(under: path("deep")).map(\.key), [path("deep/er/b.txt")])
        let single = try XCTUnwrap(connector.refs(under: path("a.md")).first)
        let fromScan = try XCTUnwrap(full.first { $0.key == single.key })
        XCTAssertEqual(single.fingerprint, fromScan.fingerprint, "same fingerprint, or an unchanged file would be re-read")

        // Things a full scan would not list stay out, and a vanished path is simply empty.
        for ignored in [".hidden/c.md", ".hidden", "node_modules/pkg/d.md", "node_modules", "e.bin", "missing.md"] {
            XCTAssertEqual(try connector.refs(under: path(ignored)).count, 0, ignored)
        }
    }

    func testEventPathsAreMappedToTheKeysAFullScanUses() throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        let connector = FilesConnector(root: dir)
        let key = try XCTUnwrap(connector.scan().first).key
        XCTAssertEqual(key, path("a.md"), "a directory walk reports real paths (/private/var/... for a /var/... folder)")
        // FSEvents reports real paths too; a path in the form the folder was chosen maps to the same key.
        XCTAssertEqual(connector.scopedPath(for: key), key)
        XCTAssertEqual(connector.scopedPath(for: dir.path + "/a.md"), key)
        XCTAssertNil(connector.scopedPath(for: "/somewhere/else/a.md"))
        XCTAssertNil(connector.scopedPath(for: dir.path + "-sibling/a.md"), "a folder that merely shares the prefix is not inside")
        XCTAssertEqual(connector.scopedPath(for: dir.path), FilesConnector.realPath(dir.path))
        XCTAssertNil(connector.scopedPath(for: path(".git/HEAD")))
    }

    func testItemsUnderAFolderDoNotIncludeSiblingsWithTheSamePrefix() throws {
        let store = try T.store()
        for id in ["foo/a", "foo/deep/b", "foobar/c", "foo"] { try store.upsertItem(T.item(id)) }
        XCTAssertEqual(Set(try store.items(bucket: "test", under: "/tmp/foo").map(\.id)), ["foo/a", "foo/deep/b"])
        XCTAssertEqual(try store.items(bucket: "test", under: "/tmp/foo/a.txt").map(\.id), ["foo/a"])
        XCTAssertEqual(try store.items(bucket: "other", under: "/tmp/foo").count, 0)
    }

    func testOutermostDropsDuplicatesAndNestedPaths() {
        XCTAssertEqual(IngestPipeline.outermost(["/r/a", "/r/a/b.md", "/r/a", "/r/ab.md", "/r/c/d.md"]), ["/r/a", "/r/ab.md", "/r/c/d.md"])
    }

    // MARK: - Applying changes

    func testSyncAppliesOnlyTheNamedPaths() async throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        try write("b.md", "Bravo note with enough text to pass the empty check easily.")
        try write("e.md", "Echo note with enough text to pass the empty check easily.")
        let store = try T.store()
        let m = model()
        let p = pipeline(m, store: store)
        let connector = FilesConnector(root: dir)
        _ = try await p.run(connectors: [connector])
        XCTAssertEqual(m.requests.count, 3)
        let generation = store.vectorGeneration

        try write("a.md", "Alpha note, now edited and quite a bit longer than before so the size differs.")
        try remove("b.md")
        try write("c.md", "Charlie is a brand new note with enough text to pass the empty check.")
        try write("e.md", "Echo note edited too, but nobody told the index about this file at all.")

        let report = try await p.sync(paths: [path("a.md"), path("b.md"), path("c.md")], connector: connector)
        XCTAssertEqual(report.deleted, 1, "b is gone")
        XCTAssertEqual(report.survivors, 2, "a was edited and c is new")
        XCTAssertEqual(m.requests.count, 5, "e was not named, so it was not read")
        XCTAssertGreaterThan(store.vectorGeneration, generation, "the vector index must notice")

        let items = try store.items(bucket: connector.bucket)
        XCTAssertEqual(Set(items.map(\.title)), ["Notes"], "all three are survivors")
        XCTAssertEqual(items.count, 3, "a, c and the stale e")
        let texts = try items.flatMap { try store.chunks(itemID: $0.id).map(\.text) }.joined(separator: "\n")
        XCTAssertTrue(texts.contains("now edited"))
        XCTAssertTrue(texts.contains("Charlie"))
        XCTAssertFalse(texts.contains("Bravo"), "the deleted file's text must be gone")
        XCTAssertTrue(texts.contains("Echo note with enough"), "e still holds its old content")
        XCTAssertFalse(texts.contains("nobody told"))

        let counts = try store.counts()
        XCTAssertEqual(counts["vectors"], counts["chunks"], "every remaining chunk has a vector and no orphan vector is left")

        // The same paths again change nothing.
        let again = try await p.sync(paths: [path("a.md"), path("b.md"), path("c.md")], connector: connector)
        XCTAssertEqual(again.skippedUpToDate, 2)
        XCTAssertEqual(again.deleted + again.survivors, 0)
        XCTAssertEqual(m.requests.count, 5)
    }

    func testDeletingAFolderRemovesEverythingBeneathIt() async throws {
        try write("keep.md", "Kept note with enough text to pass the empty check easily.")
        try write("sub/x.md", "Xray note with enough text to pass the empty check easily.")
        try write("sub/deeper/y.md", "Yankee note with enough text to pass the empty check easily.")
        let store = try T.store()
        let connector = FilesConnector(root: dir)
        let p = pipeline(model(), store: store)
        _ = try await p.run(connectors: [connector])
        XCTAssertEqual(try store.items(bucket: connector.bucket).count, 3)

        try remove("sub")
        // FSEvents reports the folder once, not each file in it.
        let report = try await p.sync(paths: [path("sub")], connector: connector)
        XCTAssertEqual(report.deleted, 2)
        XCTAssertEqual(try store.items(bucket: connector.bucket).map(\.uri), [path("keep.md")])
        XCTAssertEqual(try store.counts()["vectors"], try store.counts()["chunks"])
    }

    func testAFolderMovedInIsIndexedAsAWhole() async throws {
        let store = try T.store()
        let connector = FilesConnector(root: dir)
        let m = model()
        let p = pipeline(m, store: store)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("offload-moved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "Zulu note with enough text to pass the empty check easily.".write(to: outside.appendingPathComponent("z.md"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: outside, to: dir.appendingPathComponent("moved"))

        let report = try await p.sync(paths: [path("moved")], connector: connector)
        XCTAssertEqual(report.survivors, 1)
        XCTAssertEqual(try store.items(bucket: connector.bucket).map(\.uri), [path("moved/z.md")])
    }

    func testAnUnreadableFolderIsAnErrorNotADeletion() async throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        let store = try T.store()
        let connector = FilesConnector(root: dir)
        let p = pipeline(model(), store: store)
        _ = try await p.run(connectors: [connector])

        // The whole folder disappears (unmounted drive): every event looks like a deletion.
        try FileManager.default.removeItem(at: dir)
        let report = try await p.sync(paths: [path("a.md")], connector: connector)
        XCTAssertFalse(report.sourceErrors.isEmpty)
        XCTAssertEqual(report.deleted, 0)
        XCTAssertEqual(try store.items(bucket: connector.bucket).count, 1)
    }

    func testAMutexRunsOneBodyAtATimeInArrivalOrder() async throws {
        let mutex = AsyncMutex()
        final class Log: @unchecked Sendable {
            let lock = NSLock(); var events: [String] = []
            func add(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
        }
        let log = Log()
        await withTaskGroup(of: Void.self) { group in
            for name in ["a", "b", "c"] {
                group.addTask {
                    await mutex.withLock {
                        log.add("start " + name)
                        try? await Task.sleep(nanoseconds: 30_000_000)
                        log.add("end " + name)
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        XCTAssertEqual(log.events, ["start a", "end a", "start b", "end b", "start c", "end c"])
    }

    // MARK: - Watching

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[String]] = []
        func add(_ b: [String]) { lock.lock(); batches.append(b); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return batches }
        var paths: [String] { all.flatMap { $0 } }
    }

    func testBurstOfEventsForOnePathIsReportedOnceAfterItSettles() async throws {
        let got = Collected()
        let watcher = FolderWatcher(roots: [dir.path], quietPeriod: 0.4) { got.add($0) }
        let flag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        for _ in 0..<3 {
            watcher.record(paths: ["/r/a.md"], flags: [flag])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(got.all.isEmpty, "still being written: nothing is reported yet")
        let settled = try await eventually(timeout: 5) { !got.all.isEmpty }
        XCTAssertTrue(settled)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(got.all, [["/r/a.md"]], "one report for the whole burst")
    }

    func testAFileThatNeverSettlesDoesNotHoldBackTheOthers() async throws {
        let got = Collected()
        let watcher = FolderWatcher(roots: [dir.path], quietPeriod: 0.3) { got.add($0) }
        let flag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        watcher.record(paths: ["/r/quiet.md"], flags: [flag])
        for _ in 0..<10 {   // a log file written every 100 ms for a second
            watcher.record(paths: ["/r/busy.log"], flags: [flag])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(got.paths, ["/r/quiet.md"], "the quiet file is reported while the busy one is still changing")
        let both = try await eventually(timeout: 5) { got.paths.contains("/r/busy.log") }
        XCTAssertTrue(both, "and the busy one follows once it stops")
    }

    func testFolderModifiedEventsAreIgnoredButStructuralOnesAreNot() {
        let dirFlag = UInt32(kFSEventStreamEventFlagItemIsDir)
        XCTAssertFalse(FolderWatcher.isRelevant(dirFlag | UInt32(kFSEventStreamEventFlagItemModified)))
        XCTAssertFalse(FolderWatcher.isRelevant(dirFlag | UInt32(kFSEventStreamEventFlagItemXattrMod)))
        XCTAssertTrue(FolderWatcher.isRelevant(dirFlag | UInt32(kFSEventStreamEventFlagItemRemoved)))
        XCTAssertTrue(FolderWatcher.isRelevant(dirFlag | UInt32(kFSEventStreamEventFlagItemRenamed)))
        XCTAssertTrue(FolderWatcher.isRelevant(dirFlag | UInt32(kFSEventStreamEventFlagItemCreated)))
        XCTAssertTrue(FolderWatcher.isRelevant(UInt32(kFSEventStreamEventFlagMustScanSubDirs)), "events were lost: rescan")
        XCTAssertTrue(FolderWatcher.isRelevant(UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)))
    }

    func testWatcherSeesRealFileSystemChanges() async throws {
        let got = Collected()
        let watcher = FolderWatcher(roots: [dir.path], quietPeriod: 0.3) { got.add($0) }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)   // let the stream settle before the first change
        try write("w.md", "Whiskey note with enough text to pass the empty check easily.")
        let seen = try await eventually { got.paths.contains { $0.hasSuffix("/w.md") } }
        XCTAssertTrue(seen, "a new file is reported")
        try remove("w.md")
        let gone = try await eventually { got.paths.filter { $0.hasSuffix("/w.md") }.count >= 2 }
        XCTAssertTrue(gone, "and so is its deletion")
        XCTAssertFalse(FolderWatcher(roots: [dir.path + "/nope"]) { _ in }.start(), "nothing to watch")
    }

    // MARK: - End to end

    func testLiveSyncKeepsTheIndexInStepWithTheFolder() async throws {
        var cfg = OffloadConfig()
        cfg.folders = [dir.path]
        cfg.embedding = EmbeddingProfile(kind: .hashing)
        let m = model()
        let rt = try Runtime(paths: AppPaths(support: home), config: cfg, models: (m, m, m))
        _ = try await firstRead(rt, m)   // an empty folder: read once, and so followed from now on
        let sync = LiveSync(runtime: rt, quietPeriod: 0.3)
        XCTAssertTrue(sync.start())
        defer { sync.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)

        func state() throws -> (items: Int, chunks: Int, vectors: Int) {
            let c = try rt.store.counts()
            return (try rt.store.items(bucket: FilesConnector(root: dir).bucket).count, c["chunks"] ?? 0, c["vectors"] ?? 0)
        }

        try write("one.md", "Lease renewal is due in March and the landlord asked for two months deposit.")
        let added = try await eventually { try state().items == 1 && state().chunks > 0 }
        XCTAssertTrue(added, "a new file is indexed without running a cycle")
        let afterAdd = try state()
        XCTAssertEqual(afterAdd.vectors, afterAdd.chunks)
        let hits = try await rt.searcher.search("landlord deposit", options: SearchOptions())
        XCTAssertFalse(hits.isEmpty, "and is searchable")

        try write("one.md", "Completely different text now about a trip to Lisbon in the autumn with friends.")
        let edited = try await eventually { try rt.store.items(bucket: FilesConnector(root: dir).bucket).first.map { try rt.store.chunks(itemID: $0.id).first?.text.contains("Lisbon") ?? false } ?? false }
        XCTAssertTrue(edited, "an edit replaces the old chunks")

        try remove("one.md")
        let removed = try await eventually { try state() == (0, 0, 0) }
        let final = try state()
        XCTAssertTrue(removed, "a deleted file leaves no item, chunk or vector behind; got \(final)")
    }

    // MARK: - Default on, startup catch-up, read-once gate

    func testLiveSyncIsOnByDefaultAndForConfigsThatPredateIt() throws {
        XCTAssertTrue(OffloadConfig().liveSync)
        let old = try JSONDecoder().decode(OffloadConfig.self, from: Data(#"{"folders":["/Users/x/Notes"],"scheduleHour":4}"#.utf8))
        XCTAssertTrue(old.liveSync)
        let off = try JSONDecoder().decode(OffloadConfig.self, from: Data(#"{"liveSync":false}"#.utf8))
        XCTAssertFalse(off.liveSync, "an explicit choice is kept")
    }

    func testAFolderCountsAsReadOnlyOnceAFullReadCompleted() async throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        try write("b.md", "Bravo note with enough text to pass the empty check easily.")
        let store = try T.store()
        let connector = FilesConnector(root: dir)
        let p = pipeline(model(), store: store)
        XCTAssertFalse(try store.hasBeenRead(bucket: connector.bucket), "never read")

        // A read cut short does not count, even though it already stored one of the two files.
        _ = try await p.run(connectors: [connector], maxItemsPerSource: 1)
        XCTAssertEqual(try store.items(bucket: connector.bucket).count, 1)
        XCTAssertFalse(try store.hasBeenRead(bucket: connector.bucket), "a half-finished first read is not resumed behind the user's back")

        _ = try await p.run(connectors: [connector])
        XCTAssertTrue(try store.hasBeenRead(bucket: connector.bucket))

        // An empty folder that was read is still "read": files added later must be followed.
        let empty = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let emptyConnector = FilesConnector(root: empty)
        XCTAssertFalse(try store.hasBeenRead(bucket: emptyConnector.bucket))
        _ = try await p.run(connectors: [emptyConnector])
        XCTAssertTrue(try store.hasBeenRead(bucket: emptyConnector.bucket))
    }

    func testAStoppedFirstReadIsNotResumedAtTheNextLaunch() async throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        try write("b.md", "Bravo note with enough text to pass the empty check easily.")
        let m = model()
        let rt = try runtime(m)
        let bucket = FilesConnector(root: dir).bucket
        _ = try await IngestPipeline(store: rt.store, triager: Triager(model: m), indexer: rt.indexer)
            .run(connectors: rt.connectors(), maxItemsPerSource: 1)   // the user pressed Stop after one file
        XCTAssertEqual(try rt.store.items(bucket: bucket).count, 1)
        let requests = m.requests.count

        let sync = LiveSync(runtime: rt, quietPeriod: 0.3)   // the next launch: watcher plus catch-up
        XCTAssertTrue(sync.start())
        defer { sync.stop() }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(try rt.store.items(bucket: bucket).count, 1, "the unread file stays unread")
        XCTAssertEqual(m.requests.count, requests)
    }

    func testDatabasesFromBeforeReadMarkersCountWhatTheyHoldAsReadExactlyOnce() throws {
        let path = home.appendingPathComponent("old.sqlite").path
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        do {
            let store = try KnowledgeStore(path: path)
            try store.upsertItem(T.item("x"))   // bucket "test"
            // Simulate a database written before markers existed.
            try store.db.run("DELETE FROM meta WHERE key LIKE 'read.%' OR key = 'migrate.read-markers'")
            XCTAssertFalse(try store.hasBeenRead(bucket: "test"))
        }
        let reopened = try KnowledgeStore(path: path)
        XCTAssertTrue(try reopened.hasBeenRead(bucket: "test"), "what it already held is trusted once")
        XCTAssertFalse(try reopened.hasBeenRead(bucket: "other"))

        // After that, content alone proves nothing.
        try reopened.upsertItem(ItemRecord(
            id: "y", bucket: "later", kind: .file, uri: "/tmp/y.txt", title: "y", itemDate: nil, fingerprint: "fp",
            summary: "s", verdict: .survivor, trust: .saved))
        XCTAssertFalse(try reopened.hasBeenRead(bucket: "later"))
        let again = try KnowledgeStore(path: path)
        XCTAssertFalse(try again.hasBeenRead(bucket: "later"), "the migration does not run a second time")
    }

    func testStartupCatchesUpOnChangesMadeWhileNothingWasWatching() async throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        try write("b.md", "Bravo note with enough text to pass the empty check easily.")
        let m = model()
        let rt = try runtime(m)
        _ = try await firstRead(rt, m)
        let bucket = FilesConnector(root: dir).bucket
        XCTAssertEqual(try rt.store.items(bucket: bucket).count, 2)

        // The app is closed: the folder changes with nobody watching.
        try write("a.md", "Alpha note, now edited and quite a bit longer than before so the size differs.")
        try remove("b.md")
        try write("c.md", "Charlie is a brand new note with enough text to pass the empty check.")
        try await Task.sleep(nanoseconds: 1_000_000_000)   // so none of the above can arrive as a live event

        let sync = LiveSync(runtime: rt, quietPeriod: 0.3)
        XCTAssertTrue(sync.start())
        defer { sync.stop() }
        func text() throws -> String { try rt.store.items(bucket: bucket).flatMap { try rt.store.chunks(itemID: $0.id).map(\.text) }.joined(separator: "\n") }
        let caughtUp = try await eventually {
            let t = try text()
            return try rt.store.items(bucket: bucket).count == 2 && t.contains("now edited") && t.contains("Charlie") && !t.contains("Bravo")
        }
        let seen = try text()
        XCTAssertTrue(caughtUp, "edit, delete and add are all picked up at start; got: \(seen)")
        let counts = try rt.store.counts()
        XCTAssertEqual(counts["vectors"], counts["chunks"])
    }

    func testWithoutTheCatchUpThoseOfflineChangesWouldWaitForTheNextCycle() async throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        let m = model()
        let rt = try runtime(m)
        _ = try await firstRead(rt, m)
        try remove("a.md")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let sync = LiveSync(runtime: rt, quietPeriod: 0.3, catchUpOnStart: false)
        XCTAssertTrue(sync.start())
        defer { sync.stop() }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(try rt.store.items(bucket: FilesConnector(root: dir).bucket).count, 1, "nothing noticed the deletion")
    }

    func testAFolderNeverReadIsNotReadBehindTheUsersBack() async throws {
        try write("a.md", "Alpha note with enough text to pass the empty check easily.")
        let m = model()
        let rt = try runtime(m)
        let bucket = FilesConnector(root: dir).bucket
        let sync = LiveSync(runtime: rt, quietPeriod: 0.3)
        XCTAssertTrue(sync.start())   // the catch-up runs, and finds a folder nobody has read yet
        defer { sync.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)
        try write("b.md", "Bravo note with enough text to pass the empty check easily.")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(m.requests.count, 0, "no file was sent to the model")
        XCTAssertEqual(try rt.store.items(bucket: bucket).count, 0)

        // The user's first read (onboarding, or a cycle) switches following on for that folder.
        _ = try await firstRead(rt, m)
        XCTAssertEqual(try rt.store.items(bucket: bucket).count, 2)
        try write("c.md", "Charlie is a brand new note with enough text to pass the empty check.")
        let followed = try await eventually { try rt.store.items(bucket: bucket).count == 3 }
        XCTAssertTrue(followed)
    }
}
