import XCTest
@testable import OffloadCore

/// A task handed to a backend that runs its own loop (Claude's command-line tool): its tool calls come back
/// here and go through the same permission, approval, hook and limit machinery as the assistant's own.
final class AgentDelegationTests: XCTestCase {
    var base: URL!
    var memory: MemoryService!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("offload-deleg-\(UUID().uuidString)")
        let ws = VaultWorkspace(root: base.appendingPathComponent("vault"))
        let store = try T.store()
        let staging = try ws.makeStaging()
        let notes = ["README.md": "# About\nA founder.", "Home/Apartment.md": "# Apartment\nLandlord is Mr. Alvarez; rent $3,400.\n"]
        try ws.write(notes, paths: Array(notes.keys), into: staging)
        try ws.swap(staging: staging)
        let indexer = Indexer(store: store, embedder: HashingEmbedder())
        for (p, b) in notes { try await indexer.indexNote(path: p, body: b) }
        memory = MemoryService(store: store, searcher: HybridSearcher(store: store, embedder: HashingEmbedder()), workspace: ws)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func agent(_ model: LanguageModel, computer: ComputerController? = FakeComputer(), options: AgentOptions = AgentOptions(),
               confirm: @escaping @Sendable (String) async -> Bool = { _ in true }, ask: @escaping @Sendable (String) async -> String? = { _ in nil }) -> Agent {
        Agent(model: model, memory: memory, computer: computer, confirm: confirm, ask: ask, options: options)
    }

    // MARK: What is handed over

