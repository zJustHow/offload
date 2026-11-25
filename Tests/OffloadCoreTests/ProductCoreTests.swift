import XCTest
@testable import OffloadCore

final class ProductCoreTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-product-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    // MARK: Vault editor

    func makeEditor() throws -> (VaultEditor, VaultWorkspace, KnowledgeStore, Box<[URL]>) {
        let ws = VaultWorkspace(root: base.appendingPathComponent("vault"))
        let staging = try ws.makeStaging()
        try ws.write(["Home/Apartment.md": "# Apartment\nRent is $3,400.\n", "README.md": "# About\nA founder."], paths: ["Home/Apartment.md", "README.md"], into: staging)
        try ws.swap(staging: staging)
        let store = try T.store()
        let trashed = Box<[URL]>([])
        let editor = VaultEditor(workspace: ws, store: store, indexer: Indexer(store: store, embedder: HashingEmbedder()),
                                 trash: { url in trashed.mutate { $0.append(url) }; try FileManager.default.removeItem(at: url) })
        return (editor, ws, store, trashed)
    }

    func testCreateSaveDeleteKeepFilesIndexAndSearchInStep() async throws {
        let (editor, ws, store, trashed) = try makeEditor()
        let path = try await editor.create(folder: "People", title: "Priya Shah")
        XCTAssertEqual(path, "People/Priya Shah.md")
        XCTAssertEqual(try ws.readAll()[path], "# Priya Shah\n\n")
        XCTAssertEqual(try store.note(path: path)?.title, "Priya Shah")

        try await editor.save(path: path, body: "# Priya Shah\n\nRuns the data pipeline migration at Acme.\n")
        XCTAssertTrue(try ws.readAll()[path]!.contains("pipeline migration"))
        let hits = try store.db.query("SELECT n.path FROM note_fts f JOIN notes n ON n.rowid = f.rowid WHERE note_fts MATCH '\"pipeline\"'", []) { $0.text(0) }
        XCTAssertEqual(hits, [path], "an edit is searchable immediately")

        try editor.delete(path: path)
        XCTAssertEqual(trashed.value.count, 1, "deleting moves to the Trash, it does not erase")
        XCTAssertNil(try ws.readAll()[path])
        XCTAssertNil(try store.note(path: path))
    }

    func testNamesAreSanitizedCollisionsRejectedAndTheOverviewIsProtected() async throws {
        let (editor, _, _, _) = try makeEditor()
        XCTAssertEqual(VaultEditor.fileName(for: "  Q3: plans / ideas?  "), "Q3 plans ideas")
        XCTAssertNil(VaultEditor.fileName(for: "///"))
        XCTAssertNil(VaultEditor.fileName(for: "..."))
        let p = try await editor.create(folder: "", title: "Loose idea")
        XCTAssertEqual(p, "Notes/Loose idea.md", "a note with no folder goes to Notes/")
        do { _ = try await editor.create(folder: "Notes", title: "loose IDEA"); XCTFail() } catch { XCTAssertTrue("\(error)".contains("already exists")) }
        do { _ = try await editor.create(folder: "../..", title: "Escape"); XCTFail() } catch { XCTAssertTrue("\(error)".contains("can't be used")) }
        do { try await editor.save(path: "README.md", body: "x"); XCTFail() } catch { XCTAssertTrue("\(error)".contains("Overview")) }
        do { try editor.delete(path: "README.md"); XCTFail() } catch { XCTAssertTrue("\(error)".contains("Overview")) }
        do { try await editor.save(path: "Home/Missing.md", body: "x"); XCTFail() } catch { XCTAssertTrue("\(error)".contains("no longer exists")) }
        do { try await editor.save(path: "../outside.md", body: "x"); XCTFail() } catch { XCTAssertTrue("\(error)".contains("can't be used")) }
    }

    /// The overnight builder refuses to swap in its result when the vault's fingerprint changed
    /// while it ran (see VaultBuilderTests). That only protects the user if *every* edit moves the
    /// fingerprint, so this is the contract the editor must keep.
    func testEveryEditMovesTheFingerprintTheBuilderChecks() async throws {
        let (editor, ws, _, _) = try makeEditor()
        let f0 = try ws.fingerprint()
        let created = try await editor.create(folder: "People", title: "Priya")
        let f1 = try ws.fingerprint(); XCTAssertNotEqual(f0, f1)
        try await editor.save(path: created, body: "# Priya\nA longer body than before, so the size differs.\n")
        let f2 = try ws.fingerprint(); XCTAssertNotEqual(f1, f2)
        try editor.delete(path: created)
        XCTAssertNotEqual(f2, try ws.fingerprint())
    }

    // MARK: Reset

    func testResetNeverTouchesSourceFilesAndSendsTheVaultToTheTrash() throws {
        let paths = AppPaths(support: base.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        for name in ["offload.sqlite", "offload.sqlite-wal", "gmail-metadata.json", "history.jsonl", "config.json"] { try Data("x".utf8).write(to: paths.support.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let vault = base.appendingPathComponent("vault"); try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("my-notes.md"); try Data("precious".utf8).write(to: source)

        let trashed = Box<[URL]>([]), secrets = Box<[String]>([]), schedule = Box<[String]>([])
        try Reset.perform([.index], paths: paths, vault: vault, trash: { u in trashed.mutate { $0.append(u) } }, removeSchedule: { schedule.append("x") }, removeSecret: { secrets.append($0) })
        let left = try FileManager.default.contentsOfDirectory(atPath: paths.support.path)
        XCTAssertEqual(left.filter { $0 != "logs" }, ["config.json"], "index-only reset keeps the settings")
        XCTAssertTrue(trashed.value.isEmpty && secrets.value.isEmpty && schedule.value.isEmpty)

        try Reset.perform(.everything, paths: paths, vault: vault, trash: { u in trashed.mutate { $0.append(u) } }, removeSchedule: { schedule.append("x") }, removeSecret: { secrets.append($0) })
        XCTAssertEqual(trashed.value, [vault], "the knowledge base is moved, not deleted")
        XCTAssertTrue(secrets.value.contains("google-oauth"))
        XCTAssertEqual(schedule.value.count, 1, "the schedule is only removed by a full reset")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.config.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.logs.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "precious", "source files are never touched")
    }

    // MARK: History, names, health

    func testHistoryKeepsTheNewestRunsAndSurvivesGarbage() throws {
        let url = base.appendingPathComponent("history.jsonl")
        let h = CycleHistory(url: url)
        XCTAssertTrue(h.recent().isEmpty)
        for i in 0..<230 {
            h.append(CycleRecord(id: "\(i)", date: Date(timeIntervalSince1970: Double(i)), seconds: 1, kept: i, skipped: 0, sensitive: 0, failed: 0, notesCreated: 0, notesChanged: 0, suggestions: 0, warnings: i == 229 ? ["w"] : [], cancelled: false))
        }
        let recent = h.recent(limit: 3)
        XCTAssertEqual(recent.map(\.id), ["229", "228", "227"], "newest first")
        XCTAssertEqual(recent[0].warnings, ["w"])
        XCTAssertLessThanOrEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 200, "bounded")
        try (String(contentsOf: url, encoding: .utf8) + "{not json}\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(h.recent(limit: 1).first?.id, "229", "a corrupt line is skipped, not fatal")
    }

    func testFriendlySourceNames() {
        XCTAssertEqual(SourceNames.friendly("files:/Users/me/Documents/Notes"), "Folder “Notes”")
        XCTAssertEqual(SourceNames.friendly("imessage"), "Messages")
        XCTAssertEqual(SourceNames.friendly("mail:/Users/me/Library/Mail"), "Apple Mail")
        XCTAssertEqual(SourceNames.friendly("calendar:google"), "Google Calendar")
        XCTAssertEqual(SourceNames.friendly("siyuan:/x"), "SiYuan")
        XCTAssertEqual(SourceNames.friendly("whatever"), "whatever")
    }

    func testFullDiskAccessProbeSeesAFolderItCannotList() throws {
        let home = base.appendingPathComponent("home")
        XCTAssertTrue(SystemHealth.hasFullDiskAccess(home: home), "nothing protected to test against")
        let safari = home.appendingPathComponent("Library/Safari")
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        XCTAssertTrue(SystemHealth.hasFullDiskAccess(home: home))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safari.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path) }
        XCTAssertFalse(SystemHealth.hasFullDiskAccess(home: home), "an unreadable protected folder means no Full Disk Access")
    }

    func testHealthReportCoversEveryCapabilityAndOnlyFlagsWhatTheChosenSourcesNeed() async {
        var cfg = OffloadConfig()
        let none = await SystemHealth.check(config: cfg)
        XCTAssertEqual(Set(none.map(\.id)), ["fda", "calendar", "screen", "accessibility", "builtin", "claude", "codex", "google"])
        XCTAssertFalse(none.contains { $0.status == .needsAction }, "nothing chosen, nothing to fix")
        cfg.calendarEnabled = true; cfg.appleNotesEnabled = true
        let some = await SystemHealth.check(config: cfg)
        if !SystemHealth.calendarAccess { XCTAssertEqual(some.first { $0.id == "calendar" }?.status, .needsAction) }
        if !SystemHealth.hasFullDiskAccess() { XCTAssertEqual(some.first { $0.id == "fda" }?.status, .needsAction) }
        XCTAssertNotNil(some.first { $0.id == "fda" }?.settingsURL)
    }

    // MARK: Cycle progress and cancellation

    func testCycleReportsStructuredProgressRecordsHistoryAndCanBeCancelled() async throws {
        let docs = base.appendingPathComponent("docs"); try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        for i in 0..<6 { try "Note \(i): the user keeps careful notes about project \(i) and the plans for the quarter.".write(to: docs.appendingPathComponent("n\(i).md"), atomically: true, encoding: .utf8) }
        try "JUNKME buy now limited offer for everything in the store this weekend only".write(to: docs.appendingPathComponent("promo.txt"), atomically: true, encoding: .utf8)
        var cfg = OffloadConfig(); cfg.folders = [docs.path]; cfg.embedding = EmbeddingProfile(kind: .hashing)
        let slow = Box<Int>(0)
        let triage = MockModel { req in
            slow.mutate { $0 += 1 }
            if req.messages.last!.text.contains("JUNKME") { return ##"{"summary":"","title":"x","junk":true,"sensitive":false}"## }
            return ##"{"summary":"The user keeps notes.","title":"Notes","junk":false,"sensitive":false}"##
        }
        let mk = { try Runtime(paths: AppPaths(support: self.base.appendingPathComponent("home")), config: cfg, models: (triage, MockModel { _ in ##"{"operations":[],"skipped":[1,2,3,4,5,6]}"## }, MockModel { _ in ##"{"candidates":[]}"## })) }
        let rt = try mk()
        let seen = Box<[CycleProgress]>([])
        let report = await rt.runCycle(progress: { p in seen.mutate { $0.append(p) } })
        XCTAssertEqual(report.ingest.survivors, 6)
        let last = seen.value.last!
        XCTAssertEqual(last.stage, .suggestions)
        let reading = seen.value.filter { $0.stage == .reading && $0.total > 0 }
        XCTAssertEqual(reading.last?.kept, 6, "running totals")
        XCTAssertEqual(reading.last?.skipped, 1)
        XCTAssertEqual(reading.last?.source, "Folder “docs”")
        XCTAssertEqual(reading.last?.done, reading.last?.total)
        XCTAssertGreaterThan(reading.first?.fraction ?? -1, 0)
        XCTAssertFalse(report.cancelled)
        let rec = try XCTUnwrap(rt.history.recent(limit: 1).first)
        XCTAssertEqual(rec.kept, 6); XCTAssertFalse(rec.cancelled); XCTAssertGreaterThan(rec.seconds, 0)

        // Cancel mid-run: items already read stay read and the next run finishes the rest.
        try FileManager.default.removeItem(at: base.appendingPathComponent("home"))
        let rt2 = try mk()
        let task = Task { await rt2.runCycle(skipVault: true, skipProactive: true, progress: { p in if p.done >= 2 { withUnsafeCurrentTask { $0?.cancel() } } }) }
        let r2 = await task.value
        XCTAssertTrue(r2.cancelled)
        XCTAssertLessThan(r2.ingest.survivors, 6)
        XCTAssertTrue(rt2.history.recent(limit: 1).first?.cancelled == true)
        let resumed = await rt2.runCycle(skipVault: true, skipProactive: true)
        XCTAssertFalse(resumed.cancelled)
        XCTAssertEqual(try rt2.store.items(bucket: "files:" + docs.path).filter { $0.verdict == .survivor }.count, 6, "everything ends up read, nothing twice")
    }

    // MARK: Dashboard wording

    func testSourceStatusNamesTheMissingPermission() {
        func st(_ b: String, fda: Bool = true, cal: Bool = true, g: Bool = true, n: Int = 5) -> (HealthItem.Status, String) {
            let r = Dashboard.sourceStatus(bucket: b, itemCount: n, hasFullDiskAccess: fda, hasCalendarAccess: cal, isSignedInToGoogle: g); return (r.status, r.detail)
        }
        XCTAssertEqual(st("applenotes", fda: false).1, "Needs Full Disk Access")
        XCTAssertEqual(st("mail:/x", fda: false).0, .needsAction)
        XCTAssertEqual(st("imessage", fda: false).0, .needsAction)
        XCTAssertEqual(st("files:/x", fda: false).0, .ok, "plain folders never need it")
        XCTAssertEqual(st("calendar:apple", cal: false).1, "Needs Calendar access")
        XCTAssertEqual(st("calendar:google", g: false).1, "Sign in to Google")
        XCTAssertEqual(st("gmail", g: false).0, .needsAction)
        XCTAssertEqual(st("gmail").1, "Up to date")
        XCTAssertEqual(st("applenotes", n: 0).1, "Not read yet")
        XCTAssertEqual(Dashboard.symbol(forBucket: "mail:/x"), "envelope")
        XCTAssertEqual(Dashboard.symbol(forBucket: "unknown"), "doc")
    }

    func testActivityTextReadsLikeAPerson() {
        func rec(kept: Int = 0, changed: Int = 0, cancelled: Bool = false, warnings: [String] = []) -> CycleRecord {
            CycleRecord(id: "x", date: Date(), seconds: 1, kept: kept, skipped: 0, sensitive: 0, failed: 0, notesCreated: 0, notesChanged: changed, suggestions: 0, warnings: warnings, cancelled: cancelled)
        }
        XCTAssertEqual(Dashboard.activityText(rec()), "Checked for new items; nothing new.")
        XCTAssertEqual(Dashboard.activityText(rec(kept: 1)), "Read 1 new item.")
        XCTAssertEqual(Dashboard.activityText(rec(kept: 18, changed: 4)), "Read 18 new items and updated 4 notes.")
        XCTAssertEqual(Dashboard.activityText(rec(kept: 2, changed: 1)), "Read 2 new items and updated 1 note.")
        XCTAssertEqual(Dashboard.activityText(rec(kept: 3, cancelled: true)), "Stopped early after reading 3 items.")
        XCTAssertTrue(Dashboard.activityText(rec(kept: 1, warnings: ["Apple Mail: permission denied"])).hasSuffix("Apple Mail: permission denied"))
    }

    func testErrorsAreTranslatedIntoNextSteps() {
        struct E: Error, CustomStringConvertible { let description: String }
        XCTAssertTrue(ErrorText.friendly(E(description: "Claude usage limit reached|123")).contains("usage limit"))
        XCTAssertTrue(ErrorText.friendly(E(description: "model unavailable: the `claude` command was not found.")).contains("isn't installed"))
        XCTAssertTrue(ErrorText.friendly(E(description: "The Internet connection appears to be offline")).contains("connection"))
        XCTAssertTrue(ErrorText.friendly(LLMError.unavailable("Apple on-device model: deviceNotEligible")).contains("Apple Intelligence"))
        XCTAssertEqual(ErrorText.friendly(E(description: "Claude is not logged in. Run `claude auth login`.")), "Claude is not logged in. Run `claude auth login`.")
        XCTAssertLessThanOrEqual(ErrorText.friendly(E(description: String(repeating: "x", count: 900))).count, 220)
        let step = AgentAction(thought: "", tool: "open_app", args: ["name": "Mail"], declaredIrreversible: false)
        XCTAssertEqual(Dashboard.stepDescription(step), "Opening Mail")
        XCTAssertEqual(Dashboard.stepDescription(AgentAction(thought: "weighing options", tool: "mystery", args: [:], declaredIrreversible: false)), "weighing options")
    }
}

final class AppLogTests: XCTestCase {
    func testWritesLinesWithLevelsAndNeverTheNewline() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("applog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AppLog()
        log.info("before configure goes to the system log only")
        log.configure(directory: dir)
        log.info("cycle finished")
        log.error("two\nlines")
        log.flush()
        let text = try String(contentsOf: dir.appendingPathComponent("app.log"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(" INFO cycle finished"))
        XCTAssertTrue(lines[1].contains(" ERROR two lines"))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("app.log").path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int), 0o600, "owner only")
    }

    func testRotatesOnceInsteadOfGrowingForever() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("applog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AppLog(); log.configure(directory: dir)
        let chunk = String(repeating: "x", count: 4000)
        for _ in 0..<400 { log.info(chunk) }     // ~1.6 MB
        log.flush()
        let fm = FileManager.default
        let size = (try fm.attributesOfItem(atPath: dir.appendingPathComponent("app.log").path)[.size] as? Int) ?? 0
        XCTAssertLessThan(size, AppLog.maxBytes + 5000)
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("app.log.1").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("app.log.2").path))
    }

    func testSurvivesTheLogDirectoryBeingDeleted() throws {   // "Remove all data" deletes logs/ while the app keeps running
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("applog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AppLog(); log.configure(directory: dir)
        log.info("one"); log.flush()
        try FileManager.default.removeItem(at: dir)
        log.info("two"); log.flush()
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("app.log"), encoding: .utf8).contains("two"))
    }
}
