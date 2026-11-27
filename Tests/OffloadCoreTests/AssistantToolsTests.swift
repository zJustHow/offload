import XCTest
@testable import OffloadCore

/// Web access, note editing and how the assistant is assembled from the user's settings.
final class AssistantToolsTests: XCTestCase {
    var base: URL!
    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    // MARK: Which addresses may be read

    func testAddressesIntoTheLocalNetworkAreRefusedInEverySpelling() {
        let policy = WebPolicy()
        let public1: WebGuard.Resolver = { _ in ["93.184.216.34"] }
        func reject(_ s: String, resolve: WebGuard.Resolver? = nil) -> String? { WebGuard.rejection(for: URL(string: s)!, policy: policy, resolve: resolve ?? public1) }

        XCTAssertNil(reject("https://example.com/page"))
        for bad in ["http://localhost/", "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f000001/", "http://10.0.0.5/", "http://192.168.1.1/admin",
                    "http://172.16.0.1/", "http://169.254.169.254/latest/meta-data", "http://[::1]/", "http://[fe80::1]/", "http://[::ffff:127.0.0.1]/", "http://100.64.0.1/",
                    "http://printer.local/", "http://intranet/", "http://0.0.0.0/", "ftp://example.com/", "file:///etc/passwd", "https://user:pass@example.com/", "javascript:alert(1)"] {
            XCTAssertNotNil(reject(bad), "\(bad) must be refused")
        }
        XCTAssertNotNil(reject("https://rebind.example.com/", resolve: { _ in ["127.0.0.1"] }), "a public name that resolves to a private address is refused")
        XCTAssertNotNil(reject("https://example.com/", resolve: { _ in ["93.184.216.34", "10.1.2.3"] }), "any private answer is enough")
        XCTAssertEqual(reject("https://nowhere.example.com/", resolve: { _ in [] }), "nowhere.example.com could not be found")
        XCTAssertNil(WebGuard.rejection(for: URL(string: "https://93.184.216.34/")!, policy: policy, resolve: { _ in [] }), "a public literal needs no lookup")
    }

    func testDomainListsAreAppliedToSubdomainsToo() {
        let resolve: WebGuard.Resolver = { _ in ["93.184.216.34"] }
        let blocked = WebPolicy(blockedDomains: ["evil.com"])
        XCTAssertNotNil(WebGuard.rejection(for: URL(string: "https://evil.com/")!, policy: blocked, resolve: resolve))
        XCTAssertNotNil(WebGuard.rejection(for: URL(string: "https://www.evil.com/")!, policy: blocked, resolve: resolve))
        XCTAssertNil(WebGuard.rejection(for: URL(string: "https://notevil.com/")!, policy: blocked, resolve: resolve), "a suffix of the text is not a subdomain")
        let allowed = WebPolicy(allowedDomains: ["wikipedia.org"])
        XCTAssertNil(WebGuard.rejection(for: URL(string: "https://en.wikipedia.org/wiki/X")!, policy: allowed, resolve: resolve))
        XCTAssertNotNil(WebGuard.rejection(for: URL(string: "https://example.com/")!, policy: allowed, resolve: resolve))
    }

    // MARK: Web tools

    struct CannedWeb: WebTransport {
        var pages: [String: WebResponse] = [:]
        func get(_ url: URL) async throws -> WebResponse {
            if let p = pages[url.absoluteString] { return p }
            if url.host == "html.duckduckgo.com" { return WebResponse(url: url, status: 200, contentType: "text/html", data: Data(AssistantToolsTests.searchPage.utf8)) }
            return WebResponse(url: url, status: 404, contentType: "text/plain", data: Data())
        }
    }
    static let searchPage = """
        <div class="result"><h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FSwift&amp;rut=abc">Swift &amp; its <b>history</b></a></h2>
        <a class="result__snippet" href="x">Swift is a <b>programming</b> language.</a></div>
        <div class="result"><h2 class="result__title"><a class="result__a" href="https://tracker.evil.com/page">Evil page</a></h2>
        <a class="result__snippet" href="y">Not wanted.</a></div>
        """

    func webTools(policy: WebPolicy = WebPolicy(), pages: [String: WebResponse] = [:]) -> ToolRegistry {
        ToolRegistry(WebTools.make(policy: policy, transport: CannedWeb(pages: pages), resolve: { _ in ["93.184.216.34"] }))
    }

