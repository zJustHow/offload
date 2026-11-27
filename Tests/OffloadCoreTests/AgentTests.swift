import XCTest
@testable import OffloadCore

final class FakeComputer: ComputerController, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var log: [String] = []
    func record(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
    func screenshot() async throws -> Data { record("screenshot"); return Data([0xFF, 0xD8, 0xFF]) }
    func click(x: Int, y: Int, double: Bool) async throws { record("click \(x),\(y)\(double ? " x2" : "")") }
    func type(_ text: String) async throws { record("type \(text)") }
    func key(_ combo: String) async throws { record("key \(combo)") }
    func scroll(dx: Int, dy: Int) async throws { record("scroll \(dx),\(dy)") }
    func openApp(_ name: String) async throws { record("openApp \(name)") }
    func openURL(_ url: URL) async throws { record("openURL \(url.absoluteString)") }
    func openFile(path: String) async throws { record("openFile \(path)") }
}

/// Replays canned model replies in order and records every request.
final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String]
    private(set) var requests: [CompletionRequest] = []
    init(_ replies: [String]) { queue = replies }
    func next(_ r: CompletionRequest) -> String {
        lock.lock(); defer { lock.unlock() }
        requests.append(r)
        return queue.isEmpty ? #"{"thought":"out of script","tool":"finish","args":{"status":"COULD_NOT","summary":"script ended"}}"# : queue.removeFirst()
    }
}

final class AgentTests: XCTestCase {
    var base: URL!
    var memory: MemoryService!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-agent-\(UUID().uuidString)")
        let ws = VaultWorkspace(root: base.appendingPathComponent("vault"))
        let store = try T.store()
        let staging = try ws.makeStaging()
        let notes = ["README.md": "# About\nA founder.", "Home/Apartment.md": "# Apartment\nLandlord is Mr. Alvarez; rent $3,400.\n"]
        try ws.write(notes, paths: Array(notes.keys), into: staging)
        try ws.swap(staging: staging)
        let indexer = Indexer(store: store, embedder: HashingEmbedder())
        for (p, b) in notes { try await indexer.indexNote(path: p, body: b) }
        try store.upsertItem(ItemRecord(id: "lease", bucket: "b", kind: .file, uri: "/docs/lease.md", title: "Lease", itemDate: nil, fingerprint: "1", summary: "Lease summary", verdict: .survivor, trust: .authored))
        try await indexer.indexChunks(itemID: "lease", texts: ["Deposit reference LD-55821 paid 3 March."])
        memory = MemoryService(store: store, searcher: HybridSearcher(store: store, embedder: HashingEmbedder()), workspace: ws)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func makeAgent(_ replies: Replies, vision: Bool = false, isLocal: Bool = true, computer: ComputerController? = FakeComputer(), confirm: @escaping @Sendable (String) async -> Bool = { _ in true }, ask: @escaping @Sendable (String) async -> String? = { _ in nil }) -> Agent {
        let model = MockModel(vision: vision, contextChars: 40_000, isLocal: isLocal) { replies.next($0) }
        return Agent(model: model, memory: memory, computer: computer, confirm: confirm, ask: ask)
    }

