import XCTest
@testable import OffloadCore

final class MemoryMCPTests: XCTestCase {
    var base: URL!
    var ws: VaultWorkspace!
    var store: KnowledgeStore!
    var memory: MemoryService!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-mem-\(UUID().uuidString)")
        ws = VaultWorkspace(root: base.appendingPathComponent("vault"))
        store = try T.store()
        let embedder = HashingEmbedder()
        let notes = [
            "README.md": "# About\n\nA founder who rents an apartment in San Francisco.\n\n## Map\n- [[Apartment]]\n- [[Acme]]\n",
            "Home/Apartment.md": "# Apartment\nRents on Mission Street for $3,400 a month. Landlord is Mr. Alvarez.\n",
            "Work/Acme.md": "# Acme\nRaising a Series A led by Orion Capital.\n",
        ]
        let staging = try ws.makeStaging()
        try ws.write(notes, paths: Array(notes.keys), into: staging)
        try ws.swap(staging: staging)

        let indexer = Indexer(store: store, embedder: embedder)
        for (p, b) in notes { try await indexer.indexNote(path: p, body: b) }
        let lease = ItemRecord(id: "lease", bucket: "b", kind: .file, uri: "/docs/lease.md", title: "Lease", itemDate: Date(), fingerprint: "1", summary: "The user rents an apartment.", verdict: .survivor, trust: .authored)
        let ids = try store.commitItem(lease, chunkTexts: ["Security deposit of 6800 dollars wired on 3 March, reference LD-55821, landlord Alvarez."])
        try await indexer.embed(ids: ids, texts: ["Security deposit of 6800 dollars wired on 3 March, reference LD-55821, landlord Alvarez."])
        try store.addEvidence(notePath: "Home/Apartment.md", itemIDs: ["lease"])
        try await indexer.embedPending()
        memory = MemoryService(store: store, searcher: HybridSearcher(store: store, embedder: embedder), workspace: ws)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func testSearchReturnsRawSnippetsToEveryCaller() async throws {
        var opts = SearchOptions(); opts.limit = 10
        let hits = try await memory.search("LD-55821 deposit", options: opts)
        let chunk = try XCTUnwrap(hits.first { $0.kind == .chunk }, "raw snippets are always returned")
        XCTAssertEqual(chunk.citedByNotes, ["Home/Apartment.md"], "a hit knows which notes it supports")
    }

    func testItemViewAlwaysIncludesRawText() throws {
        XCTAssertTrue(try XCTUnwrap(memory.item(id: "lease")?.rawText).contains("LD-55821"))
        XCTAssertEqual(try memory.item(id: "lease")?.citedByNotes, ["Home/Apartment.md"])
        XCTAssertNil(try memory.item(id: "nope"))
        XCTAssertTrue(try memory.isKnownSource(uri: "/docs/lease.md"))
        XCTAssertFalse(try memory.isKnownSource(uri: "/etc/passwd"))
    }

    func testNoteLookupCannotEscapeTheVault() throws {
        XCTAssertNotNil(try memory.note(path: "Home/Apartment.md"))
        XCTAssertNil(try memory.note(path: "../outside.md"))
        XCTAssertNil(try memory.note(path: "/etc/passwd"))
        XCTAssertNil(try memory.note(path: "Home/Missing.md"))
    }

    // MARK: MCP

    func call(_ server: MCPServer, _ json: String) async throws -> [String: Any] {
        let maybe = await server.handle(json)
        let line = try XCTUnwrap(maybe)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    func text(_ r: [String: Any]) -> String {
        ((r["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }

    func testProtocolBasics() async throws {
        let s = MCPServer(memory: memory)
        let r = try await call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}"#)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05", "echoes the client's version")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        let initialized = await s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(initialized, "notifications get no response")

        let list = try await call(s, #"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#)
        XCTAssertEqual(list["id"] as? String, "abc", "string ids round-trip")
        let tools = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(tools ?? []), ["get_structure", "get_files", "search_memory", "read_item"])

        let unknown = try await call(s, #"{"jsonrpc":"2.0","id":2,"method":"nope"}"#)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let bad = try await call(s, "{not json")
        XCTAssertEqual((bad["error"] as? [String: Any])?["code"] as? Int, -32700)
        let ping = try await call(s, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
        XCTAssertNotNil(ping["result"])
    }

    func testToolsStructureFilesAndSearch() async throws {
        let s = MCPServer(memory: memory)
        let structure = text(try await call(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_structure","arguments":{}}}"#))
        XCTAssertTrue(structure.contains("Home/"))
        XCTAssertTrue(structure.contains("Apartment.md"))
        XCTAssertTrue(structure.contains("A founder who rents"))

        let files = text(try await call(s, ##"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_files","arguments":{"paths":["Home/Apartment.md","../../etc/passwd","Work/acme","Home/Nothing.md"]}}}"##))
        XCTAssertTrue(files.contains("=== Home/Apartment.md ==="))
        XCTAssertTrue(files.contains("Mr. Alvarez"))
        XCTAssertTrue(files.contains("=== ../../etc/passwd ===\n(not found)"), "traversal resolves to not found, never to a file")
        XCTAssertFalse(files.contains("root:"))
        XCTAssertTrue(files.contains("=== Work/Acme.md ==="), "a wrongly capitalized path resolves when unambiguous")
        XCTAssertTrue(files.contains("(not found)"))

        let asString = text(try await call(s, ##"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_files","arguments":{"paths":"[\"Work/Acme.md\"]"}}}"##))
        XCTAssertTrue(asString.contains("Orion Capital"), "a JSON array sent as a string still works")

        let found = text(try await call(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_memory","arguments":{"query":"who is my landlord","limit":3}}}"#))
        XCTAssertTrue(found.contains("NOTE Home/Apartment.md"))

        let withRaw = text(try await call(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search_memory","arguments":{"query":"LD-55821"}}}"#))
        XCTAssertTrue(withRaw.contains("SOURCE item=lease"))

        let bad = try await call(s, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"delete_everything","arguments":{}}}"#)
        XCTAssertEqual((bad["result"] as? [String: Any])?["isError"] as? Bool, true)
        let empty = try await call(s, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"search_memory","arguments":{"query":"  "}}}"#)
        XCTAssertEqual((empty["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testToolResultsAreRedactedBeforeTheyReachTheClient() async throws {
        // A note holding an identifier (written by the user, or slipped past the model) was never
        // scanned at ingestion; the MCP client is a hosted model, so the server scans what it returns.
        let dir = ws.root.appendingPathComponent("Home")
        try "# Card\nThe user pays with card 4111 1111 1111 1111, reference LD-55821.\n"
            .write(to: dir.appendingPathComponent("Card.md"), atomically: true, encoding: .utf8)
        let s = MCPServer(memory: memory)
        let files = text(try await call(s, ##"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_files","arguments":{"paths":["Home/Card.md"]}}}"##))
        XCTAssertTrue(files.contains("=== Home/Card.md ==="))
        XCTAssertFalse(files.contains("4111"), files)
        XCTAssertTrue(files.contains("[REDACTED:card]"))
        XCTAssertTrue(files.contains("LD-55821"), "ordinary references are not over-redacted")
    }

    func testFileCallsAreCapped() async throws {
        let s = MCPServer(memory: memory)
        let many = (0..<80).map { "\"Home/n\($0).md\"" }.joined(separator: ",")
        let r = text(try await call(s, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_files\",\"arguments\":{\"paths\":[\(many)]}}}"))
        XCTAssertTrue(r.contains("only the first 50 of 80"))
    }
}
