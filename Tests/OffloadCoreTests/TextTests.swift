import XCTest
@testable import OffloadCore

final class TextTests: XCTestCase {
    func testMixedChineseEnglishTokenization() {
        // Regression: NLTokenizer alone drops the Chinese part of mixed strings.
        let t = LexicalTokenizer(includeCJKBigrams: true)
        let tokens = t.tokens("我昨天在上海和王先生签了租房合同 meeting at 3pm order #A12345")
        XCTAssertTrue(tokens.contains("上海"), "\(tokens)")
        XCTAssertTrue(tokens.contains("合同"))
        XCTAssertTrue(tokens.contains("租房"))
        XCTAssertTrue(tokens.contains("meeting"))
        XCTAssertTrue(tokens.contains("a12345"))
        XCTAssertTrue(tokens.contains("3pm"))
    }

    func testBigramsAreOptional() {
        let on = LexicalTokenizer(includeCJKBigrams: true).tokens("租房合同")
        let off = LexicalTokenizer(includeCJKBigrams: false).tokens("租房合同")
        XCTAssertTrue(on.count > off.count)
    }

    func testQueryTokensDropFunctionWordsButKeepContentWords() {
        let t = LexicalTokenizer()
        let q = t.queryTokens("我在上海的会议")
        XCTAssertFalse(q.contains("我"))
        XCTAssertFalse(q.contains("的"))
        XCTAssertTrue(q.contains("上海"))
        XCTAssertTrue(q.contains("会议"), "a word merely containing a function-word char must survive: \(q)")
        XCTAssertFalse(t.queryTokens("what is the meeting about").contains("the"))
    }

    func testFTSQueryIsQuotedAndSafe() {
        let t = LexicalTokenizer()
        let q = t.ftsQuery("NOT NEAR \"quoted\" (paren) col:umn *")!
        // Operators in user text must come out as quoted literals, never as FTS syntax.
        XCTAssertTrue(q.contains("\"not\""), q)
        XCTAssertTrue(q.contains("\"near\""), q)
        XCTAssertFalse(q.contains("*"))
        XCTAssertFalse(q.contains(":"))
        XCTAssertNil(t.ftsQuery("   !!! "))
    }

    func testShortDocumentIsOneChunk() {
        XCTAssertEqual(Chunker().chunk(document: "hello world").count, 1)
        XCTAssertEqual(Chunker().chunk(document: "  \n\n ").count, 0)
    }

    func testLongDocumentSplitsWithinBoundsAndKeepsAllContent() {
        let para = String(repeating: "This is a sentence about the lease. ", count: 20)
        let doc = (0..<10).map { "Section \($0)\n" + para }.joined(separator: "\n\n")
        let c = Chunker(targetChars: 900, maxChars: 1400, overlapChars: 100)
        let chunks = c.chunk(document: doc)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 1400 + 120 })
        for i in 0..<10 { XCTAssertTrue(chunks.contains { $0.text.contains("Section \(i)") }, "Section \(i) lost") }
    }

    func testLongChineseWithoutSpacesStillSplits() {
        let doc = String(repeating: "我昨天在上海签了租房合同押金两个月房租。", count: 120)
        let chunks = Chunker().chunk(document: doc)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 1400 + 120 })
    }

    func testConversationWindowsOverlapByTwoLines() {
        let lines = (0..<60).map { "Me: message number \($0) " + String(repeating: "x", count: 40) }
        let chunks = Chunker(targetChars: 400, maxChars: 600, overlapChars: 0).chunk(conversation: lines)
        XCTAssertGreaterThan(chunks.count, 2)
        let first = chunks[0].text.split(separator: "\n").map(String.init)
        let second = chunks[1].text.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(first.suffix(2)), Array(second.prefix(2)))
        // Every line appears somewhere.
        let all = chunks.map(\.text).joined(separator: "\n")
        for l in lines { XCTAssertTrue(all.contains(l)) }
    }
}
