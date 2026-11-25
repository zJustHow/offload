import XCTest
@testable import OffloadCore

final class NotesSiYuanTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("offload-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: protobuf / gzip helpers (build real wire-format bytes)

    func varint(_ v: Int) -> Data {
        var out = Data(), n = UInt64(v)
        repeat { var b = UInt8(n & 0x7F); n >>= 7; if n != 0 { b |= 0x80 }; out.append(b) } while n != 0
        return out
    }
    func field(_ number: Int, _ payload: Data) -> Data { varint(number << 3 | 2) + varint(payload.count) + payload }
    func noteProto(_ text: String) -> Data {
        // NoteStoreProto { document = 2 { version = 2 (varint), note = 3 { note_text = 2, attribute_run = 5 } } }
        let note = field(2, Data(text.utf8)) + field(5, Data([0x08, 0x05]))
        let doc = varint(2 << 3) + varint(1) + field(3, note)
        return field(2, doc) + varint(1 << 3) + varint(7)
    }
    func gzipViaSystemTool(_ data: Data) async throws -> Data {
        let r = try await Subprocess.run(executable: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-c"], stdin: data, timeout: 20)
        XCTAssertEqual(r.status, 0)
        return r.stdout
    }

    func testGzipReadsRealGzipOutputIncludingHeaderVariants() async throws {
        let original = Data(String(repeating: "Hello notes 你好 ", count: 200).utf8)
        let gz = try await gzipViaSystemTool(original)
        XCTAssertEqual(try Gzip.decompress(gz), original)
        // A header with a file name (gzip without -n) has extra bytes to skip.
        let named = tmp.appendingPathComponent("named.txt"); try original.write(to: named)
        let r = try await Subprocess.run(executable: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-c", named.path], timeout: 20)
        XCTAssertEqual(try Gzip.decompress(r.stdout), original)
        XCTAssertThrowsError(try Gzip.decompress(Data("not gzip at all, just text bytes".utf8)))
        XCTAssertThrowsError(try Gzip.decompress(gz.prefix(15)), "truncated stream")
    }

    func testProtobufTextExtractionSkipsOtherFieldsAndSurvivesGarbage() {
        XCTAssertEqual(ProtoReader.noteText(from: noteProto("Title\nBody 中文 text")), "Title\nBody 中文 text")
        XCTAssertNil(ProtoReader.noteText(from: Data([0xFF, 0xFF, 0xFF])))
        XCTAssertNil(ProtoReader.noteText(from: Data()))
        // A length that claims more bytes than exist must not crash or read past the buffer.
        XCTAssertNil(ProtoReader.noteText(from: Data([0x12, 0x7F, 0x01])))
    }

    // MARK: Apple Notes

    func makeNotesDB(includePasswordColumn: Bool = true) async throws -> URL {
        let url = tmp.appendingPathComponent("NoteStore.sqlite")
        let db = try Database(path: url.path)
        try db.exec("""
        CREATE TABLE ZICCLOUDSYNCINGOBJECT(Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZTITLE1 TEXT, ZTITLE2 TEXT, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER, ZNOTEDATA INTEGER, ZMODIFICATIONDATE1 REAL, ZCREATIONDATE1 REAL, ZMARKEDFORDELETION INTEGER\(includePasswordColumn ? ", ZISPASSWORDPROTECTED INTEGER" : ""));
        CREATE TABLE ZICNOTEDATA(Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB);
        INSERT INTO ZICCLOUDSYNCINGOBJECT(Z_PK, ZTITLE2, ZFOLDERTYPE) VALUES (1, 'Work', 0), (2, 'Recently Deleted', 1);
        """)
        func note(_ pk: Int, id: String, title: String, text: String, folder: Int, deleted: Int = 0, locked: Int = 0, compressed: Bool = true) async throws {
            let proto = noteProto(text)
            let blob = compressed ? try await gzipViaSystemTool(proto) : proto
            try db.run("INSERT INTO ZICNOTEDATA(Z_PK, ZNOTE, ZDATA) VALUES(?,?,?)", [.int(pk), .int(pk), .blob(blob)])
            var cols = "Z_PK,ZIDENTIFIER,ZTITLE1,ZFOLDER,ZNOTEDATA,ZMODIFICATIONDATE1,ZMARKEDFORDELETION"
            var vals: [SQLValue] = [.int(pk), .text(id), .text(title), .int(folder), .int(pk), .double(700_000_000 + Double(pk)), .int(deleted)]
            if includePasswordColumn { cols += ",ZISPASSWORDPROTECTED"; vals.append(.int(locked)) }
            try db.run("INSERT INTO ZICCLOUDSYNCINGOBJECT(\(cols)) VALUES(\(vals.map { _ in "?" }.joined(separator: ",")))", vals)
        }
        try await note(10, id: "AAA-1", title: "Trip plan", text: "Trip plan\nBook the ryokan in Kyoto \u{FFFC} and the Shinkansen.", folder: 1)
        try await note(11, id: "AAA-2", title: "读书笔记", text: "读书笔记\n正在读《黑天鹅》,第三章。", folder: 1, compressed: false)
        try await note(12, id: "AAA-3", title: "Locked", text: "Locked\nsecret diary", folder: 1, locked: 1)
        try await note(13, id: "AAA-4", title: "Gone", text: "Gone\nmarked for deletion", folder: 1, deleted: 1)
        try await note(14, id: "AAA-5", title: "Trashed", text: "Trashed\nin recently deleted", folder: 2)
        return url
    }

    func testAppleNotesListsOnlyReadableNotesAndLoadsText() async throws {
        let c = AppleNotesConnector(databaseURL: try await makeNotesDB())
        let refs = try await c.list()
        XCTAssertEqual(Set(refs.map(\.title)), ["Trip plan", "读书笔记"], "password-protected, deleted and trashed notes are never read")
        XCTAssertTrue(refs.allSatisfy { $0.trust == .authored && $0.uri.hasPrefix("notes://showNote?identifier=") })
        guard case .text(let t) = try await c.load(refs.first { $0.title == "Trip plan" }!) else { return XCTFail() }
        XCTAssertTrue(t.contains("Apple Notes folder: Work"))
        XCTAssertTrue(t.contains("Book the ryokan in Kyoto  and the Shinkansen."), "attachment placeholders are removed")
        XCTAssertFalse(t.contains("\u{FFFC}"))
        guard case .text(let zh) = try await c.load(refs.first { $0.title == "读书笔记" }!) else { return XCTFail() }
        XCTAssertTrue(zh.contains("黑天鹅"), "an uncompressed payload is accepted too")
        XCTAssertFalse(t.contains("secret diary"))
    }

    func testAppleNotesCopiesTheStoreOncePerRun() async throws {
        let c = AppleNotesConnector(databaseURL: try await makeNotesDB())
        let before = DatabaseSnapshot.openCount
        let refs = try await c.list()
        for r in refs { _ = try await c.load(r) }
        XCTAssertEqual(DatabaseSnapshot.openCount - before, 1, "\(refs.count) notes, one copy of NoteStore.sqlite")
    }

    func testAppleNotesAdaptsToMissingColumnsAndRejectsOtherDatabases() async throws {
        let c = AppleNotesConnector(databaseURL: try await makeNotesDB(includePasswordColumn: false))
        let older = try await c.list()
        XCTAssertFalse(older.isEmpty, "an older schema without the password column still works")

        let other = tmp.appendingPathComponent("other.sqlite")
        try Database(path: other.path).exec("CREATE TABLE t(x)")
        do { _ = try await AppleNotesConnector(databaseURL: other).list(); XCTFail() } catch { XCTAssertTrue("\(error)".contains("Apple Notes")) }
    }

    func testAppleNotesEditChangesFingerprintAndFlowsThroughThePipeline() async throws {
        let url = try await makeNotesDB()
        let store = try T.store()
        let model = MockModel { _ in #"{"summary":"The user keeps notes.","title":"Notes","junk":false,"sensitive":false}"# }
        let pipeline = IngestPipeline(store: store, triager: Triager(model: model), indexer: Indexer(store: store, embedder: HashingEmbedder()))
        let c = AppleNotesConnector(databaseURL: url)
        let first = try await pipeline.run(connectors: [c])
        XCTAssertEqual(first.survivors, 2)
        let db = try Database(path: url.path)
        try db.run("UPDATE ZICCLOUDSYNCINGOBJECT SET ZMODIFICATIONDATE1 = 800000000 WHERE ZIDENTIFIER = 'AAA-1'")
        try db.run("UPDATE ZICCLOUDSYNCINGOBJECT SET ZMARKEDFORDELETION = 1 WHERE ZIDENTIFIER = 'AAA-2'")
        let second = try await pipeline.run(connectors: [c])
        XCTAssertEqual(second.survivors, 1, "the edited note is re-read")
        XCTAssertEqual(second.deleted, 1, "a note deleted in Notes leaves the index")
        XCTAssertEqual(try store.items(bucket: "applenotes").count, 1)
    }

    // MARK: SiYuan

    func makeWorkspace() throws -> URL {
        let data = tmp.appendingPathComponent("data")
        let box = data.appendingPathComponent("20240101120000-abcdefg")
        try FileManager.default.createDirectory(at: box.appendingPathComponent(".siyuan"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: box.appendingPathComponent("20240102000000-parent0"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data(#"{"name":"Work notes"}"#.utf8).write(to: box.appendingPathComponent(".siyuan/conf.json"))
        try Data("not a document".utf8).write(to: data.appendingPathComponent("assets/ignored.sy"))
        func text(_ s: String) -> [String: Any] { ["Type": "NodeText", "Data": s] }
        let doc: [String: Any] = [
            "ID": "20240102000001-docdoc1", "Type": "NodeDocument", "Properties": ["title": "Q3 \"Roadmap\" 路线图", "updated": "20240301101010"],
            "Children": [
                ["Type": "NodeHeading", "HeadingLevel": 2, "Children": [text("Goals")]],
                ["Type": "NodeParagraph", "Children": [text("Ship the "), ["Type": "NodeTextMark", "TextMarkType": "strong", "TextMarkTextContent": "pipeline"], text(" migration. See "), ["Type": "NodeTextMark", "TextMarkType": "block-ref", "TextMarkTextContent": "Kickoff notes"], text(" "), ["Type": "NodeTextMark", "TextMarkType": "tag", "TextMarkTextContent": "q3"], ["Type": "NodeKramdownSpanIAL", "Data": "{: id=\"x\"}"]]],
                ["Type": "NodeList", "ListData": ["Typ": 0], "Children": [
                    ["Type": "NodeListItem", "Children": [["Type": "NodeParagraph", "Children": [text("hire two engineers")]]]],
                    ["Type": "NodeListItem", "Children": [["Type": "NodeParagraph", "Children": [text("freeze the schema")]]]]]],
                ["Type": "NodeCodeBlock", "Children": [["Type": "NodeCodeBlockFenceOpenMarker", "Data": "```"], ["Type": "NodeCodeBlockCode", "Data": "make deploy"], ["Type": "NodeCodeBlockFenceCloseMarker", "Data": "```"]]],
                ["Type": "NodeBlockQueryEmbed", "Data": "SELECT * FROM blocks"],
                ["Type": "NodeTable", "Children": [["Type": "NodeTableHead", "Children": [["Type": "NodeTableRow", "Children": [["Type": "NodeTableCell", "Children": [text("Owner")]], ["Type": "NodeTableCell", "Children": [text("Date")]]]]]], ["Type": "NodeTableRow", "Children": [["Type": "NodeTableCell", "Children": [text("Priya")]], ["Type": "NodeTableCell", "Children": [text("Friday")]]]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: box.appendingPathComponent("20240102000000-parent0/20240102000001-docdoc1.sy"))
        let other: [String: Any] = ["ID": "20240103000000-doc2222", "Type": "NodeDocument", "Properties": ["title": "Ideas"], "Children": [["Type": "NodeParagraph", "Children": [text("Learn to bake sourdough.")]]]]
        try JSONSerialization.data(withJSONObject: other).write(to: box.appendingPathComponent("20240103000000-doc2222.sy"))
        return data
    }

    func testSiYuanFindsNotebookDocumentsAndRendersBlocks() async throws {
        let c = SiYuanConnector(dataDirectory: try makeWorkspace())
        let refs = try await c.list()
        XCTAssertEqual(Set(refs.map(\.title)), ["Q3 \"Roadmap\" 路线图", "Ideas"], "assets and non-notebook folders are skipped; escaped titles are decoded")
        XCTAssertTrue(refs.allSatisfy { $0.trust == .authored })
        guard case .text(let t) = try await c.load(refs.first { $0.title.hasPrefix("Q3") }!) else { return XCTFail() }
        XCTAssertTrue(t.hasPrefix("SiYuan notebook: Work notes"))
        XCTAssertTrue(t.contains("## Goals"))
        XCTAssertTrue(t.contains("Ship the pipeline migration. See Kickoff notes #q3"))
        XCTAssertTrue(t.contains("- hire two engineers"))
        XCTAssertTrue(t.contains("- freeze the schema"))
        XCTAssertTrue(t.contains("```\nmake deploy\n```"))
        XCTAssertTrue(t.contains("Owner | Date"))
        XCTAssertTrue(t.contains("Priya | Friday"))
        XCTAssertFalse(t.contains("SELECT * FROM blocks"), "embedded queries are not content")
        XCTAssertFalse(t.contains("{: id="), "inline attribute lists are not content")
    }

    func testSiYuanIsIncrementalAndMissingFolderIsAnError() async throws {
        let data = try makeWorkspace()
        let c = SiYuanConnector(dataDirectory: data)
        let before = try await c.list().first { $0.title == "Ideas" }!.fingerprint
        let file = data.appendingPathComponent("20240101120000-abcdefg/20240103000000-doc2222.sy")
        let edited: [String: Any] = ["ID": "20240103000000-doc2222", "Type": "NodeDocument", "Properties": ["title": "Ideas"], "Children": [["Type": "NodeParagraph", "Children": [["Type": "NodeText", "Data": "Learn to bake sourdough and croissants this winter."]]]]]
        try JSONSerialization.data(withJSONObject: edited).write(to: file)
        let after = try await c.list().first { $0.title == "Ideas" }!.fingerprint
        XCTAssertNotEqual(before, after)
        do { _ = try await SiYuanConnector(dataDirectory: tmp.appendingPathComponent("nope")).list(); XCTFail() } catch { XCTAssertTrue("\(error)".contains("not found")) }
    }
}