    func testMemoryThenFinish() async {
        let replies = Replies([
            #"{"thought":"look it up","tool":"search_memory","args":{"query":"who is my landlord"}}"#,
            #"{"thought":"got it","tool":"finish","args":{"status":"DONE","summary":"Landlord is Mr. Alvarez"}}"#,
        ])
        let result = await makeAgent(replies, computer: nil).run(task: "Who is my landlord?")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.summary, "Landlord is Mr. Alvarez")
        XCTAssertEqual(result.steps, 2)
        let obs = replies.requests[1].messages.last!.text
        XCTAssertTrue(obs.contains("Apartment.md"), "the search result is fed back as an observation")
        XCTAssertFalse(replies.requests[0].messages[0].text.contains("click {"), "no computer tools are advertised without a controller")
    }

    func testIrreversibleActionsNeedConfirmationAndDeclinesAreRespected() async {
        let computer = FakeComputer()
        let replies = Replies([
            #"{"thought":"press Send to send the email","tool":"click","args":{"x":400,"y":300},"risk":"none"}"#,   // model under-reports risk
            #"{"thought":"try again","tool":"click","args":{"x":400,"y":300},"risk":"irreversible"}"#,
        ])
        let asked = Box<[String]>([])
        let result = await makeAgent(replies, computer: computer, confirm: { desc in asked.append(desc); return false }).run(task: "Email my landlord")
        XCTAssertEqual(asked.value.count, 2, "keyword backstop caught the unflagged Send, the flag caught the second")
        XCTAssertEqual(result.status, .couldNot)
        XCTAssertFalse(computer.log.contains { $0.hasPrefix("click") }, "a declined action must never execute")
        XCTAssertTrue(replies.requests[1].messages.last!.text.contains("DECLINED"))
    }

    func testConfirmedActionExecutesAndRoutineActionsDoNotAskForConfirmation() async {
        let computer = FakeComputer()
        let replies = Replies([
            #"{"thought":"open the mail app","tool":"open_app","args":{"name":"Mail"}}"#,
            #"{"thought":"click the search field","tool":"click","args":{"x":10,"y":20}}"#,
            #"{"thought":"click Send","tool":"click","args":{"x":400,"y":300},"risk":"irreversible"}"#,
            #"{"thought":"done","tool":"finish","args":{"status":"DONE","summary":"sent"}}"#,
        ])
        let asked = Box<[String]>([])
        let result = await makeAgent(replies, computer: computer, confirm: { asked.append($0); return true }).run(task: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(asked.value.count, 1, "only the Send click is gated")
        XCTAssertTrue(computer.log.contains("click 400,300"))
        XCTAssertTrue(computer.log.contains("openApp Mail"))
    }

    func testRiskClassifierCoversEnglishChineseAndEnterKey() {
        func a(_ tool: String, _ thought: String, _ args: JSONObject = [:], flagged: Bool = false) -> AgentAction {
            AgentAction(thought: thought, tool: tool, args: args, declaredIrreversible: flagged)
        }
        XCTAssertTrue(RiskClassifier.isIrreversible(a("click", "click the Submit button")))
        XCTAssertTrue(RiskClassifier.isIrreversible(a("click", "点击发送按钮")))
        XCTAssertTrue(RiskClassifier.isIrreversible(a("type", "type address", ["text": "please delete my account"])))
        XCTAssertTrue(RiskClassifier.isIrreversible(a("key", "confirm field", ["combo": "Return"])))
        XCTAssertTrue(RiskClassifier.isIrreversible(a("click", "ok", flagged: true)))
        XCTAssertFalse(RiskClassifier.isIrreversible(a("click", "click the search field")))
        XCTAssertFalse(RiskClassifier.isIrreversible(a("search_memory", "send me the files", ["query": "submit"])), "memory lookups are never gated")
        XCTAssertFalse(RiskClassifier.isIrreversible(a("click", "open the postal map")), "word boundaries: 'post' is not 'postal'")
    }

    func testBadRepliesAreRetriedThenFail() async {
        let replies = Replies(["I think I should look at the screen.", "still prose", "no json here either"])
        let result = await makeAgent(replies).run(task: "t")
        XCTAssertEqual(result.status, .failed("unparseable replies"))
        XCTAssertTrue(replies.requests[1].messages.last!.text.contains("ONLY a JSON object"))
    }

    func testStepLimitAndToolErrorsStopRunaways() async {
        let loop = Replies(Array(repeating: #"{"thought":"again","tool":"search_memory","args":{"query":"landlord"}}"#, count: 10))
        let r1 = await makeAgent(loop, computer: nil).run(task: "t", maxSteps: 4)
        XCTAssertEqual(r1.status, .maxSteps)
        XCTAssertEqual(r1.steps, 4)

        let errors = Replies(Array(repeating: #"{"thought":"x","tool":"teleport","args":{}}"#, count: 10))
        let r2 = await makeAgent(errors, computer: nil).run(task: "t")
        XCTAssertEqual(r2.status, .failed("repeated tool errors"))
    }

    func testOpenToolsAreRestricted() async {
        let computer = FakeComputer()
        let replies = Replies([
            #"{"thought":"x","tool":"open_url","args":{"url":"file:///etc/passwd"}}"#,
            #"{"thought":"x","tool":"open_url","args":{"url":"javascript:alert(1)"}}"#,
            #"{"thought":"x","tool":"open_source","args":{"uri":"/etc/passwd"}}"#,
            #"{"thought":"x","tool":"open_source","args":{"uri":"/docs/lease.md"}}"#,
            #"{"thought":"x","tool":"open_url","args":{"url":"https://example.com/page"}}"#,
            #"{"thought":"x","tool":"finish","args":{"status":"DONE","summary":"ok"}}"#,
        ])
        _ = await makeAgent(replies, computer: computer, confirm: { _ in true }).run(task: "t")
        XCTAssertEqual(computer.log.filter { $0.hasPrefix("openURL") }, ["openURL https://example.com/page"])
        XCTAssertEqual(computer.log.filter { $0.hasPrefix("openFile") }, ["openFile /docs/lease.md"], "only files Offload indexed can be opened")
    }

    func testReadItemReturnsRawTextToAnyModel() async {
        let replies = Replies([
            #"{"thought":"x","tool":"read_item","args":{"id":"lease"}}"#,
            #"{"thought":"x","tool":"finish","args":{"status":"DONE","summary":"ok"}}"#,
        ])
        _ = await makeAgent(replies, isLocal: false, computer: nil).run(task: "t")
        let obs = replies.requests[1].messages.last!.text
        XCTAssertTrue(obs.contains("Summary: Lease summary"))
        XCTAssertTrue(obs.contains("LD-55821"))
    }

    func testAskUserAndVisionScreenshots() async {
        let replies = Replies([
            #"{"thought":"need info","tool":"ask_user","args":{"question":"Which email?"}}"#,
            #"{"thought":"look","tool":"screenshot","args":{}}"#,
            #"{"thought":"done","tool":"finish","args":{"status":"DONE","summary":"ok"}}"#,
        ])
        let result = await makeAgent(replies, vision: true, ask: { _ in "work email" }).run(task: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(replies.requests[1].messages.last!.text.contains("work email"))
        XCTAssertEqual(replies.requests[2].messages.last!.images.count, 1, "vision models receive the screenshot")
    }

    func testPromptsCarryTheInjectionGuard() {
        let prompt = makeAgent(Replies([])).systemPrompt()
        XCTAssertTrue(prompt.contains("ONLY task"))
        XCTAssertTrue(prompt.contains("DATA"))
        XCTAssertTrue(prompt.contains("irreversible"))
    }

    func testHistoryCompactionKeepsTaskAndRecentTurnsAndDigestsTheRest() {
        var msgs: [ChatMessage] = [.system("sys"), .user("THE TASK: find the lease")]
        for i in 0..<20 {
            msgs.append(.assistant(#"{"thought":"t","tool":"search_memory","args":{"query":"q\#(i)"}}"# + String(repeating: " ", count: 500)))
            msgs.append(.user("Observation: result \(i) " + String(repeating: "y", count: 500)))
        }
        let compacted = HistoryCompactor.compact(msgs, budget: 4_000)
        XCTAssertEqual(compacted[0].text, "sys")
        XCTAssertTrue(compacted[1].text.hasPrefix("THE TASK: find the lease"), "the task stays first")
        XCTAssertTrue(compacted[1].text.contains(HistoryCompactor.marker), "older steps are summarized into the task message")
        XCTAssertTrue(compacted[1].text.contains("search_memory(query=q"), "the digest says what was done")
        XCTAssertTrue(compacted[1].text.contains("result"), "...and what came back")
        XCTAssertEqual(compacted.last?.text, msgs.last?.text, "recent steps are kept verbatim")
        XCTAssertEqual(compacted.count, 2 + 4, "system, task, and the last two steps")
        XCTAssertEqual(compacted[2].role, .assistant, "a step is never split from its observation")
        XCTAssertLessThan(HistoryCompactor.size(of: compacted), HistoryCompactor.size(of: msgs))
        XCTAssertLessThan(compacted[1].text.count, 2_400, "the digest is capped")
    }

    func testCompactionIsStableWhenRepeatedAndOmitsTheOldestFirst() {
        var msgs: [ChatMessage] = [.system("sys"), .user("THE TASK: t")]
        for i in 0..<60 {
            msgs.append(.assistant(#"{"thought":"t","tool":"read_note","args":{"path":"Folder/Note\#(i).md"}}"#))
            msgs.append(.user("Observation: body \(i) " + String(repeating: "z", count: 300)))
            msgs = HistoryCompactor.compact(msgs, budget: 3_000)
        }
        XCTAssertLessThanOrEqual(HistoryCompactor.size(of: msgs), 3_400)
        XCTAssertTrue(msgs[1].text.contains("earlier steps not listed"), msgs[1].text)
        XCTAssertTrue(msgs[1].text.contains("Note5"), "the newest digest lines survive: \(msgs[1].text)")
        XCTAssertFalse(msgs[1].text.contains("Note0.md"), "the oldest were dropped first")
        XCTAssertEqual(msgs.filter { $0.role == .user }.count, msgs.filter { $0.role == .assistant }.count + 1, "pairs stay whole: the task is the one extra user message")
    }

    func testNothingIsChangedWhileTheConversationFits() {
        let msgs: [ChatMessage] = [.system("sys"), .user("task"), .assistant("{}"), .user("Observation: ok")]
        XCTAssertEqual(HistoryCompactor.compact(msgs, budget: 10_000), msgs)
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}
extension Box where T == [String] { func append(_ s: String) { mutate { $0.append(s) } } }
