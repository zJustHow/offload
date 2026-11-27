import XCTest
@testable import OffloadCore

/// The agent loop on top of the tool layer: policy, approval, planning, hidden tools, native tool calling.
final class AgentToolingTests: XCTestCase {
    var base: URL!
    var memory: MemoryService!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-tooling-\(UUID().uuidString)")
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

    func textAgent(_ replies: Replies, computer: ComputerController? = FakeComputer(), options: AgentOptions = AgentOptions(),
                   confirm: @escaping @Sendable (String) async -> Bool = { _ in true }, ask: @escaping @Sendable (String) async -> String? = { _ in nil }) -> Agent {
        let model = MockModel(contextChars: 40_000, isLocal: true) { replies.next($0) }
        return Agent(model: model, memory: memory, computer: computer, confirm: confirm, ask: ask, options: options)
    }

    func nativeAgent(_ model: NativeMockModel, computer: ComputerController? = FakeComputer(), options: AgentOptions = AgentOptions(),
                     confirm: @escaping @Sendable (String) async -> Bool = { _ in true }) -> Agent {
        Agent(model: model, memory: memory, computer: computer, confirm: confirm, options: options)
    }

    func finish(_ s: String = "ok") -> String { #"{"thought":"x","tool":"finish","args":{"status":"DONE","summary":"\#(s)"}}"# }

    // MARK: Policy

    func testADenyRuleBlocksATool_AndTheModelIsToldSo() async {
        let computer = FakeComputer()
        var options = AgentOptions(); options.policy = PermissionPolicy(mode: .act, deny: [PermissionRule("click")])
        let replies = Replies([#"{"thought":"x","tool":"click","args":{"x":1,"y":2}}"#, finish()])
        let result = await textAgent(replies, computer: computer, options: options).run(task: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertFalse(computer.log.contains { $0.hasPrefix("click") })
        XCTAssertTrue(replies.requests[1].messages.last!.text.contains("denied:"), replies.requests[1].messages.last!.text)
    }

    func testAnAskRuleAsksEvenForAHarmlessAction() async {
        let computer = FakeComputer()
        var options = AgentOptions(); options.policy = PermissionPolicy(mode: .act, ask: [PermissionRule("open_app(Mail)")])
        let asked = Box<[String]>([])
        let replies = Replies([#"{"thought":"x","tool":"open_app","args":{"name":"Notes"}}"#, #"{"thought":"x","tool":"open_app","args":{"name":"Mail"}}"#, finish()])
        let result = await textAgent(replies, computer: computer, options: options, confirm: { asked.append($0); return true }).run(task: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(asked.value.count, 1, "only Mail matches the rule")
        XCTAssertTrue(asked.value[0].contains("open_app(name=Mail)"))
        XCTAssertTrue(asked.value[0].contains("asks for approval"), "a policy question says why it is being asked: \(asked.value[0])")
        XCTAssertEqual(computer.log.filter { $0.hasPrefix("openApp") }, ["openApp Notes", "openApp Mail"])
    }

    func testAReadOnlySessionLooksThingsUpButNeverActs() async {
        let computer = FakeComputer()
        var options = AgentOptions(); options.policy = .readOnly
        let replies = Replies([
            #"{"thought":"x","tool":"search_memory","args":{"query":"landlord"}}"#,
            #"{"thought":"x","tool":"open_app","args":{"name":"Mail"}}"#,
            finish(),
        ])
        _ = await textAgent(replies, computer: computer, options: options).run(task: "t")
        XCTAssertTrue(replies.requests[1].messages.last!.text.contains("Apartment.md"))
        XCTAssertTrue(replies.requests[2].messages.last!.text.contains("denied:"))
        XCTAssertTrue(computer.log.isEmpty)
    }

    // MARK: Planning

    func testPlanFirstBlocksActionsUntilThePlanIsApproved() async {
        let computer = FakeComputer()
        var options = AgentOptions(); options.planFirst = true
        let asked = Box<[String]>([])
        let replies = Replies([
            #"{"thought":"x","tool":"search_memory","args":{"query":"landlord"}}"#,
            #"{"thought":"x","tool":"open_app","args":{"name":"Mail"}}"#,
            #"{"thought":"x","tool":"exit_plan_mode","args":{"plan":"1. Open Mail 2. Find the lease"}}"#,
            #"{"thought":"x","tool":"open_app","args":{"name":"Mail"}}"#,
            finish(),
        ])
        let result = await textAgent(replies, computer: computer, options: options, confirm: { asked.append($0); return true }).run(task: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(replies.requests[0].messages[0].text.contains("PLAN FIRST"))
        XCTAssertTrue(replies.requests[0].messages[0].text.contains("exit_plan_mode"))
        XCTAssertTrue(replies.requests[2].messages.last!.text.contains("planning only"), "acting before approval is refused")
        XCTAssertEqual(asked.value.count, 1)
        XCTAssertTrue(asked.value[0].hasPrefix("Plan: 1. Open Mail"), asked.value[0])
        XCTAssertEqual(computer.log.filter { $0.hasPrefix("openApp") }, ["openApp Mail"], "exactly once, after the plan was approved")
        XCTAssertFalse(replies.requests[4].messages[0].text.contains("PLAN FIRST"), "the planning rule is dropped once approved")
    }

    func testADeclinedPlanKeepsTheAssistantReadOnly() async {
        let computer = FakeComputer()
        var options = AgentOptions(); options.planFirst = true
        let replies = Replies([
            #"{"thought":"x","tool":"exit_plan_mode","args":{"plan":"do it"}}"#,
            #"{"thought":"x","tool":"open_app","args":{"name":"Mail"}}"#,
            finish(),
        ])
        _ = await textAgent(replies, computer: computer, options: options, confirm: { _ in false }).run(task: "t")
        XCTAssertTrue(replies.requests[1].messages.last!.text.contains("DECLINED this plan"))
        XCTAssertTrue(replies.requests[2].messages.last!.text.contains("planning only"))
        XCTAssertTrue(computer.log.isEmpty)
    }

    // MARK: External and hidden tools

    func testAnExternalToolAsksFirstAndItsOutputIsLabelledAsData() async {
        let (tool, probe) = probeTool("mcp__notes__add", tier: .act, approval: .always, origin: .mcp(server: "notes"), untrusted: true, result: "added")
        var options = AgentOptions(); options.extraTools = [tool]
        let asked = Box<[String]>([])
        let replies = Replies([#"{"thought":"save it","tool":"mcp__notes__add","args":{"text":"buy milk"}}"#, finish()])
        _ = await textAgent(replies, computer: nil, options: options, confirm: { asked.append($0); return true }).run(task: "t")
        XCTAssertEqual(asked.value.count, 1, "an unvetted external tool asks even though nothing 'looks irreversible'")
        XCTAssertTrue(asked.value[0].contains("external server"))
        XCTAssertEqual(probe.calls.count, 1)
        let observation = replies.requests[1].messages.last!.text
        XCTAssertTrue(observation.contains("added") && observation.contains("external source"), observation)
    }

    func testManyToolsAreFoundWithToolSearchAndThenListed() async {
        var options = AgentOptions()
        var extras: [Tool] = []
        let probe = Probe()
        for i in 0..<8 { extras.append(probeTool("mcp__cal__tool\(i)", origin: .mcp(server: "cal"), description: i == 3 ? "create a calendar event" : "does thing \(i)", probe: probe).0) }
        options.extraTools = extras
        let replies = Replies([
            #"{"thought":"x","tool":"tool_search","args":{"query":"calendar event"}}"#,
            #"{"thought":"x","tool":"mcp__cal__tool3","args":{"text":"lunch"}}"#,
            finish(),
        ])
        let result = await textAgent(replies, computer: nil, options: options).run(task: "t")
        XCTAssertEqual(result.status, .done)
        let first = replies.requests[0].messages[0].text
        XCTAssertFalse(first.contains("mcp__cal__tool3"), "eight MCP tools are not all listed")
        XCTAssertTrue(first.contains("tool_search"))
        XCTAssertTrue(replies.requests[1].messages.last!.text.contains("mcp__cal__tool3"), "the search result names the tool")
        XCTAssertTrue(replies.requests[1].messages[0].text.contains("mcp__cal__tool3"), "a found tool is listed from then on")
        XCTAssertFalse(replies.requests[1].messages[0].text.contains("mcp__cal__tool5"))
        XCTAssertEqual(probe.calls.count, 1)
    }

    func testAskUserCanOfferOptions() async {
        let seen = Box<[String]>([])
        let replies = Replies([#"{"thought":"x","tool":"ask_user","args":{"question":"Which email?","options":["work","home"]}}"#, finish()])
        _ = await textAgent(replies, computer: nil, ask: { seen.append($0); return "2" }).run(task: "t")
        XCTAssertTrue(seen.value[0].contains("1. work") && seen.value[0].contains("2. home"))
        XCTAssertTrue(replies.requests[1].messages.last!.text.contains("The user answered: home"), "a number picks the option")
    }

    // MARK: Native tool calling

    func testNativeToolCallingRunsParallelCallsAndPairsEveryResult() async {
        let model = NativeMockModel([
            ModelReply(text: "look both up", toolCalls: [nativeCall("c1", "search_memory", ["query": "landlord"]), nativeCall("c2", "read_item", ["id": "lease"])]),
            ModelReply(text: "", toolCalls: [nativeCall("c3", "finish", ["status": "DONE", "summary": "found it"])]),
        ])
        let events = Box<[String]>([])
        let result = await nativeAgent(model).run(task: "Who is my landlord?") { e in if case .action(let a) = e { events.append(a.tool) } }
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.summary, "found it")
        XCTAssertEqual(events.value, ["search_memory", "read_item", "finish"])

        let second = model.requests[1].request.messages
        let results = second.last!.toolResults
        XCTAssertEqual(results.map(\.toolCallID), ["c1", "c2"], "every call gets its own result, in order")
        XCTAssertTrue(results[0].text.contains("Apartment.md"))
        XCTAssertTrue(results[1].text.contains("LD-55821"))
        XCTAssertEqual(second[second.count - 2].toolCalls.map(\.id), ["c1", "c2"])
        XCTAssertFalse(model.requests[0].request.messages[0].text.contains("Reply with ONE JSON object"), "the text protocol is not used")
        XCTAssertTrue(model.requests[0].tools.contains { $0.name == "search_memory" } && model.requests[0].tools.contains { $0.name == "finish" })
    }

    func testNativeIrreversibleFlagTriggersConfirmationAndADeclineIsReported() async {
        let computer = FakeComputer()
        let model = NativeMockModel([
            ModelReply(text: "send it", toolCalls: [nativeCall("c1", "click", ["x": 5, "y": 6, "irreversible": true])]),
            ModelReply(text: "again", toolCalls: [nativeCall("c2", "click", ["x": 5, "y": 6, "irreversible": true])]),
        ])
        let asked = Box<[String]>([])
        let result = await nativeAgent(model, computer: computer, confirm: { asked.append($0); return false }).run(task: "t")
        XCTAssertEqual(asked.value.count, 2)
        XCTAssertEqual(result.status, .couldNot)
        XCTAssertTrue(computer.log.isEmpty, "a declined action never runs")
        let click = model.requests[0].tools.first { $0.name == "click" }
        XCTAssertNotNil(click?.inputSchema["properties"]?[ToolSpec.irreversibleFlag], "the model is offered the flag")
        XCTAssertTrue(model.requests[1].request.messages.last!.toolResults[0].text.contains("DECLINED"))
        XCTAssertTrue(model.requests[1].request.messages.last!.toolResults[0].isError)
    }

    func testNativeProseAnswerEndsTheRunAndTheChecklistIsReported() async {
        let todos = Box<[[TodoItem]]>([])
        let model = NativeMockModel([
            ModelReply(text: "", toolCalls: [nativeCall("c1", "todo_write", ["todos": [["content": "look up", "status": "in_progress"], ["content": "answer", "status": "pending"]]])]),
            ModelReply(text: "The landlord is Mr. Alvarez."),
        ])
        let result = await nativeAgent(model).run(task: "t") { e in if case .todos(let t) = e { todos.mutate { $0.append(t) } } }
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.summary, "The landlord is Mr. Alvarez.")
        XCTAssertEqual(todos.value.first?.map(\.content), ["look up", "answer"])
        XCTAssertEqual(todos.value.first?.first?.status, .inProgress)
    }

    func testNativeModeCanBeSwitchedOffAndOtherModelsKeepTheTextProtocol() async {
        var options = AgentOptions(); options.nativeTools = false
        let model = NativeMockModel([])
        let agent = nativeAgent(model, options: options)
        XCTAssertTrue(agent.systemPrompt().contains("Reply with ONE JSON object"))
        XCTAssertFalse(agent.systemPrompt().contains("todo_write"), "a text-protocol model is not shown the checklist tool")
        XCTAssertFalse(nativeAgent(NativeMockModel([])).systemPrompt().contains("Reply with ONE JSON object"))
    }

    func testLongRunsCompactTheirHistoryInsteadOfLosingIt() async {
        let model = MockModel(contextChars: 3_000, isLocal: true) { _ in #"{"thought":"again","tool":"read_item","args":{"id":"lease"}}"# }
        let result = await Agent(model: model, memory: memory, computer: nil, confirm: { _ in true }).run(task: "keep going", maxSteps: 12)
        XCTAssertEqual(result.status, .maxSteps)
        let last = model.requests.last!.messages
        XCTAssertLessThan(HistoryCompactor.size(of: last), 4_500)
        XCTAssertTrue(last[1].text.contains(HistoryCompactor.marker))
        XCTAssertTrue(last[1].text.contains("read_item(id=lease)"))
    }

    func testAnAppCanReceiveTheFullApprovalRequestInsteadOfPlainText() async {
        let seen = Box<[String]>([])
        let plain = Box<[String]>([])
        var options = AgentOptions(); options.planFirst = true
        options.approval = { request in seen.append("\(request.spec.name)|\(request.call.arguments.string("plan") ?? "")|\(request.reason)"); return true }
        let replies = Replies([#"{"thought":"x","tool":"exit_plan_mode","args":{"plan":"1. look 2. act"}}"#, #"{"thought":"x","tool":"open_app","args":{"name":"Mail"}}"#, finish()])
        let result = await textAgent(replies, computer: FakeComputer(), options: options, confirm: { plain.append($0); return false }).run(task: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(seen.value, ["exit_plan_mode|1. look 2. act|'exit_plan_mode' needs your approval"], "the app gets the tool, the plan itself and the reason")
        XCTAssertTrue(plain.value.isEmpty, "the plain confirm closure is not used when the app handles approvals itself")
    }

    func testAskUserCanUseTheAppsOwnChoiceDialog() async {
        var options = AgentOptions()
        options.askChoice = { question, choices in "picked:\(choices.last ?? "")" }
        let replies = Replies([#"{"thought":"x","tool":"ask_user","args":{"question":"Which?","options":["a","b"]}}"#, finish()])
        _ = await textAgent(replies, computer: nil, options: options, ask: { _ in XCTFail("the text fallback must not be used"); return nil }).run(task: "t")
        XCTAssertTrue(replies.requests[1].messages.last!.text.contains("The user answered: picked:b"))
    }

    // MARK: Native runs against models that think

    func testNativeRunsFreezeThePromptAndToolListAndKeepSignedBlocks() async {
        var options = AgentOptions(); options.planFirst = true
        var extras: [Tool] = []
        for i in 0..<9 { extras.append(probeTool("mcp__cal__tool\(i)", origin: .mcp(server: "cal")).0) }
        options.extraTools = extras
        let signed: [JSONValue] = [["type": "thinking", "thinking": "", "signature": "SIG=="], ["type": "tool_use", "id": "c1", "name": "exit_plan_mode", "input": ["plan": "1. look"]]]
        let model = NativeMockModel([
            ModelReply(text: "", toolCalls: [nativeCall("c1", "exit_plan_mode", ["plan": "1. look"])], stopReason: "tool_use", providerBlocks: signed),
            ModelReply(text: "", toolCalls: [nativeCall("c2", "search_memory", ["query": "landlord"])], stopReason: "tool_use"),
            ModelReply(text: "Done: Mr. Alvarez.", stopReason: "end_turn"),
        ])
        let result = await nativeAgent(model, computer: nil, options: options).run(task: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(model.requests.count, 3)

        let prompts = model.requests.map { $0.request.messages[0].text }
        XCTAssertEqual(Set(prompts).count, 1, "the system prompt is byte-identical on every step, even after the plan was approved")
        XCTAssertTrue(prompts[0].contains("PLAN FIRST"))
        let toolNames = model.requests.map { $0.tools.map(\.name) }
        XCTAssertEqual(Set(toolNames.map { $0.joined(separator: ",") }).count, 1, "the tool list is identical on every step")
        XCTAssertTrue(toolNames[0].contains("mcp__cal__tool8"), "all nine MCP tools are listed from the start")
        XCTAssertFalse(toolNames[0].contains("tool_search"), "no tool is hidden behind a search in a native run")

        let replayed = model.requests[1].request.messages.first { $0.role == .assistant }
        XCTAssertEqual(replayed?.providerBlocks, signed, "the model's own blocks, signature included, go back untouched")
    }

    func testRefusedAndCutOffNativeRepliesNeverRunATool() async {
        let computer = FakeComputer()
        let refused = NativeMockModel([ModelReply(text: "", toolCalls: [nativeCall("c1", "click", ["x": 1, "y": 2])], stopReason: "refusal")])
        let r1 = await nativeAgent(refused, computer: computer).run(task: "t")
        XCTAssertEqual(r1.status, .failed("refused"))

        let cut = NativeMockModel([
            ModelReply(text: "I will", toolCalls: [nativeCall("c1", "click", ["x": 1])], stopReason: "max_tokens"),
            ModelReply(text: "Done.", stopReason: "end_turn"),
        ])
        let r2 = await nativeAgent(cut, computer: computer).run(task: "t")
        XCTAssertEqual(r2.status, .done)
        XCTAssertTrue(computer.log.isEmpty, "a tool call in a cut-off reply may be incomplete, so it is not run")
        XCTAssertTrue(cut.requests[1].request.messages.last!.text.contains("cut off"))
        XCTAssertTrue(cut.requests[1].request.messages.dropLast().allSatisfy { $0.toolCalls.isEmpty }, "the truncated call is not kept in the history")
    }

    func testRewritingHistoryDropsSignedBlocksOnce() {
        let signed: [JSONValue] = [["type": "thinking", "thinking": "", "signature": "SIG=="]]
        var msgs: [ChatMessage] = [.system("sys"), .user("THE TASK: t")]
        for i in 0..<8 {
            msgs.append(.assistant("step \(i)", toolCalls: [nativeCall("c\(i)", "read_item", ["id": "lease"])], providerBlocks: signed))
            msgs.append(.toolResults([ToolResultBlock(toolCallID: "c\(i)", name: "read_item", text: String(repeating: "x", count: 600))]))
        }
        let untouched = HistoryCompactor.compact(msgs, budget: 100_000)
        XCTAssertEqual(untouched, msgs, "nothing is rewritten while it fits, so the signatures stay valid")
        let compacted = HistoryCompactor.compact(msgs, budget: 3_000)
        XCTAssertLessThan(compacted.count, msgs.count)
        XCTAssertTrue(compacted.allSatisfy { $0.providerBlocks.isEmpty }, "once history is rewritten, the old signed blocks are dropped")
        XCTAssertFalse(compacted[2].toolCalls.isEmpty, "the calls themselves stay, so every result still has its call")
    }
}