    func testFetchingAPageReturnsItsTextAsUntrustedData() async throws {
        let html = "<html><head><title>Hello &amp; welcome</title><style>p{}</style></head><body><script>evil()</script><p>First paragraph.</p></body></html>"
        let reg = webTools(pages: ["https://example.com/a": WebResponse(url: URL(string: "https://example.com/a")!, status: 200, contentType: "text/html; charset=utf-8", data: Data(html.utf8))])
        let asked = Box<[String]>([])
        let d = ToolDispatcher(registry: reg, policy: PermissionPolicy(mode: .allow), hooks: [UntrustedContentHook()], approver: { asked.append($0.description); return true })
        let r = await d.dispatch(ToolCall(name: "web_fetch", arguments: ["url": "https://example.com/a"]))
        XCTAssertEqual(r.outcome, .ran, r.output.text)
        XCTAssertTrue(r.output.text.contains("Hello & welcome"))
        XCTAssertTrue(r.output.text.contains("First paragraph."))
        XCTAssertFalse(r.output.text.contains("evil()"), "scripts are dropped")
        XCTAssertTrue(r.output.text.contains("external source"))
        XCTAssertEqual(asked.value, ["Read the web page https://example.com/a"], "even in allow mode a web read asks, and shows the address")
    }

    func testRefusedAddressesAndIdentifiersNeverReachTheUserOrTheNetwork() async {
        let asked = Box<[String]>([])
        let d = ToolDispatcher(registry: webTools(policy: WebPolicy(blockedDomains: ["evil.com"])), policy: PermissionPolicy(mode: .act), approver: { asked.append($0.description); return true })
        for url in ["http://127.0.0.1:8080/admin", "https://evil.com/x", "https://example.com/?card=4111%201111%201111%201111", "https://example.com/?card=4111 1111 1111 1111", "not a url"] {
            let r = await d.dispatch(ToolCall(name: "web_fetch", arguments: ["url": .string(url)]))
            XCTAssertEqual(r.outcome, .invalid, "\(url): \(r.output.text)")
        }
        let q = await d.dispatch(ToolCall(name: "web_search", arguments: ["query": "who owns card 4111 1111 1111 1111"]))
        XCTAssertEqual(q.outcome, .invalid)
        XCTAssertTrue(q.output.text.contains("identifier"))
        XCTAssertTrue(asked.value.isEmpty, "nobody is asked to approve something that was never going to be sent")
    }

    func testSearchParsesUnwrapsRedirectsAndFiltersByDomain() async {
        let d = ToolDispatcher(registry: webTools(policy: WebPolicy(blockedDomains: ["evil.com"])), policy: PermissionPolicy(mode: .act), approver: { _ in true })
        let r = await d.dispatch(ToolCall(name: "web_search", arguments: ["query": "swift language"]))
        XCTAssertEqual(r.outcome, .ran, r.output.text)
        XCTAssertTrue(r.output.text.contains("1. Swift & its history"), r.output.text)
        XCTAssertTrue(r.output.text.contains("https://en.wikipedia.org/wiki/Swift"), "the redirect wrapper is removed")
        XCTAssertTrue(r.output.text.contains("Swift is a programming language."))
        XCTAssertFalse(r.output.text.contains("evil.com"), "blocked domains are filtered from results")
        let hits = DuckDuckGoSearch.parse(Self.searchPage)
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(DuckDuckGoSearch.parse("<html>layout changed</html>").isEmpty)
    }

    // MARK: Note editing

    func makeVault() async throws -> (MemoryService, VaultEditor, VaultWorkspace) {
        let ws = VaultWorkspace(root: base.appendingPathComponent("vault"))
        let store = try T.store()
        let staging = try ws.makeStaging()
        let notes = ["README.md": "# About\n\nA founder.\n", "Home/Apartment.md": "# Apartment\nLandlord is Mr. Alvarez.\n\nRent is due on the 1st.\n"]
        try ws.write(notes, paths: Array(notes.keys), into: staging)
        try ws.swap(staging: staging)
        let indexer = Indexer(store: store, embedder: HashingEmbedder())
        for (p, b) in notes { try await indexer.indexNote(path: p, body: b) }
        let memory = MemoryService(store: store, searcher: HybridSearcher(store: store, embedder: HashingEmbedder()), workspace: ws)
        return (memory, VaultEditor(workspace: ws, store: store, indexer: indexer), ws)
    }

