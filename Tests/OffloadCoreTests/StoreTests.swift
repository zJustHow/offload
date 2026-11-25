import XCTest
@testable import OffloadCore

final class StoreTests: XCTestCase {
    func ftsIDs(_ s: KnowledgeStore, _ q: String) throws -> [Int64] {
        let fts = s.tokenizer.ftsQuery(q)!
        return try s.db.query("SELECT rowid FROM chunk_fts WHERE chunk_fts MATCH ?", [.text(fts)]) { $0.int(0) }
    }

    func testChunksAreSearchableAndReplacedCleanly() throws {
        let s = try T.store()
        try s.upsertItem(T.item("a"))
        try s.replaceChunks(itemID: "a", texts: ["the lease deposit is two months", "unrelated gardening notes"])
        XCTAssertEqual(try ftsIDs(s, "deposit").count, 1)
        // Replacing must remove stale index entries, not just add new ones.
        try s.replaceChunks(itemID: "a", texts: ["completely different content about sailing"])
        XCTAssertEqual(try ftsIDs(s, "deposit").count, 0)
        XCTAssertEqual(try ftsIDs(s, "sailing").count, 1)
    }

    func testDeletingItemCascadesToChunksIndexesAndVectors() async throws {
        let s = try T.store()
        let idx = try await T.ingest([("a", "rental agreement clause seven about pets")], into: s, embedder: HashingEmbedder())
        XCTAssertEqual(try ftsIDs(s, "pets").count, 1)
        XCTAssertEqual(try s.counts()["vectors"], 1)
        _ = idx
        try s.deleteItem(id: "a")
        XCTAssertEqual(try ftsIDs(s, "pets").count, 0, "FTS entries must be removed by the cascade")
        XCTAssertEqual(try s.counts()["chunks"], 0)
        XCTAssertEqual(try s.counts()["vectors"], 0)
        let tri = try s.db.query("SELECT rowid FROM chunk_tri WHERE chunk_tri MATCH '\"clause\"'", []) { $0.int(0) }
        XCTAssertEqual(tri.count, 0)
    }

    func testIsUpToDateTracksFingerprintAndFailures() throws {
        let s = try T.store()
        XCTAssertFalse(try s.isUpToDate(id: "x", fingerprint: "f1"))
        try s.upsertItem(T.item("x", fingerprint: "f1"))
        XCTAssertTrue(try s.isUpToDate(id: "x", fingerprint: "f1"))
        XCTAssertFalse(try s.isUpToDate(id: "x", fingerprint: "f2"))
        try s.upsertItem(T.item("x", verdict: .failed, fingerprint: "f1"))
        XCTAssertFalse(try s.isUpToDate(id: "x", fingerprint: "f1"), "failed items must be retried")
    }

    func testMergeStateLifecycle() throws {
        let s = try T.store()
        try s.upsertItem(T.item("a", fingerprint: "1"))
        try s.upsertItem(T.item("junk", verdict: .junk))
        XCTAssertEqual(try s.unmergedSurvivors().map(\.id), ["a"])
        try s.markMerged(ids: ["a"], at: Date().addingTimeInterval(1))
        XCTAssertTrue(try s.unmergedSurvivors().isEmpty)
        // Re-saving identical content keeps it merged...
        try s.upsertItem(T.item("a", fingerprint: "1"))
        XCTAssertTrue(try s.unmergedSurvivors().isEmpty)
        // ...but changed content makes it pending again.
        try s.upsertItem(T.item("a", fingerprint: "2"))
        XCTAssertEqual(try s.unmergedSurvivors().map(\.id), ["a"])
    }

    func testNoteIndexingSkipsUnchangedAndReplacesChanged() async throws {
        let s = try T.store()
        let idx = Indexer(store: s, embedder: HashingEmbedder())
        try await idx.indexNote(path: "Work/Acme.md", body: "# Acme\nFundraising round led by Orion")
        XCTAssertEqual(try s.note(path: "Work/Acme.md")?.title, "Acme")
        try await idx.embedPending()
        XCTAssertEqual(try s.notesNeedingVectors().count, 0)
        try await idx.indexNote(path: "Work/Acme.md", body: "# Acme\nFundraising round led by Orion")
        XCTAssertEqual(try s.notesNeedingVectors().count, 0, "unchanged content must keep its vector")
        try await idx.indexNote(path: "Work/Acme.md", body: "# Acme\nNow profitable")
        XCTAssertEqual(try s.notesNeedingVectors().count, 1, "changed content must be re-embedded")
        let hit = try s.db.query("SELECT n.path FROM note_fts f JOIN notes n ON n.rowid=f.rowid WHERE note_fts MATCH '\"profitable\"'", []) { $0.text(0) }
        XCTAssertEqual(hit, ["Work/Acme.md"])
        let stale = try s.db.query("SELECT rowid FROM note_fts WHERE note_fts MATCH '\"orion\"'", []) { $0.int(0) }
        XCTAssertTrue(stale.isEmpty)
    }

    func testEvidenceIgnoresUnknownItemsAndFollowsDeletion() throws {
        let s = try T.store()
        try s.upsertItem(T.item("a"))
        try s.addEvidence(notePath: "N.md", itemIDs: ["a", "does-not-exist"])
        XCTAssertEqual(try s.evidenceItems(notePath: "N.md").map(\.id), ["a"])
        try s.deleteItem(id: "a")
        XCTAssertTrue(try s.evidenceItems(notePath: "N.md").isEmpty)
    }

    func testTokenizerConfigIsPinnedInTheDatabase() throws {
        let db = try Database.inMemory()
        _ = try KnowledgeStore(db: db, tokenizer: LexicalTokenizer(includeCJKBigrams: false))
        let again = try KnowledgeStore(db: db, tokenizer: LexicalTokenizer(includeCJKBigrams: true))
        XCTAssertFalse(again.tokenizer.includeCJKBigrams, "index format must not change under an existing database")
    }
}
