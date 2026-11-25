import XCTest
@testable import OffloadCore

/// Thread-safe call recorder for scripted models.
final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var mergePrompts: [String] = []
    private(set) var portraitCalls = 0
    var onMerge: (@Sendable () -> Void)?
    var mergeReply: @Sendable (Int, String) -> String = { _, _ in #"{"operations":[]}"# }
    func recordMerge(_ p: String) -> Int { lock.lock(); defer { lock.unlock() }; mergePrompts.append(p); return mergePrompts.count }
    func recordPortrait() { lock.lock(); portraitCalls += 1; lock.unlock() }
}

final class VaultBuilderTests: XCTestCase {
    var base: URL!
    var ws: VaultWorkspace!
    var store: KnowledgeStore!
    let script = Script()

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-vb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        ws = VaultWorkspace(root: base.appendingPathComponent("vault"))
        store = try T.store()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func model() -> MockModel {
        let script = self.script
        return MockModel(contextChars: 60_000) { req in
            let system = req.messages.first?.text ?? ""
            let user = req.messages.last?.text ?? ""
            if system.contains("opening portrait") { script.recordPortrait(); return "The user is a founder who rents an apartment and travels often for work." }
            let n = script.recordMerge(user)
            script.onMerge?()
            return script.mergeReply(n, user)
        }
    }

    func builder(_ m: LanguageModel) -> VaultBuilder { VaultBuilder(store: store, model: m, embedder: HashingEmbedder(), workspace: ws) }

    @discardableResult
    func addItem(_ id: String, title: String, summary: String, trust: Trust = .authored) throws -> ItemRecord {
        let item = ItemRecord(id: id, bucket: "b", kind: .file, uri: "/\(id)", title: title, itemDate: Date(), fingerprint: "f-\(id)", summary: summary, verdict: .survivor, trust: trust)
        try store.commitItem(item, chunkTexts: ["raw text of \(title)"])
        return item
    }

    func testFirstBuildCreatesNotesPortraitProvenanceAndMarksMerged() async throws {
        try addItem("lease", title: "Lease", summary: "The user rents an apartment on Mission Street for $3,400 a month.")
        try addItem("acme", title: "Acme", summary: "The user is raising a Series A for Acme.")
        try addItem("promo", title: "Gym promo", summary: "Gym offers a discount.", trust: .saved)
        script.mergeReply = { _, prompt in
            // Find the evidence numbers by title so the test does not depend on item order.
            func num(_ title: String) -> Int { prompt.components(separatedBy: "\n").compactMap { l -> Int? in
                guard l.hasPrefix("#"), l.contains("· \(title)") else { return nil }
                return Int(l.dropFirst().prefix { $0.isNumber }) }.first ?? 0 }
            return """
            {"operations":[
              {"op":"create","path":"Home/Apartment.md","content":"# Apartment\\nRents on Mission Street, $3,400 a month. See [[Acme]] and [[Nonexistent]].","evidence":[\(num("Lease"))]},
              {"op":"create","path":"Work/Acme.md","content":"# Acme\\nRaising a Series A.","evidence":[\(num("Acme"))]},
              {"op":"create","path":"../../escape.md","content":"# Evil\\nx","evidence":[1]}
            ],"skipped":[\(num("Gym promo"))]}
            """
        }
        let report = try await builder(model()).update()

        XCTAssertEqual(report.considered, 3)
        XCTAssertEqual(report.created, 2)
        XCTAssertEqual(report.rejected["invalidPath"], 1, "the path-traversal attempt must be rejected")
        XCTAssertTrue(report.portraitUpdated)
        XCTAssertNil(report.abortedReason)

        let notes = try ws.readAll()
        XCTAssertEqual(Set(notes.keys), ["Home/Apartment.md", "Work/Acme.md", "README.md"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("escape.md").path))
        XCTAssertTrue(notes["Home/Apartment.md"]!.contains("[[Acme]]"))
        XCTAssertFalse(notes["Home/Apartment.md"]!.contains("[[Nonexistent]]"), "dangling links are removed")
        XCTAssertTrue(notes["README.md"]!.contains("founder"))
        XCTAssertTrue(notes["README.md"]!.contains("[[Apartment]]"), "map links every note")

        // Provenance: each note points back at the item(s) it was built from.
        XCTAssertEqual(try store.evidenceItems(notePath: "Home/Apartment.md").map(\.id), ["lease"])
        XCTAssertEqual(try store.evidenceItems(notePath: "Work/Acme.md").map(\.id), ["acme"])
        // The notes are searchable straight away, and every considered item is merged (the
        // promo was judged not durable, which is a valid outcome that must not be retried forever).
        XCTAssertEqual(try store.notePaths().sorted(), ["Home/Apartment.md", "README.md", "Work/Acme.md"])
        XCTAssertTrue(try store.unmergedSurvivors().isEmpty)

        // Nothing pending: a second run must not call the model at all.
        let before = script.mergePrompts.count
        let again = try await builder(model()).update()
        XCTAssertEqual(again.considered, 0)
        XCTAssertEqual(script.mergePrompts.count, before)
    }