    func testAnApprovedNoteEditIsValidatedWrittenAndIndexed() async throws {
        let (memory, editor, ws) = try await makeVault()
        let asked = Box<[String]>([])
        let d = ToolDispatcher(registry: ToolRegistry([NoteTools.proposeEdit(memory: memory, editor: editor)]), policy: PermissionPolicy(mode: .allow), approver: { asked.append($0.description); return true })

        let appended = await d.dispatch(ToolCall(name: "propose_note_edit", arguments: ["path": "Home/Apartment.md", "operation": "append", "content": "Parking spot is number 14."]))
        XCTAssertEqual(appended.outcome, .ran, appended.output.text)
        XCTAssertTrue(appended.output.text.contains("added to"))
        XCTAssertTrue(asked.value[0].contains("Home/Apartment.md") && asked.value[0].contains("Parking spot"), "the user sees what will be written")
        let body = try XCTUnwrap(try memory.note(path: "Home/Apartment.md"))
        XCTAssertTrue(body.contains("Mr. Alvarez") && body.contains("Parking spot is number 14."), "an append keeps what was there")
        XCTAssertNotNil(try? ws.readAll()["Home/Apartment.md"])

        let created = await d.dispatch(ToolCall(name: "propose_note_edit", arguments: ["path": "Travel/Lisbon.md", "operation": "create", "content": "Flight lands at 9am."]))
        XCTAssertEqual(created.outcome, .ran, created.output.text)
        let note = try XCTUnwrap(try memory.note(path: "Travel/Lisbon.md"))
        XCTAssertTrue(note.hasPrefix("# Lisbon"), "a heading is added from the file name")

        var opts = SearchOptions(); opts.limit = 3
        let found = try await memory.search("parking spot number", options: opts)
        XCTAssertTrue(found.contains { $0.notePath == "Home/Apartment.md" }, "the edited note is searchable straight away")
    }

    func testDisallowedEditsAreRefusedBeforeAnyoneIsAskedAndNothingIsWritten() async throws {
        let (memory, editor, ws) = try await makeVault()
        let asked = Box<[String]>([])
        let d = ToolDispatcher(registry: ToolRegistry([NoteTools.proposeEdit(memory: memory, editor: editor)]), policy: PermissionPolicy(mode: .allow), approver: { asked.append($0.description); return true })
        let before = try ws.readAll()
        let cases: [(JSONObject, String)] = [
            (["path": "README.md", "operation": "rewrite", "content": "# Hacked"], "README.md"),
            (["path": "../../escape.md", "operation": "create", "content": "x"], "path"),
            (["path": "/etc/passwd", "operation": "create", "content": "x"], "path"),
            (["path": "TopLevel.md", "operation": "create", "content": "x"], "inside a folder"),
            (["path": "Home/Apartment.md", "operation": "rewrite", "content": "tiny"], "rewrite may not remove"),
            (["path": "Home/Apartment.md", "operation": "append", "content": "Landlord is Mr. Alvarez."], "nothing new"),
            (["path": "Home/Other.md", "operation": "create", "content": "# Apartment\nsame title"], "title"),
            (["path": "Home/Secret.md", "operation": "create", "content": "Card [REDACTED:card] is here"], "REDACTED"),
            (["path": "Home/X.md", "operation": "delete", "content": "x"], "must be one of"),
        ]
        for (args, expected) in cases {
            let r = await d.dispatch(ToolCall(name: "propose_note_edit", arguments: args))
            XCTAssertEqual(r.outcome, .invalid, "\(args): \(r.output.text)")
            XCTAssertTrue(r.output.text.contains(expected), "\(args): \(r.output.text)")
        }
        XCTAssertTrue(asked.value.isEmpty)
        XCTAssertEqual(try ws.readAll(), before)
    }

    func testADeclinedEditWritesNothingAndANoteEditNeedsWriteAccessOrApproval() async throws {
        let (memory, editor, ws) = try await makeVault()
        let tool = NoteTools.proposeEdit(memory: memory, editor: editor)
        let before = try ws.readAll()
        let args: JSONObject = ["path": "Home/Apartment.md", "operation": "append", "content": "New fact."]
        let declined = await ToolDispatcher(registry: ToolRegistry([tool]), policy: PermissionPolicy(mode: .act), approver: { _ in false }).dispatch(ToolCall(name: "propose_note_edit", arguments: args))
        XCTAssertEqual(declined.outcome, .declined)
        let readOnly = await ToolDispatcher(registry: ToolRegistry([tool]), policy: .readOnly, approver: { _ in true }).dispatch(ToolCall(name: "propose_note_edit", arguments: args))
        if case .ask = PermissionPolicy.readOnly.decide(ToolCall(name: "propose_note_edit", arguments: args), spec: tool.spec, tier: .write) {} else { XCTFail("read-only is one step short of write") }
        XCTAssertEqual(readOnly.outcome, .ran, "asked, and the user said yes")
        XCTAssertNotEqual(try ws.readAll(), before)
    }

    // MARK: Assembly from the user's settings

    func runtime(_ cfg: OffloadConfig, model: LanguageModel) throws -> Runtime {
        try Runtime(paths: AppPaths(support: base.appendingPathComponent("home")), config: cfg, models: (model, model, model))
    }

