import XCTest
@testable import OffloadCore

final class VaultOpsTests: XCTestCase {
    func testPathNormalizationBlocksEscapesAndHiddenFiles() {
        XCTAssertEqual(VaultOps.normalizePath("Work/Acme.md"), "Work/Acme.md")
        XCTAssertEqual(VaultOps.normalizePath("Work/Acme"), "Work/Acme.md", "extension is added")
        XCTAssertEqual(VaultOps.normalizePath("./Work\\Acme.md"), "Work/Acme.md")
        for bad in ["../evil.md", "Work/../../evil.md", "/etc/passwd.md", "~/x.md", ".hidden/x.md", "Work/.secret.md", "a/b/\u{0}c.md", "Work/a:b.md", "", "  ", "Work/a|b.md"] {
            XCTAssertNil(VaultOps.normalizePath(bad), "must reject: \(bad.debugDescription)")
        }
    }

    func testParseToleratesVerbAliasesAndBadEntries() {
        let raw = "```json\n{\"operations\":[{\"op\":\"New\",\"path\":\"A/B.md\",\"content\":\"# B\\nx\",\"evidence\":[1,\"2\"]},{\"op\":\"explode\",\"path\":\"A/C.md\",\"content\":\"x\"},{\"op\":\"append\",\"path\":\"A/B.md\"}]}\n```"
        let ops = VaultOps.parse(raw)!
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].kind, .create)
        XCTAssertEqual(ops[0].evidence, [1, 2])
        XCTAssertNil(VaultOps.parse("sorry I cannot"))
        XCTAssertEqual(VaultOps.parse(#"{"operations":[]}"#)?.count, 0)
    }

    func testVerbsAreRepairedWhenIntentIsObvious() {
        var notes = ["Work/Acme.md": "# Acme\nFounded 2020.\n"]
        let r = VaultOps.apply([
            VaultOperation(kind: .create, path: "Work/Acme.md", content: "# Acme\nRaised a Series A."),   // create on existing -> append
            VaultOperation(kind: .append, path: "Work/New.md", content: "# New\nBrand new note."),       // append to missing + heading -> create
            VaultOperation(kind: .append, path: "Work/Ghost.md", content: "no heading, no target"),       // append to missing, no heading -> create with a derived heading
            VaultOperation(kind: .rewrite, path: "Work/Other.md", content: "# Other\nbody"),             // rewrite missing -> create
        ], to: &notes)
        XCTAssertTrue(notes["Work/Acme.md"]!.contains("Founded 2020."), "existing content must be kept")
        XCTAssertTrue(notes["Work/Acme.md"]!.contains("Series A"))
        XCTAssertEqual(notes["Work/Acme.md"]!.components(separatedBy: "# Acme").count, 2, "duplicate heading must be stripped")
        XCTAssertNotNil(notes["Work/New.md"])
        XCTAssertNotNil(notes["Work/Other.md"])
        XCTAssertEqual(notes["Work/Ghost.md"], "# Ghost\n\nno heading, no target\n", "heading derived from the file name")
        XCTAssertTrue(r.rejected.isEmpty)
    }

    func testAppendIsIdempotent() {
        var notes = ["A/Note.md": "# Note\nFirst paragraph.\n\nSecond paragraph.\n"]
        let op = VaultOperation(kind: .append, path: "A/Note.md", content: "second   PARAGRAPH.\n\nA genuinely new fact.\n\nA genuinely new fact.")
        let r = VaultOps.apply([op, op], to: &notes)
        XCTAssertEqual(notes["A/Note.md"]!.components(separatedBy: "genuinely new fact").count, 2, "added exactly once")
        XCTAssertEqual(notes["A/Note.md"]!.components(separatedBy: "econd").count, 2, "existing paragraph not repeated")
        XCTAssertEqual(r.applied.count, 1)
        XCTAssertEqual(r.rejected.map(\.reason), [.emptyContent], "re-applying the same append is a no-op, not a duplicate")
    }

    func testDedupeSeesParagraphsThatShareAHeadingLine() {
        var notes = ["Home/Apartment.md": "# Apartment\nLeases on Mission Street from Mr. Alvarez.\n"]
        let r = VaultOps.apply([VaultOperation(kind: .create, path: "Home/Apartment.md", content: "# Apartment\nLeases on Mission Street from Mr. Alvarez.")], to: &notes)
        XCTAssertEqual(notes["Home/Apartment.md"]!.components(separatedBy: "Mission Street").count, 2, "the same fact is not added twice")
        XCTAssertEqual(r.rejected.map(\.reason), [.emptyContent])
    }

    func testCollapseDuplicatesKeepsFirstOccurrenceAndStructure() {
        let messy = "# Trip\nPlans a Japan trip in April with three nights in Kyoto.\n\n- Reserve the Shinkansen seats a month ahead.\n- Kyoto has three nights at a ryokan with an onsen.\n\nPlans a Japan trip in April with three nights in Kyoto.\n\n- Reserve the Shinkansen seats a month ahead.\n- A genuinely new item about Osaka hotels.\n"
        let out = VaultOps.collapseDuplicates(in: messy)
        XCTAssertEqual(out.components(separatedBy: "Japan trip").count, 2)
        XCTAssertEqual(out.components(separatedBy: "Shinkansen").count, 2)
        XCTAssertTrue(out.hasPrefix("# Trip"))
        XCTAssertTrue(out.contains("Osaka hotels"))
        XCTAssertTrue(out.contains("onsen"))
        XCTAssertEqual(VaultOps.collapseDuplicates(in: out), out, "idempotent")
    }

    func testLimitsAndGuards() {
        var limits = VaultLimits(); limits.maxNotes = 2; limits.maxRootFolders = 1
        var notes = ["A/One.md": "# One\nbody body body body body body\n"]
        let r = VaultOps.apply([
            VaultOperation(kind: .create, path: "README.md", content: "# x"),
            VaultOperation(kind: .create, path: "Root note.md", content: "# Root note\nx"),
            VaultOperation(kind: .create, path: "B/Other root.md", content: "# Other root\nx"),
            VaultOperation(kind: .create, path: "A/One copy.md", content: "# One\nsame title as another note"),
            VaultOperation(kind: .rewrite, path: "A/One.md", content: "# One\nx"),
            VaultOperation(kind: .create, path: "A/Two.md", content: "# Two\nfits"),
            VaultOperation(kind: .create, path: "A/Three.md", content: "# Three\nover the cap"),
            VaultOperation(kind: .create, path: "A/B/C/D/Deep.md", content: "# Deep\nx"),
            VaultOperation(kind: .create, path: "A/Empty.md", content: "   "),
        ], to: &notes, limits: limits)
        XCTAssertEqual(r.rejected.map(\.reason), [.invalidPath, .rootNote, .tooManyFolders, .duplicateTitle, .shrinksTooMuch, .tooManyNotes, .tooDeep, .emptyContent])
        XCTAssertEqual(Set(notes.keys), ["A/One.md", "A/Two.md"])
    }

    func testLinkCleanupResolvesTitlesStemsAliasesAndRemovesDanglingLinks() {
        let notes = ["People/Priya Shah.md": "# Priya\nx", "Work/Acme.md": "# Acme Corp\nx"]
        let text = "See [[Priya]], [[Acme Corp|the company]], [[Acme#Funding]], [[Priya Shah]], [[Nobody Here]] and [[Ghost|a ghost]]."
        let out = VaultOps.cleanLinks(in: text, existing: notes)
        XCTAssertTrue(out.contains("[[Priya]]"))
        XCTAssertTrue(out.contains("[[Acme Corp|the company]]"))
        XCTAssertTrue(out.contains("[[Acme#Funding]]"))
        XCTAssertTrue(out.contains("[[Priya Shah]]"))
        XCTAssertFalse(out.contains("[[Nobody Here]]"))
        XCTAssertTrue(out.contains("Nobody Here"))
        XCTAssertTrue(out.contains("a ghost") && !out.contains("[[Ghost"))
    }
}