    func testUpdateShowsRelatedExistingNotesAndPreservesUserEdits() async throws {
        try addItem("lease", title: "Lease", summary: "The user rents an apartment on Mission Street.")
        script.mergeReply = { _, _ in ##"{"operations":[{"op":"create","path":"Home/Apartment.md","content":"# Apartment\nRents on Mission Street.","evidence":[1]}]}"## }
        _ = try await builder(model()).update()

        // The user improves a note by hand.
        let noteURL = ws.root.appendingPathComponent("Home/Apartment.md")
        try "# Apartment\nRents on Mission Street.\n\nMY OWN EDIT: landlord is picky about plants.\n".write(to: noteURL, atomically: true, encoding: .utf8)

        try addItem("lease2", title: "Lease renewal", summary: "The user renewed the Mission Street apartment lease for another year.")
        script.mergeReply = { _, _ in ##"{"operations":[{"op":"append","path":"Home/Apartment.md","content":"Lease renewed for another year.","evidence":[1]}]}"## }
        let report = try await builder(model()).update()

        let prompt = script.mergePrompts.last!
        XCTAssertTrue(prompt.contains("Home/Apartment.md"), "existing note paths are listed")
        XCTAssertTrue(prompt.contains("MY OWN EDIT"), "related notes are retrieved and shown to the model, including the user's edits")
        let text = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(text.contains("MY OWN EDIT"), "user edits must survive an update")
        XCTAssertTrue(text.contains("Lease renewed"))
        XCTAssertEqual(report.created, 0)
        XCTAssertEqual(Set(try store.evidenceItems(notePath: "Home/Apartment.md").map(\.id)), ["lease", "lease2"], "evidence accumulates")
    }

    func testEditDuringRunAbortsTheSwapAndKeepsItemsPending() async throws {
        try addItem("a", title: "A", summary: "The user does something notable here.")
        script.mergeReply = { _, _ in ##"{"operations":[{"op":"create","path":"Misc/A.md","content":"# A\nnotable","evidence":[1]}]}"## }
        _ = try await builder(model()).update()
        try addItem("b", title: "B", summary: "The user does another notable thing.")
        let liveNote = ws.root.appendingPathComponent("Misc/A.md")
        let edited = "# A\nEDITED WHILE THE MODEL WAS THINKING\n"
        script.onMerge = { try? edited.write(to: liveNote, atomically: true, encoding: .utf8) }
        script.mergeReply = { _, _ in ##"{"operations":[{"op":"append","path":"Misc/A.md","content":"more","evidence":[1]}]}"## }

        let report = try await builder(model()).update()
        XCTAssertNotNil(report.abortedReason)
        XCTAssertEqual(try String(contentsOf: liveNote, encoding: .utf8), edited, "the user's edit must not be clobbered")
        XCTAssertEqual(try store.unmergedSurvivors().map(\.id), ["b"], "aborted work is retried later")
    }

    func testUnparseableModelOutputLeavesEverythingUntouchedAndRetryable() async throws {
        try addItem("a", title: "A", summary: "The user does something notable here.")
        script.mergeReply = { _, _ in "I'm sorry, I can't produce JSON today." }
        let report = try await builder(model()).update()
        XCTAssertEqual(report.failedBatches, 1)
        XCTAssertEqual(script.mergePrompts.count, 2, "one retry with a stricter instruction")
        XCTAssertTrue(script.mergePrompts[1].contains("not valid JSON"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.root.path), "no vault is created from nothing")
        XCTAssertEqual(try store.unmergedSurvivors().count, 1)
    }

    func testItemsTheModelDidNotAccountForAreRetriedThenGivenUp() async throws {
        try addItem("a", title: "A", summary: "The user does something notable here.")
        // The model returns a valid reply that mentions neither evidence number nor "skipped".
        script.mergeReply = { _, _ in #"{"operations":[]}"# }
        for attempt in 1...3 {
            let report = try await builder(model()).update()
            XCTAssertEqual(report.deferred, attempt < 3 ? 1 : 0, "attempt \(attempt)")
            XCTAssertEqual(report.gaveUp, attempt == 3 ? 1 : 0, "attempt \(attempt)")
        }
        XCTAssertTrue(try store.unmergedSurvivors().isEmpty, "after three ignored attempts the item stops coming back")
        // A *changed* item starts over.
        try store.upsertItem(ItemRecord(id: "a", bucket: "b", kind: .file, uri: "/a", title: "A", itemDate: nil, fingerprint: "new", summary: "The user edited the file.", verdict: .survivor, trust: .authored))
        XCTAssertEqual(try store.unmergedSurvivors().count, 1)
    }

    func testEvidenceCitedOnlyByRejectedOperationsStaysPending() async throws {
        try addItem("a", title: "A", summary: "The user does something notable here.")
        script.mergeReply = { _, _ in ##"{"operations":[{"op":"create","path":"../../etc/evil.md","content":"# Evil\nx","evidence":[1]}]}"## }
        let report = try await builder(model()).update()
        XCTAssertEqual(report.rejected["invalidPath"], 1)
        XCTAssertEqual(report.deferred, 1)
        XCTAssertEqual(try store.unmergedSurvivors().count, 1, "information the model tried to record, but could not, must not be dropped")
    }

    func testSmallContextsGetSmallBatches() throws {
        let items = (0..<10).map { i in ItemRecord(id: "i\(i)", bucket: "b", kind: .file, uri: "/", title: "T\(i)", itemDate: nil, fingerprint: "f", summary: "short", verdict: .survivor, trust: .saved) }
        XCTAssertEqual(VaultBuilder.slice(items, budget: 100_000, maxItems: 2).map(\.count), [2, 2, 2, 2, 2])
    }

    func testBatchingNeverSplitsItemsAndRespectsBudget() throws {
        let items = (0..<40).map { i in
            ItemRecord(id: "i\(i)", bucket: "b", kind: .file, uri: "/", title: "Item \(i)", itemDate: nil, fingerprint: "f", summary: String(repeating: "word ", count: 60), verdict: .survivor, trust: .saved)
        }
        let batches = VaultBuilder.slice(items, budget: 3_000)
        XCTAssertGreaterThan(batches.count, 3)
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), items.map(\.id), "order preserved, nothing lost or duplicated")
        for b in batches {
            let size = b.enumerated().reduce(0) { $0 + VaultBuilder.render($1.element, number: $1.offset + 1).count }
            XCTAssertLessThanOrEqual(size, 3_000 + 400)
        }
    }

    func testMergePromptCarriesTrustTagsAndAttributionRules() {
        let item = ItemRecord(id: "x", bucket: "b", kind: .file, uri: "/", title: "Saved article", itemDate: Date(timeIntervalSince1970: 946_728_000), fingerprint: "f", summary: "An article about X.", verdict: .survivor, trust: .saved)
        let prompt = VaultBuilder.mergePrompt(batch: [item], notes: [:], related: [], limits: VaultLimits(), budget: 20_000)
        XCTAssertTrue(prompt.contains("#1 [SAVED] file · Saved article · file modified 2000-01-01"))
        XCTAssertTrue(VaultBuilder.mergeSystemPrompt.contains("Never present it as the person's own life"))
        XCTAssertTrue(VaultBuilder.mergeSystemPrompt.contains("never compute calendar dates"))
    }
}
