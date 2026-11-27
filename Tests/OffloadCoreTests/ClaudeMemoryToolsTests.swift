import XCTest
@testable import OffloadCore

/// The Claude subscription model answering questions with Offload's read-only MCP server wired in.
final class ClaudeMemoryToolsTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("offload-claudetools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func script(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    var server: ClaudeCLIModel.MemoryServer {
        ClaudeCLIModel.MemoryServer(executable: URL(fileURLWithPath: "/Applications/Offload.app/Contents/MacOS/offload"), home: URL(fileURLWithPath: "/Users/me/Library/Application Support/Offload"))
    }

    // MARK: Arguments

    func testWithoutAServerTheArgumentsAreExactlyTheOldOnes() {
        XCTAssertEqual(ClaudeCLIModel.arguments(system: "s", model: "m", memoryServer: nil), ClaudeCLIModel.arguments(system: "s", model: "m"))
        XCTAssertFalse(ClaudeCLIModel.arguments(system: nil, model: nil).contains("--mcp-config"))
    }

    func testTheServerIsWiredInWithOnlyItsReadOnlyToolsAllowedAndStillNoBuiltInTools() throws {
        let args = ClaudeCLIModel.arguments(system: "SYS", model: "sonnet", memoryServer: server)
        XCTAssertEqual(Array(args.prefix(9)), ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", ""], "no built-in tools, and only the servers named here")
        let configIndex = try XCTUnwrap(args.firstIndex(of: "--mcp-config"))
        let config = try XCTUnwrap(JSONValue(jsonText: args[configIndex + 1]))
        let entry = try XCTUnwrap(config["mcpServers"]?["offload"])
        XCTAssertEqual(entry["command"], "/Applications/Offload.app/Contents/MacOS/offload")
        XCTAssertEqual(entry["args"], ["mcp"])
        XCTAssertEqual(entry["env"]?["OFFLOAD_HOME"], "/Users/me/Library/Application Support/Offload", "it reads this installation, wherever it lives")
        XCTAssertEqual(config["mcpServers"]?.asObject?.count, 1, "no server but Offload's own")

        let allowed = try XCTUnwrap(args.firstIndex(of: "--allowedTools"))
        XCTAssertEqual(args[allowed + 1], "mcp__offload__get_structure,mcp__offload__get_files,mcp__offload__search_memory,mcp__offload__read_item")
        XCTAssertEqual(Array(args.suffix(4)), ["--model", "sonnet", "--system-prompt", "SYS"])
    }

    func testTheAllowListIsExactlyWhatTheServerOffers() async throws {
        // If the server gains a tool, this fails until someone decides whether the Claude command may use it.
        let ws = VaultWorkspace(root: dir.appendingPathComponent("vault"))
        let store = try T.store()
        let memory = MemoryService(store: store, searcher: HybridSearcher(store: store, embedder: HashingEmbedder()), workspace: ws)
        let registry = MCPServer(memory: memory).registry
        XCTAssertEqual(registry.specs.map(\.name), MCPServer.toolNames)
        XCTAssertTrue(registry.specs.allSatisfy { $0.tier == .readOnly }, "everything the command may call only reads")
        XCTAssertEqual(server.allowedTools, MCPServer.toolNames.map { "mcp__offload__" + $0 })
    }

    // MARK: Running

    func testOnlyAQuestionThatAsksForLookupsGetsTheServer() async throws {
        let argLog = dir.appendingPathComponent("args.txt").path
        let fake = try script("claude", """
        printf '%s\\n' "$@" > "\(argLog)"
        cat > /dev/null
        printf '{"type":"result","is_error":false,"result":"ok"}'
        """)
        let withServer = try ClaudeCLIModel(executable: fake, memoryServer: server)
        XCTAssertTrue(withServer.capabilities.canLookUp)
        XCTAssertFalse(withServer.capabilities.isLocal, "still a hosted model")
        XCTAssertFalse(try ClaudeCLIModel(executable: fake).capabilities.canLookUp)

        _ = try await withServer.complete(CompletionRequest(messages: [.user("who is my landlord?")], lookups: true))
        let asked = try String(contentsOfFile: argLog, encoding: .utf8)
        XCTAssertTrue(asked.contains("--mcp-config"))
        XCTAssertTrue(asked.contains("mcp__offload__get_files"))
        XCTAssertTrue(asked.contains("--tools\n\n"), "still no built-in tools")
        XCTAssertTrue(asked.contains("--strict-mcp-config"))

        // Reading untrusted items, writing notes, and the agent's own turns never set `lookups`.
        _ = try await withServer.complete(CompletionRequest(messages: [.user("triage this email")]))
        let plain = try String(contentsOfFile: argLog, encoding: .utf8)
        XCTAssertFalse(plain.contains("--mcp-config"), "no tools unless the request asks for lookups")
        XCTAssertFalse(plain.contains("mcp__"))

        // A request for lookups on a model that was not given the server changes nothing.
        _ = try await ClaudeCLIModel(executable: fake).complete(CompletionRequest(messages: [.user("q")], lookups: true))
        XCTAssertFalse(try String(contentsOfFile: argLog, encoding: .utf8).contains("--mcp-config"))
    }

    func testTheServerIsFoundNextToTheAppOrOnTheSearchPath() throws {
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakeOffload = try script("offload-fake", "exit 0")
        try FileManager.default.moveItem(at: fakeOffload, to: bin.appendingPathComponent("offload"))
        let old = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", bin.path + ":" + old, 1); defer { setenv("PATH", old, 1) }
        let found = try XCTUnwrap(ClaudeCLIModel.MemoryServer.locate(home: dir))
        XCTAssertEqual(found.executable.path, bin.appendingPathComponent("offload").path)
        XCTAssertEqual(found.home, dir)
    }

    // MARK: Carrying out a whole task

    func testATaskGetsTheBridgeAsItsOnlyServerAndExactlyTheOfferedTools() throws {
        let endpoint = ToolHost.Endpoint(socketPath: "/tmp/offload-habc/s", token: "tok123")
        let task = DelegatedTask(system: "SYS", task: "THE TASK: x", endpoint: endpoint, tools: ["search_memory", "click", "mcp__notes__add"])
        let file = dir.appendingPathComponent("mcp.json")
        try Data(server.bridgeConfiguration(endpoint).utf8).write(to: file)
        let args = ClaudeCLIModel.taskArguments(task, model: "sonnet", configFile: file)
        XCTAssertEqual(Array(args.prefix(9)), ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", ""], "still no built-in tools, still only the servers named here")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--mcp-config")) + 1], file.path, "the configuration is passed as a file")
        let config = try XCTUnwrap(JSONValue(jsonText: String(contentsOf: file, encoding: .utf8)))
        let entry = try XCTUnwrap(config["mcpServers"]?["offload"])
        XCTAssertEqual(entry["command"], "/Applications/Offload.app/Contents/MacOS/offload")
        XCTAssertEqual(entry["args"], ["mcp", "--host", "/tmp/offload-habc/s"])
        XCTAssertEqual(entry["env"]?["OFFLOAD_HOST_TOKEN"], "tok123", "the token travels in the environment")
        XCTAssertFalse(args.joined(separator: " ").contains("tok123"), "and never on a command line another user could list with ps")
        XCTAssertEqual(config["mcpServers"]?.asObject?.count, 1)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--allowedTools")) + 1], "mcp__offload__search_memory,mcp__offload__click,mcp__offload__mcp__notes__add")
        XCTAssertEqual(Array(args.suffix(4)), ["--model", "sonnet", "--system-prompt", "SYS"])
    }

    func testRunningATaskAgainstAStandInCommand() async throws {
        let log = dir.appendingPathComponent("task-args.txt").path
        let fake = try script("claude", """
        printf '%s\n' "$@" > "\(log)"
        while [ $# -gt 0 ]; do case "$1" in --mcp-config) cp "$2" "\(log).config"; stat -f '%Lp' "$2" > "\(log).mode";; esac; shift; done
        echo "stdin=$(cat)" >> "\(log)"
        echo "key=${ANTHROPIC_API_KEY:-unset}" >> "\(log)"
        printf '{"type":"result","is_error":false,"result":"Created the note."}'
        """)
        setenv("ANTHROPIC_API_KEY", "must-not-leak", 1); defer { unsetenv("ANTHROPIC_API_KEY") }
        let model = try ClaudeCLIModel(executable: fake, taskServer: server)
        XCTAssertTrue(model.capabilities.runsOwnLoop)
        XCTAssertFalse(model.capabilities.canLookUp, "tasks and lookups are separate switches")
        XCTAssertFalse(try ClaudeCLIModel(executable: fake).capabilities.runsOwnLoop)

        let task = DelegatedTask(system: "SYS", task: "THE TASK: add a note", endpoint: .init(socketPath: "/tmp/x/s", token: "t0k"), tools: ["propose_note_edit"])
        let reply = try await model.runTask(task)
        XCTAssertEqual(reply, "Created the note.")
        let seen = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(seen.contains("mcp__offload__propose_note_edit"))
        XCTAssertTrue(seen.contains("stdin=THE TASK: add a note"), "the task is read from stdin, not argv")
        XCTAssertTrue(seen.contains("key=unset"), "the subscription is used, not an API key")
        XCTAssertFalse(seen.contains("t0k"), "the token is not on the command line")
        XCTAssertTrue(try String(contentsOfFile: log + ".config", encoding: .utf8).contains("t0k"), "it is in the private configuration file")
        XCTAssertEqual(try String(contentsOfFile: log + ".mode", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "600")

        let plain = try ClaudeCLIModel(executable: fake)
        do { _ = try await plain.runTask(task); XCTFail("a model without the helper cannot run tasks") }
        catch { XCTAssertTrue("\(error)".contains("offload")) }
    }

    func testStoppingATaskKillsTheCommand() async throws {
        let pidFile = dir.appendingPathComponent("pid").path
        let fake = try script("claude", "echo $$ > \"\(pidFile)\"; cat > /dev/null; sleep 60")
        let model = try ClaudeCLIModel(executable: fake, taskServer: server)
        let task = DelegatedTask(system: "", task: "t", endpoint: .init(socketPath: "/tmp/x/s", token: "t"), tools: [])
        let started = Date()
        let run = Task { try await model.runTask(task) }
        while !FileManager.default.fileExists(atPath: pidFile) { try await Task.sleep(nanoseconds: 20_000_000) }
        run.cancel()
        do { _ = try await run.value; XCTFail("expected cancellation") } catch { /* cancelled */ }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "it did not wait for the sleep to finish")
        let pid = Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotEqual(kill(pid, 0), 0, "the process is gone")
    }

    // MARK: Configuration

    func testTheProfileOptionDecodesFromOldConfigsAndOnlyReachesTheModelWhenAServerIsGiven() throws {
        XCTAssertNil(try JSONDecoder().decode(ModelProfile.self, from: Data(#"{"provider":"claudeCLI"}"#.utf8)).memoryTools)
        XCTAssertEqual(try JSONDecoder().decode(ModelProfile.self, from: Data(#"{"provider":"claudeCLI","memoryTools":true}"#.utf8)).memoryTools, true)
        try XCTSkipUnless(Subprocess.locate("claude") != nil, "the claude command is not installed")
        let profile = ModelProfile(provider: .claudeCLI, memoryTools: true)
        XCTAssertFalse(try Runtime.makeModel(profile).capabilities.canLookUp, "the profile alone does nothing: the runtime has to find the server")
        let model = try Runtime.makeModel(profile, memoryServer: server)
        XCTAssertTrue(model is RedactingModel, "a subscription model is hosted, so everything it is sent is still scrubbed")
        XCTAssertTrue(model.capabilities.canLookUp, "the capability survives the wrapper")
    }

    func testRuntimeSaysSoWhenTheHelperCannotBeFound() throws {
        try XCTSkipUnless(Subprocess.locate("claude") != nil, "the claude command is not installed")
        // The test runner is neither the offload tool nor next to one, and `offload` is not on this PATH.
        let old = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "/usr/bin:/bin", 1); defer { setenv("PATH", old, 1) }
        guard ClaudeCLIModel.MemoryServer.locate(home: dir) == nil else { throw XCTSkip("an offload command exists on this machine's standard paths") }
        var cfg = OffloadConfig()
        cfg.assistant = ModelProfile(provider: .claudeCLI, memoryTools: true)
        let rt = try Runtime(paths: AppPaths(support: dir.appendingPathComponent("home")), config: cfg)
        XCTAssertFalse(rt.assistantModel.capabilities.canLookUp)
        XCTAssertTrue(rt.fallbackNotes.contains { $0.contains("cannot use Offload's tools") }, "\(rt.fallbackNotes)")
    }

    // MARK: Answering

    func testAnsweringOffersTheToolsOnlyToAModelThatCanUseThem() async throws {
        let ws = VaultWorkspace(root: dir.appendingPathComponent("vault"))
        let store = try T.store()
        let memory = MemoryService(store: store, searcher: HybridSearcher(store: store, embedder: HashingEmbedder()), workspace: ws)   // an empty index

        // A model that can look things up gets to try even when the first search found nothing.
        let capable = MockModel(canLookUp: true) { _ in "Mr. Alvarez (Home/Apartment.md)\nUSED: none" }
        let answer = try await MemoryQA(memory: memory, model: capable).ask("Who is my landlord?")
        XCTAssertEqual(answer.text, "Mr. Alvarez (Home/Apartment.md)")
        XCTAssertEqual(capable.requests.count, 1)
        XCTAssertTrue(capable.requests[0].lookups)
        let system = capable.requests[0].messages[0].text
        for tool in MCPServer.toolNames { XCTAssertTrue(system.contains(tool), "the prompt names \(tool)") }
        XCTAssertTrue(system.contains("not instructions"))
        XCTAssertTrue(capable.requests[0].messages[1].text.contains("(none found by the first search)"))

        // A model that cannot is not told about tools it does not have, and an empty index ends it early.
        let plain = MockModel { _ in "should not be asked" }
        let none = try await MemoryQA(memory: memory, model: plain).ask("Who is my landlord?")
        XCTAssertTrue(none.text.contains("could not find anything"))
        XCTAssertTrue(plain.requests.isEmpty)

        let indexer = Indexer(store: store, embedder: HashingEmbedder())
        try await indexer.indexNote(path: "Home/Apartment.md", body: "# Apartment\nLandlord is Mr. Alvarez.\n")
        let plain2 = MockModel { _ in "Mr. Alvarez\nUSED: 1" }
        _ = try await MemoryQA(memory: memory, model: plain2).ask("Who is my landlord?")
        XCTAssertFalse(plain2.requests[0].lookups)
        XCTAssertFalse(plain2.requests[0].messages[0].text.contains("get_files"))
    }

    // MARK: The real thing (opt-in; spends a few tokens of the user's subscription)

    /// Runs the real `claude` command against the real `offload mcp` built in this checkout, over a notes
    /// folder that no index knows about, so the only way to answer is to call the tools.
    func testLiveClaudeLooksThingsUpThroughOffloadsOwnServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OFFLOAD_LIVE_CLI"] == "1", "set OFFLOAD_LIVE_CLI=1 to call the real claude CLI")
        let status = await ClaudeCLIModel.authStatus()
        try XCTSkipUnless(status.loggedIn, "claude is not logged in")
        let built = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/offload")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: built.path), "run `swift build` first so .build/debug/offload exists")

        let home = dir.appendingPathComponent("home")
        let vault = home.appendingPathComponent("vault/Home")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "# About\n\nA founder.\n".write(to: home.appendingPathComponent("vault/README.md"), atomically: true, encoding: .utf8)
        try "# Apartment\nThe landlord is Mr. Zephyrine Quillon; rent is $3,400.\n".write(to: vault.appendingPathComponent("Apartment.md"), atomically: true, encoding: .utf8)

        let model = try ClaudeCLIModel(memoryServer: ClaudeCLIModel.MemoryServer(executable: built, home: home))
        let out = try await model.complete(CompletionRequest(
            messages: [.system("Answer using your tools to read the user's notes. Reply with just the name."), .user("What is my landlord's surname?")], lookups: true))
        XCTAssertTrue(out.contains("Quillon"), "the answer only exists in a note Claude had to fetch itself: \(out)")
    }

    /// A whole task by the real `claude` command, with every tool call coming back into this process: it must read a
    /// note, ask for approval, and write a new note, all through `ToolHost` and the real `offload mcp --host` bridge.
    func testLiveClaudeCarriesOutATaskThroughTheToolHost() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OFFLOAD_LIVE_CLI"] == "1", "set OFFLOAD_LIVE_CLI=1 to call the real claude CLI")
        let status = await ClaudeCLIModel.authStatus()
        try XCTSkipUnless(status.loggedIn, "claude is not logged in")
        let built = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/offload")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: built.path), "run `swift build` first so .build/debug/offload exists")

        let ws = VaultWorkspace(root: dir.appendingPathComponent("vault"))
        let store = try T.store()
        let staging = try ws.makeStaging()
        let notes = ["README.md": "# About\nA founder.", "Home/Apartment.md": "# Apartment\nThe landlord is Mr. Zephyrine Quillon.\n"]
        try ws.write(notes, paths: Array(notes.keys), into: staging)
        try ws.swap(staging: staging)
        let indexer = Indexer(store: store, embedder: HashingEmbedder())
        let memory = MemoryService(store: store, searcher: HybridSearcher(store: store, embedder: HashingEmbedder()), workspace: ws)   // no index: browsing is the only way
        var options = AgentOptions()
        options.extraTools = [NoteTools.proposeEdit(memory: memory, editor: VaultEditor(workspace: ws, store: store, indexer: indexer))]
        let asked = Box<[String]>([])
        let steps = Box<[String]>([])
        let helper = ClaudeCLIModel.MemoryServer(executable: built, home: dir)
        let agent = Agent(model: try ClaudeCLIModel(taskServer: helper), memory: memory, computer: nil, confirm: { asked.append($0); return true }, options: options)
        let result = await agent.run(task: "Read my notes to find my landlord's surname, then create the note Home/Landlord.md that records it. Reply in one sentence.", maxSteps: 12) { e in
            if case .action(let a) = e { steps.append(a.tool) }
        }
        XCTAssertEqual(result.status, .done, result.summary)
        XCTAssertTrue(steps.value.contains("propose_note_edit"), "\(steps.value)")
        XCTAssertEqual(asked.value.count, 1, "the write asked once, inside this process: \(asked.value)")
        let note = try XCTUnwrap(try memory.note(path: "Home/Landlord.md"), "the note was written by the approved edit")
        XCTAssertTrue(note.contains("Quillon"), note)
    }
}