final class VaultWorkspaceTests: XCTestCase {
    var base: URL!
    var ws: VaultWorkspace!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        ws = VaultWorkspace(root: base.appendingPathComponent("vault"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func testStagingIsIsolatedAndSwapIsAtomicReplacement() throws {
        let first = try ws.makeStaging()
        try ws.write(["A/One.md": "# One\nv1"], paths: ["A/One.md"], into: first)
        try ws.swap(staging: first)
        XCTAssertEqual(try ws.readAll()["A/One.md"], "# One\nv1")

        // Hidden support files (the writing-style snapshot) must survive a staged round trip.
        try "style".write(to: ws.root.appendingPathComponent(".writingstyle.md"), atomically: true, encoding: .utf8)
        let staging = try ws.makeStaging()
        try ws.write(["A/One.md": "# One\nv2", "A/Two.md": "# Two\nnew"], paths: ["A/One.md", "A/Two.md"], into: staging)
        XCTAssertEqual(try ws.readAll()["A/One.md"], "# One\nv1", "live vault must not change while staging is edited")
        try ws.swap(staging: staging)
        XCTAssertEqual(try ws.readAll()["A/One.md"], "# One\nv2")
        XCTAssertEqual(try ws.readAll().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ws.root.appendingPathComponent(".writingstyle.md").path))
        XCTAssertNil(try ws.readAll().keys.first { $0.contains("writingstyle") }, "hidden files are not notes")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix(".offload-staging") }
        XCTAssertTrue(leftovers.isEmpty, "swap must consume the staging directory")
    }