    func testTheWholeRegistryIsOfferedExceptTheLoopsOwnControls() async throws {
        let (mcpTool, _) = probeTool("mcp__notes__add", tier: .act, approval: .always, origin: .mcp(server: "notes"), untrusted: true)
        var options = AgentOptions(); options.extraTools = [mcpTool, NoteTools.proposeEdit(memory: memory, editor: VaultEditor(workspace: memory.workspace, store: memory.store, indexer: Indexer(store: memory.store, embedder: HashingEmbedder())))]
        let model = DelegatingMockModel { _, _ in "All done." }
        let result = await agent(model, options: options).run(task: "tidy up")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.summary, "All done.")
        let task = try XCTUnwrap(model.tasks.first)
        let offered = Set(task.tools)
        for expected in ["search_memory", "read_note", "read_item", "click", "type", "key", "scroll", "open_app", "open_url", "open_source", "screenshot", "screen_text",
                         "propose_note_edit", "mcp__notes__add", "ask_user", "todo_write"] {
            XCTAssertTrue(offered.contains(expected), "\(expected) is offered; got \(offered.sorted())")
        }
        XCTAssertFalse(offered.contains("finish"), "Claude ends its own loop")
        XCTAssertFalse(offered.contains("tool_search"))
        XCTAssertTrue(task.task.hasPrefix("THE TASK: tidy up"))
        XCTAssertTrue(task.system.contains("DATA"), "the injection rule is in the instructions")
        XCTAssertTrue(task.system.contains("COULD_NOT"))
        XCTAssertFalse(task.system.contains("call finish"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: task.endpoint.socketPath).deletingLastPathComponent().path), "the socket is removed when the task ends")
    }

    func testProgressEventsComeFromTheCallsThatReallyHappen() async throws {
        let model = DelegatingMockModel { _, client in
            _ = try client.call("search_memory", arguments: ["query": "landlord"])
            _ = try client.call("open_app", arguments: ["name": "Mail"])
            return "Opened Mail."
        }
        let events = Box<[String]>([])
        let computer = FakeComputer()
        let result = await agent(model, computer: computer).run(task: "t") { e in
            switch e {
            case .step(let n): events.append("step\(n)")
            case .action(let a): events.append("action:\(a.tool)")
            case .observation(let o): events.append("obs:\(o.prefix(8))")
            case .finished: events.append("finished")
            default: break
            }
        }
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(events.value.filter { !$0.hasPrefix("obs") }, ["step1", "action:search_memory", "step2", "action:open_app", "finished"])
        XCTAssertTrue(computer.log.contains("openApp Mail"), "the tool ran in this process, with this process's controller")
    }

    // MARK: Permissions and approvals still decide

    func testPolicyDeniesAndTheIrreversibleBackstopStillAsks() async throws {
        var options = AgentOptions(); options.policy = PermissionPolicy(mode: .act, deny: [PermissionRule("type")])
        let asked = Box<[String]>([])
        let computer = FakeComputer()
        let seen = Box<[String]>([])
        let model = DelegatingMockModel { _, client in
            seen.append(try client.call("type", arguments: ["text": "hello"]).text)
            seen.append(try client.call("click", arguments: ["x": 4, "y": 5]).text)                       // harmless: runs
            seen.append(try client.call("click", arguments: ["x": 400, "y": 300, "irreversible": true]).text) // flagged: asks, then refused
            return "done"
        }
        let result = await agent(model, computer: computer, options: options, confirm: { asked.append($0); return false }).run(task: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(seen.value[0].hasPrefix("denied:"), seen.value[0])
        XCTAssertTrue(seen.value[1].contains("clicked"))
        XCTAssertTrue(seen.value[2].contains("declined"))
        XCTAssertEqual(asked.value.count, 1, "only the flagged click asked")
        XCTAssertEqual(computer.log.filter { $0.hasPrefix("click") }, ["click 4,5"], "the declined click and the denied typing never happened")
        XCTAssertFalse(computer.log.contains { $0.hasPrefix("type") })
    }

    func testAnExternalToolAsksAndItsOutputIsLabelledAndScrubbed() async throws {
        let (tool, probe) = probeTool("mcp__notes__add", tier: .act, approval: .always, origin: .mcp(server: "notes"), untrusted: true, result: "saved; card 4111 1111 1111 1111")
        var options = AgentOptions(); options.extraTools = [tool]
        let asked = Box<[String]>([])
        let out = Box<String>("")
        let model = DelegatingMockModel { _, client in
            out.mutate { $0 = (try? client.call("mcp__notes__add", arguments: ["text": "buy milk"]).text) ?? "" }
            return "ok"
        }
        _ = await agent(model, options: options, confirm: { asked.append($0); return true }).run(task: "t")
        XCTAssertEqual(asked.value.count, 1)
        XCTAssertTrue(asked.value[0].contains("external server"))
        XCTAssertEqual(probe.calls.count, 1)
        XCTAssertTrue(out.value.contains("external source"), "labelled as data: \(out.value)")
        XCTAssertTrue(out.value.contains("[REDACTED:card]"), "a hosted model never sees the card number: \(out.value)")
        XCTAssertFalse(out.value.contains("4111"))
    }

    func testPlanFirstKeepsClaudeReadOnlyUntilThePlanIsApproved() async throws {
        var options = AgentOptions(); options.planFirst = true
        let computer = FakeComputer()
        let seen = Box<[String]>([])
        let model = DelegatingMockModel { task, client in
            XCTAssertTrue(task.system.contains("PLAN FIRST"))
            seen.append(try client.call("open_app", arguments: ["name": "Mail"]).text)                     // refused: still planning
            seen.append(try client.call("search_memory", arguments: ["query": "landlord"]).text)           // lookups are fine
            seen.append(try client.call("exit_plan_mode", arguments: ["plan": "1. Open Mail 2. Reply"]).text)
            seen.append(try client.call("open_app", arguments: ["name": "Mail"]).text)                     // now allowed
            return "done"
        }
        let asked = Box<[String]>([])
        _ = await agent(model, computer: computer, options: options, confirm: { asked.append($0); return true }).run(task: "t")
        XCTAssertTrue(seen.value[0].contains("planning only"), seen.value[0])
        XCTAssertTrue(seen.value[1].contains("Apartment.md"))
        XCTAssertTrue(seen.value[2].contains("Plan approved"))
        XCTAssertTrue(seen.value[3].contains("opened Mail"), seen.value[3])
        XCTAssertEqual(asked.value.count, 1)
        XCTAssertTrue(asked.value[0].hasPrefix("Plan: 1. Open Mail 2. Reply"), "the plan itself is what the user is asked about: \(asked.value[0])")
        XCTAssertEqual(computer.log.filter { $0.hasPrefix("openApp") }, ["openApp Mail"], "once, after approval")
    }

    func testAskUserReachesTheUserThroughTheNotchCallback() async throws {
        let model = DelegatingMockModel { _, client in try client.call("ask_user", arguments: ["question": "Which address?"]).text }
        let result = await agent(model, ask: { q in "work@acme.com (\(q))" }).run(task: "t")
        XCTAssertTrue(result.summary.contains("The user answered: work@acme.com (Which address?)"), result.summary)
    }

    // MARK: Limits

    func testTheStepLimitStopsFurtherCalls() async throws {
        let computer = FakeComputer()
        let replies = Box<[String]>([])
        let model = DelegatingMockModel { _, client in
            for _ in 0..<5 { replies.append(try client.call("scroll", arguments: ["dy": -10]).text) }
            return "I stopped."
        }
        let result = await agent(model, computer: computer).run(task: "t", maxSteps: 3)
        XCTAssertEqual(result.status, .maxSteps)
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(computer.log.filter { $0.hasPrefix("scroll") }.count, 3)
        XCTAssertTrue(replies.value[3].contains("Step limit reached"))
    }

    func testTwoDeclinesAndRepeatedErrorsEndTheTask() async throws {
        let computer = FakeComputer()
        let declineModel = DelegatingMockModel { _, client in
            for _ in 0..<4 { _ = try client.call("click", arguments: ["x": 1, "y": 1, "irreversible": true]) }
            return "gave up"
        }
        let declined = await agent(declineModel, computer: computer, confirm: { _ in false }).run(task: "t")
        XCTAssertEqual(declined.status, .couldNot)
        XCTAssertTrue(declined.summary.contains("declined"))
        XCTAssertTrue(computer.log.isEmpty)

        let errorModel = DelegatingMockModel { _, client in
            for _ in 0..<6 { _ = try client.call("read_note", arguments: ["path": "Nope/Missing.md"]) }
            return "gave up"
        }
        let failed = await agent(errorModel, computer: nil).run(task: "t")
        XCTAssertEqual(failed.status, .failed("repeated tool errors"))
    }

    func testCouldNotInTheFinalMessageIsReported() async throws {
        let model = DelegatingMockModel { _, _ in "COULD_NOT: the lease is not in your notes" }
        let result = await agent(model, computer: nil).run(task: "t")
        XCTAssertEqual(result.status, .couldNot)
        XCTAssertEqual(result.summary, "the lease is not in your notes")
    }

    func testStoppingTheTaskStopsTheModelAndClosesTheHost() async throws {
        let started = Box<Bool>(false)
        let path = Box<String>("")
        let model = DelegatingMockModel { task, _ in
            path.mutate { $0 = task.endpoint.socketPath }
            started.mutate { $0 = true }
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "never"
        }
        let run = Task { await self.agent(model, computer: nil).run(task: "t") }
        while !started.value { try await Task.sleep(nanoseconds: 20_000_000) }
        run.cancel()
        let result = await run.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.value), "the socket is gone")
    }

    func testAModelThatFailsBeforeAnyCallIsAFailureNotAHang() async throws {
        let model = DelegatingMockModel { _, _ in throw LLMError.unavailable("claude is not logged in") }
        let result = await agent(model, computer: nil).run(task: "t")
        XCTAssertEqual(result.status, .failed("model unavailable: claude is not logged in"))
    }

    func testAHostedModelIsGivenATaskWithIdentifiersRemoved() async throws {
        let inner = DelegatingMockModel(isLocal: false) { _, _ in "ok" }
        let hosted = RedactingModel(inner)
        XCTAssertTrue(hosted.capabilities.runsOwnLoop, "the wrapper keeps the capability")
        _ = await agent(hosted, computer: nil).run(task: "pay with 4111 1111 1111 1111")
        XCTAssertFalse(inner.tasks[0].task.contains("4111"))
        XCTAssertTrue(inner.tasks[0].task.contains("[REDACTED:card]"))
    }
}