    func testTheAssistantIsBuiltFromTheConfiguredPolicyAndTools() async throws {
        var cfg = OffloadConfig()
        cfg.agent.permissions = PermissionPolicy(mode: .readOnly)
        cfg.agent.webTools = true
        let replies = Replies([#"{"thought":"x","tool":"open_app","args":{"name":"Mail"}}"#, #"{"thought":"x","tool":"finish","args":{"status":"DONE","summary":"ok"}}"#])
        let model = MockModel { replies.next($0) }
        let rt = try runtime(cfg, model: model)
        let computer = FakeComputer()
        let (agent, notice) = await rt.makeAgent(computer: computer, confirm: { _ in true })
        XCTAssertNil(notice)
        _ = await agent.run(task: "t")
        let prompt = replies.requests[0].messages[0].text
        XCTAssertTrue(prompt.contains("propose_note_edit"), "note editing is on by default")
        XCTAssertTrue(prompt.contains("web_fetch") && prompt.contains("web_search"), "web tools appear once the user turns them on")
        XCTAssertTrue(replies.requests[1].messages.last!.text.contains("denied:"), "the configured read-only policy applied")
        XCTAssertTrue(computer.log.isEmpty)

        var off = OffloadConfig()
        off.agent.noteEditing = false
        let r2 = Replies([#"{"thought":"x","tool":"finish","args":{"status":"DONE","summary":"ok"}}"#])
        let rt2 = try Runtime(paths: AppPaths(support: base.appendingPathComponent("home2")), config: off, models: (MockModel { r2.next($0) }, MockModel { r2.next($0) }, MockModel { r2.next($0) }))
        _ = await rt2.makeAgent(computer: nil, confirm: { _ in true }).agent.run(task: "t")
        XCTAssertFalse(r2.requests[0].messages[0].text.contains("propose_note_edit") || r2.requests[0].messages[0].text.contains("web_fetch"))
    }

    func testConfiguredAppsBecomeToolsAndAFailingOneIsReportedNotFatal() async throws {
        let script = try writeStubMCPServer(into: base)
        var cfg = OffloadConfig()
        cfg.mcpServers = [MCPServerConfig(name: "stub", command: script, readOnly: true), MCPServerConfig(name: "ghost", command: "/nonexistent/server")]
        cfg.agent.noteEditing = false
        let replies = Replies([#"{"thought":"x","tool":"mcp__stub__echo","args":{"text":"hi 4111 1111 1111 1111"}}"#, #"{"thought":"x","tool":"finish","args":{"status":"DONE","summary":"ok"}}"#])
        let rt = try runtime(cfg, model: MockModel { replies.next($0) })
        let (agent, notice) = await rt.makeAgent(computer: nil, confirm: { _ in XCTFail("a read-only app needs no approval"); return false })
        XCTAssertTrue(notice?.contains("ghost") == true, "the user is told one app could not be reached: \(notice ?? "nil")")
        let result = await agent.run(task: "t")
        XCTAssertEqual(result.status, .done)
        let prompt = replies.requests[0].messages[0].text
        XCTAssertTrue(prompt.contains("mcp__stub__echo") && prompt.contains("mcp__stub__delete_all"), "three tools are listed, not hidden")
        let observation = replies.requests[1].messages.last!.text
        XCTAssertTrue(observation.contains("echo: hi [REDACTED:card]"), "arguments were scrubbed before the app saw them: \(observation)")
        XCTAssertTrue(observation.contains("external source"))
        await rt.shutdownAssistantTools()

        let off = await rt.makeAgent(computer: nil, confirm: { _ in true }, overrides: { var o = AssistantOverrides(); o.useMCP = false; return o }())
        XCTAssertNil(off.notice, "--no-mcp skips the apps entirely")
        await rt.shutdownAssistantTools()
    }

    func testAgentSettingsDecodeFromOldAndPartialConfigs() throws {
        XCTAssertEqual(try JSONDecoder().decode(OffloadConfig.self, from: Data("{}".utf8)).agent, AgentSettings())
        let partial = try JSONDecoder().decode(OffloadConfig.self, from: Data(#"{"agent":{"webTools":true,"permissions":{"mode":"write","deny":["open_url"]}}}"#.utf8))
        XCTAssertTrue(partial.agent.webTools)
        XCTAssertTrue(partial.agent.noteEditing, "an unset key keeps its default")
        XCTAssertEqual(partial.agent.permissions.mode, .write)
        XCTAssertEqual(partial.agent.permissions.deny.map(\.raw), ["open_url"])
        let saved = AppPaths(support: base.appendingPathComponent("cfg"))
        var cfg = OffloadConfig()
        cfg.mcpServers = [MCPServerConfig(name: "n", command: "c", env: ["K": "keychain:a"])]
        cfg.agent.permissions.allow = [PermissionRule("mcp__n__*")]
        try saved.save(cfg)
        XCTAssertEqual(try saved.loadConfig(), cfg)
    }
}