    func testFingerprintDetectsEditsAdditionsAndDeletions() throws {
        let s = try ws.makeStaging()
        try ws.write(["A/One.md": "# One\nx"], paths: ["A/One.md"], into: s)
        try ws.swap(staging: s)
        let f0 = try ws.fingerprint()
        XCTAssertEqual(try ws.fingerprint(), f0, "stable when nothing changes")
        try "# One\nedited by the user, longer".write(to: ws.root.appendingPathComponent("A/One.md"), atomically: true, encoding: .utf8)
        let f1 = try ws.fingerprint()
        XCTAssertNotEqual(f0, f1)
        try "# Two".write(to: ws.root.appendingPathComponent("A/Two.md"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(f1, try ws.fingerprint())
    }

    func testWriteRefusesUnsafePathsLoudlyAndWritesNothing() throws {
        let s = try ws.makeStaging()
        XCTAssertThrowsError(try ws.write(["../escaped.md": "x", "A/ok.md": "# ok"], paths: ["A/ok.md", "../escaped.md"], into: s)) { error in
            XCTAssertTrue("\(error)".contains("outside the knowledge base"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.deletingLastPathComponent().appendingPathComponent("escaped.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.appendingPathComponent("A/ok.md").path), "validation happens before any write")
        ws.discard(staging: s)
    }

    /// Regression: `/tmp` and `/private/tmp` name the same place but standardize differently for
    /// files that do not exist yet. A containment check built on that silently dropped every write.
    func testWorksUnderSymlinkedTempPrefixes() throws {
        for prefix in ["/private/tmp", "/tmp"] {
            let root = URL(fileURLWithPath: "\(prefix)/offload-prefix-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let w = VaultWorkspace(root: root.appendingPathComponent("vault"))
            let staging = try w.makeStaging()
            let notes = ["Home/A.md": "# A\nx", "README.md": "# About"]
            try w.write(notes, paths: Array(notes.keys), into: staging)
            XCTAssertEqual(try w.readAll(in: staging).keys.sorted(), ["Home/A.md", "README.md"], prefix)
            try w.swap(staging: staging)
            XCTAssertEqual(try w.readAll().keys.sorted(), ["Home/A.md", "README.md"], prefix)
            XCTAssertNotEqual(try w.fingerprint(), "empty", prefix)
        }
    }

    func testReadAllSkipsSymlinks() throws {
        let s = try ws.makeStaging()
        try ws.write(["A/ok.md": "# ok"], paths: ["A/ok.md"], into: s)
        let outside = base.appendingPathComponent("outside.md")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: s.appendingPathComponent("A/link.md"), withDestinationURL: outside)
        try ws.swap(staging: s)
        XCTAssertEqual(Set(try ws.readAll().keys), ["A/ok.md"])
    }

    func testReadmeMapLinksEveryNote() {
        let readme = VaultREADME.render(portrait: "A person.", notes: ["Work/Acme.md": "# Acme Corp\nSeries A.", "Home/Flat.md": "# Flat\nRented.", "README.md": "old"])
        XCTAssertTrue(readme.contains("[[Acme Corp]] — Series A."))
        XCTAssertTrue(readme.contains("### Home"))
        XCTAssertFalse(readme.contains("old"))
    }
}
