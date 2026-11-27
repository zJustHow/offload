import XCTest
@testable import OffloadCore

final class OfficeTextTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("offload-office-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Fixtures

    /// An Office-style archive built by the system `zip` (DEFLATE entries unless `store`).
    @discardableResult
    func archive(_ name: String, _ parts: [String: String], store: Bool = false) throws -> URL {
        let staging = dir.appendingPathComponent("stage-\(UUID().uuidString)")
        for (path, content) in parts {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let out = dir.appendingPathComponent(name)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-q", "-X", "-D", "-r"] + (store ? ["-0"] : []) + [out.path, "."]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0, "zip failed")
        return out
    }

    static let wNS = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006""#
    static let aNS = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#

    func word(_ body: String) -> String { #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document \#(Self.wNS)><w:body>\#(body)</w:body></w:document>"# }
    func footnotes(_ body: String) -> String { #"<?xml version="1.0" encoding="UTF-8"?><w:footnotes \#(Self.wNS)>\#(body)</w:footnotes>"# }
    func slide(_ body: String) -> String { #"<?xml version="1.0" encoding="UTF-8"?><p:sld \#(Self.aNS)><p:cSld><p:spTree>\#(body)</p:spTree></p:cSld></p:sld>"# }
    func para(_ text: String) -> String { "<a:p><a:r><a:t>\(text)</a:t></a:r></a:p>" }
    func shape(_ paragraphs: String...) -> String { "<p:sp><p:txBody>" + paragraphs.joined() + "</p:txBody></p:sp>" }

    func relationships(_ items: [(id: String, type: String, target: String)]) -> String {
        let rels = items.map { #"<Relationship Id="\#($0.id)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/\#($0.type)" Target="\#($0.target)"/>"# }.joined()
        return #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(rels)</Relationships>"#
    }

    func presentation(_ ids: [String]) -> String {
        let list = ids.enumerated().map { #"<p:sldId id="\#(256 + $0.offset)" r:id="\#($0.element)"/>"# }.joined()
        return #"<?xml version="1.0" encoding="UTF-8"?><p:presentation \#(Self.aNS)><p:sldIdLst>\#(list)</p:sldIdLst></p:presentation>"#
    }

    // MARK: Word

    func testDocxKeepsParagraphsBreaksTabsAndTables() throws {
        let body = """
            <w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr><w:r><w:t>First</w:t></w:r><w:r><w:t xml:space="preserve"> paragraph</w:t></w:r></w:p>
            <w:p><w:r><w:t>Line one</w:t><w:br/><w:t>line two</w:t><w:tab/><w:t>after tab</w:t></w:r></w:p>
            <w:p><w:r><w:delText>deleted words</w:delText></w:r><w:r><w:instrText>PAGE</w:instrText></w:r></w:p>
            <w:tbl>
              <w:tr><w:tc><w:p><w:r><w:t>Owner</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Due</w:t></w:r></w:p><w:p><w:r><w:t>date</w:t></w:r></w:p></w:tc></w:tr>
              <w:tr><w:tc><w:p><w:r><w:t>Priya</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Friday</w:t></w:r></w:p></w:tc></w:tr>
            </w:tbl>
            """
        let file = try archive("a.docx", ["word/document.xml": word(body)])
        let text = try OfficeText.docx(at: file)
        XCTAssertEqual(text, "First paragraph\nLine one\nline two\tafter tab\n\nOwner\tDue date\nPriya\tFriday")
        XCTAssertFalse(text.contains("deleted words"), "tracked deletions are not text")
        XCTAssertFalse(text.contains("PAGE"), "field codes are not text")
    }

    func testDocxReadsStoredEntriesToo() throws {
        let file = try archive("stored.docx", ["word/document.xml": word("<w:p><w:r><w:t>No compression</w:t></w:r></w:p>")], store: true)
        XCTAssertEqual(try OfficeText.docx(at: file), "No compression")
    }

    func testDocxTextBoxesAreNotDuplicatedAndFootnotesAreIncluded() throws {
        let body = """
            <mc:AlternateContent><mc:Choice Requires="wps"><w:p><w:r><w:t>Text box</w:t></w:r></w:p></mc:Choice>
            <mc:Fallback><w:p><w:r><w:t>Text box</w:t></w:r></w:p></mc:Fallback></mc:AlternateContent>
            <w:p><w:r><w:t>Main text</w:t></w:r></w:p>
            """
        let notes = footnotes(#"<w:footnote w:id="0"><w:p/></w:footnote><w:footnote w:id="1"><w:p><w:r><w:t>See tablet XI.</w:t></w:r></w:p></w:footnote>"#)
        let file = try archive("b.docx", ["word/document.xml": word(body), "word/footnotes.xml": notes])
        let text = try OfficeText.docx(at: file)
        XCTAssertEqual(text, "Text box\nMain text\n\nSee tablet XI.")
    }

    func testDocxKeepsChineseAndTypographicPunctuation() throws {
        let line = "房东陈女士说“没问题”,续租要在 6 月 30 日前通知。It’s fine."
        let file = try archive("c.docx", ["word/document.xml": word("<w:p><w:r><w:t>\(line)</w:t></w:r></w:p>")])
        XCTAssertEqual(try OfficeText.docx(at: file), line)
    }

    func testDocxStopsAtTheCharacterLimit() throws {
        let body = String(repeating: "<w:p><w:r><w:t>word word word</w:t></w:r></w:p>", count: 5_000)
        let file = try archive("long.docx", ["word/document.xml": word(body)])
        let text = try OfficeText.docx(at: file, maxChars: 200)
        XCTAssertFalse(text.isEmpty)
        XCTAssertLessThanOrEqual(text.count, 200)
        XCTAssertTrue(text.hasPrefix("word word word"))
    }

    // MARK: PowerPoint

    func testPptxFollowsDeckOrderNotFileOrderAndAddsSpeakerNotes() throws {
        let file = try archive("deck.pptx", [
            // The deck shows slide2.xml first: the file that was created second was dragged to the front.
            "ppt/presentation.xml": presentation(["rId2", "rId1"]),
            "ppt/_rels/presentation.xml.rels": relationships([("rId1", "slide", "slides/slide1.xml"), ("rId2", "slide", "slides/slide2.xml")]),
            "ppt/slides/slide1.xml": slide(shape(para("Second in the deck"))),
            "ppt/slides/slide2.xml": slide(shape(para("Opening slide"), para("Welcome"))),
            "ppt/slides/_rels/slide2.xml.rels": relationships([("rId1", "notesSlide", "../notesSlides/notesSlide1.xml")]),
            "ppt/notesSlides/notesSlide1.xml": slide(shape(para("Say hello")) + shape(para("1"))),
        ])
        XCTAssertEqual(try OfficeText.pptx(at: file), "Slide 1\nOpening slide\nWelcome\nNotes: Say hello\n\nSlide 2\nSecond in the deck")
    }

    func testPptxWithoutAPresentationPartFallsBackToNumericFileOrder() throws {
        let file = try archive("plain.pptx", [
            "ppt/slides/slide10.xml": slide(shape(para("C"))),
            "ppt/slides/slide2.xml": slide(shape(para("B"))),
            "ppt/slides/slide1.xml": slide(shape(para("A"))),
        ])
        XCTAssertEqual(try OfficeText.pptx(at: file), "Slide 1\nA\n\nSlide 2\nB\n\nSlide 3\nC")
    }

    func testPptxTableRowsStayOnOneLine() throws {
        func cell(_ t: String) -> String { "<a:tc><a:txBody>\(para(t))</a:txBody></a:tc>" }
        let table = "<p:graphicFrame><a:tbl><a:tr>\(cell("Owner"))\(cell("Date"))</a:tr><a:tr>\(cell("Priya"))\(cell("Friday"))</a:tr></a:tbl></p:graphicFrame>"
        let file = try archive("table.pptx", ["ppt/slides/slide1.xml": slide(table)])
        XCTAssertEqual(try OfficeText.pptx(at: file), "Slide 1\nOwner\tDate\nPriya\tFriday")
    }

    func testPptxSkipsSlidesWithNoText() throws {
        let file = try archive("empty.pptx", [
            "ppt/slides/slide1.xml": slide("<p:pic/>"),
            "ppt/slides/slide2.xml": slide(shape(para("Only this one"))),
        ])
        // Numbering follows the deck, so the picture-only slide still counts as slide 1.
        XCTAssertEqual(try OfficeText.pptx(at: file), "Slide 2\nOnly this one")
    }

    // MARK: Bad input

    func testFilesThatAreNotArchivesFailCleanly() throws {
        let junk = dir.appendingPathComponent("junk.docx")
        try Data("this is not a zip file at all, just some text that is long enough".utf8).write(to: junk)
        XCTAssertThrowsError(try OfficeText.docx(at: junk))
        XCTAssertThrowsError(try OfficeText.pptx(at: junk))

        let tiny = dir.appendingPathComponent("tiny.docx")
        try Data([0x50, 0x4B]).write(to: tiny)
        XCTAssertThrowsError(try OfficeText.docx(at: tiny))
    }

    func testTruncatedArchiveFailsCleanly() throws {
        let file = try archive("t.docx", ["word/document.xml": word("<w:p><w:r><w:t>hello</w:t></w:r></w:p>")])
        let whole = try Data(contentsOf: file)
        // Losing the end of the file loses the directory that says where everything is.
        XCTAssertThrowsError(try OfficeText.docx(whole.prefix(whole.count - 30), maxChars: 1_000, maxEntryBytes: OfficeText.maxEntryBytes))
    }

    func testArchivesOfTheWrongKindAreRejected() throws {
        let other = try archive("other.docx", ["notes.txt": "hello"])
        XCTAssertThrowsError(try OfficeText.docx(at: other)) { XCTAssertTrue("\($0)".contains("not a Word document")) }
        XCTAssertThrowsError(try OfficeText.pptx(at: other)) { XCTAssertTrue("\($0)".contains("no slides")) }
    }

    func testCorruptXMLWithNothingReadableFails() throws {
        let file = try archive("bad.docx", ["word/document.xml": "<w:document><w:body><w:p>"])
        XCTAssertThrowsError(try OfficeText.docx(at: file))
    }

    func testEncryptedEntriesAreRejected() throws {
        let file = try archive("enc.docx", ["word/document.xml": word("<w:p><w:r><w:t>secret</w:t></w:r></w:p>")])
        var data = try Data(contentsOf: file)
        let directory = try XCTUnwrap(data.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        data[directory.lowerBound + 8] |= 1   // general-purpose flag bit 0: encrypted
        XCTAssertThrowsError(try OfficeText.docx(data, maxChars: 1_000, maxEntryBytes: OfficeText.maxEntryBytes)) {
            XCTAssertTrue("\($0)".contains("encrypted"))
        }
    }

    // MARK: Limits

    func testAHugeEntryIsRefusedWithoutInflatingIt() throws {
        let bomb = word("<w:p><w:r><w:t>" + String(repeating: "a", count: 2_000_000) + "</w:t></w:r></w:p>")
        let file = try archive("bomb.docx", ["word/document.xml": bomb])
        XCTAssertLessThan(try Data(contentsOf: file).count, 50_000, "the fixture must compress well to be a bomb")
        let data = try Data(contentsOf: file)
        XCTAssertThrowsError(try OfficeText.docx(data, maxChars: 1_000_000, maxEntryBytes: 100_000)) { XCTAssertTrue("\($0)".contains("larger")) }
    }

    func testAnArchiveThatLiesAboutItsSizeIsStillStopped() throws {
        let bomb = word("<w:p><w:r><w:t>" + String(repeating: "a", count: 2_000_000) + "</w:t></w:r></w:p>")
        var data = try Data(contentsOf: archive("liar.docx", ["word/document.xml": bomb]))
        // Central directory entry: the uncompressed size is at offset 24. Claim 10 bytes.
        let directory = try XCTUnwrap(data.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        for i in 0..<4 { data[directory.lowerBound + 24 + i] = i == 0 ? 10 : 0 }
        XCTAssertThrowsError(try OfficeText.docx(data, maxChars: 1_000_000, maxEntryBytes: 100_000)) { XCTAssertTrue("\($0)".contains("larger")) }
    }

    // MARK: Folder integration

    func testFilesConnectorListsAndLoadsOfficeDocuments() async throws {
        try archive("essay.docx", ["word/document.xml": word("<w:p><w:r><w:t>Gilgamesh and Enkidu</w:t></w:r></w:p>")])
        try archive("deck.pptx", ["ppt/slides/slide1.xml": slide(shape(para("Quarterly roadmap")))])
        try "plain".write(to: dir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try Data("legacy".utf8).write(to: dir.appendingPathComponent("old.doc"))

        let connector = FilesConnector(root: dir)
        let refs = try await connector.list()
        XCTAssertEqual(Set(refs.map { ($0.key as NSString).lastPathComponent }), ["essay.docx", "deck.pptx", "note.md"], "legacy .doc is still not read")
        XCTAssertEqual(refs.first { $0.key.hasSuffix(".docx") }?.trust, .saved)

        func text(_ suffix: String) async throws -> String {
            let ref = try XCTUnwrap(refs.first { $0.key.hasSuffix(suffix) })
            guard case .text(let t) = try await connector.load(ref) else { XCTFail("expected text"); return "" }
            return t
        }
        let essay = try await text("essay.docx")
        let deck = try await text("deck.pptx")
        XCTAssertEqual(essay, "Gilgamesh and Enkidu")
        XCTAssertEqual(deck, "Slide 1\nQuarterly roadmap")

        // Live sync resolves a single changed path through the same rules.
        let changed = try connector.refs(under: FilesConnector.realPath(dir.path) + "/essay.docx")
        XCTAssertEqual(changed.count, 1)
    }
}
