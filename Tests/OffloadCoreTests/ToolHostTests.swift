import XCTest
@testable import OffloadCore

final class ToolHostTests: XCTestCase {
    func makeHost(_ tools: [Tool], policy: PermissionPolicy = PermissionPolicy(mode: .act), approve: Bool? = nil, exposing: Set<String>? = nil, hooks: [ToolHook] = []) -> ToolHost {
        let registry = ToolRegistry(tools)
        let dispatcher = ToolDispatcher(registry: registry, policy: policy, hooks: hooks, approver: approve.map { answer in { @Sendable _ in answer } })
        return ToolHost(dispatcher: dispatcher, exposing: exposing ?? Set(registry.specs.map(\.name)))
    }

    // MARK: The socket

    func testTheSocketIsPrivateAndGoneWhenStopped() throws {
        let host = makeHost([probeTool("look").0])
        let endpoint = try host.start()
        let folder = URL(fileURLWithPath: endpoint.socketPath).deletingLastPathComponent().path
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int), 0o700, "only this user can enter the folder")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: endpoint.socketPath)[.posixPermissions] as? Int), 0o600)
        XCTAssertGreaterThanOrEqual(endpoint.token.count, 32, "a long random token")
        XCTAssertLessThan(endpoint.socketPath.utf8.count, 100, "short enough for a Unix socket address")
        XCTAssertThrowsError(try host.start(), "a host starts once")
        host.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder), "nothing is left behind")
        XCTAssertThrowsError(try ToolHostClient(socketPath: endpoint.socketPath, token: endpoint.token), "nobody can connect afterwards")
        host.stop()   // harmless twice
    }

    func testFoldersAbandonedByAKilledTaskAreSweptButFreshOnesAreNot() throws {
        let fm = FileManager.default
        let old = "/tmp/offload-hstale\(UUID().uuidString.prefix(6))", fresh = "/tmp/offload-hfresh\(UUID().uuidString.prefix(6))"
        for path in [old, fresh] { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(atPath: old); try? fm.removeItem(atPath: fresh) }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7 * 3600)], ofItemAtPath: old)
        let host = makeHost([probeTool("look").0])
        _ = try host.start(); defer { host.stop() }
        XCTAssertFalse(fm.fileExists(atPath: old), "a folder older than any task can last is removed")
        XCTAssertTrue(fm.fileExists(atPath: fresh), "a recent one may belong to a task that is still running")
    }

    func testAConnectionWithoutTheRightTokenGetsNothing() throws {
        let (tool, probe) = probeTool("look")
        let host = makeHost([tool])
        let endpoint = try host.start(); defer { host.stop() }
        XCTAssertThrowsError(try ToolHostClient(socketPath: endpoint.socketPath, token: "guess")) { XCTAssertTrue("\($0)".contains("refused") || "\($0)".contains("closed"), "\($0)") }
        XCTAssertTrue(probe.calls.isEmpty)
        // And a raw client that skips the greeting is dropped without being answered.
        let raw = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(raw) }
        var address = ToolHost.address(endpoint.socketPath)
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        let line = Array("{\"id\":1,\"op\":\"call\",\"name\":\"look\",\"arguments\":{\"text\":\"x\"}}\n".utf8)
        _ = line.withUnsafeBytes { write(raw, $0.baseAddress!, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(read(raw, &buffer, buffer.count), 0, "closed, with no reply")
        XCTAssertTrue(probe.calls.isEmpty)
    }

    // MARK: Listing and calling

    func testListsOnlyWhatIsExposedAndCallsRunBehindTheDispatcher() async throws {
        let (look, lookProbe) = probeTool("look", result: "found it")
        let (press, pressProbe) = probeTool("press", tier: .act)
        let (hidden, hiddenProbe) = probeTool("finish")
        let host = makeHost([look, press, hidden], exposing: ["look", "press"])
        let endpoint = try host.start(); defer { host.stop() }
        let client = try ToolHostClient(socketPath: endpoint.socketPath, token: endpoint.token)

        let tools = try client.list()
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }.sorted(), ["look", "press"])
        let pressSchema = try XCTUnwrap(tools.first { $0["name"] as? String == "press" }?["inputSchema"] as? [String: Any])
        XCTAssertNotNil((pressSchema["properties"] as? [String: Any])?[ToolSpec.irreversibleFlag], "a tool that acts offers the model the irreversible flag")
        XCTAssertEqual(tools.first { $0["name"] as? String == "look" }?["tier"] as? String, "read-only")

        let ok = try client.call("look", arguments: ["text": "hi", "n": "3"])
        XCTAssertEqual(ok.text, "found it")
        XCTAssertFalse(ok.isError)
        XCTAssertEqual(lookProbe.calls.first?["n"], .int(3), "the dispatcher repaired the argument")

        let missing = try client.call("look", arguments: [:])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("text is required"))

        let notExposed = try client.call("finish", arguments: ["text": "x"])
        XCTAssertTrue(notExposed.isError)
        XCTAssertTrue(hiddenProbe.calls.isEmpty, "a tool in the registry that is not exposed cannot be reached")
        let unknown = try client.call("teleport", arguments: [:])
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(pressProbe.calls.isEmpty)
    }

    func testPermissionApprovalAndHooksApplyToEveryCall() async throws {
        let (press, probe) = probeTool("press", tier: .act, result: "card 4111 1111 1111 1111 on file")
        let denying = makeHost([press], policy: PermissionPolicy(mode: .readOnly))
        let e1 = try denying.start(); defer { denying.stop() }
        let denied = try ToolHostClient(socketPath: e1.socketPath, token: e1.token).call("press", arguments: ["text": "x"])
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.text.hasPrefix("denied:"), denied.text)

        let declining = makeHost([press], policy: PermissionPolicy(mode: .prompt), approve: false)
        let e2 = try declining.start(); defer { declining.stop() }
        let declined = try ToolHostClient(socketPath: e2.socketPath, token: e2.token).call("press", arguments: ["text": "x"])
        XCTAssertTrue(declined.isError)
        XCTAssertTrue(declined.text.contains("declined"))
        XCTAssertTrue(probe.calls.isEmpty, "a refused or declined call never ran")

        let approving = makeHost([press], policy: PermissionPolicy(mode: .prompt), approve: true, hooks: [OutputRedactionHook()])
        let e3 = try approving.start(); defer { approving.stop() }
        let ran = try ToolHostClient(socketPath: e3.socketPath, token: e3.token).call("press", arguments: ["text": "x"])
        XCTAssertFalse(ran.isError)
        XCTAssertTrue(ran.text.contains("[REDACTED:card]"), "the host's hooks scrub what the command reads: \(ran.text)")
        XCTAssertFalse(ran.text.contains("4111"))
        XCTAssertEqual(probe.calls.count, 1)
    }

    func testTheApprovalWaitsForTheUserWithoutBlockingOtherCalls() async throws {
        let (slow, _) = probeTool("slow", tier: .act, approval: .always)
        let (quick, _) = probeTool("quick", result: "fast answer")
        let release = DispatchSemaphore(value: 0)
        let registry = ToolRegistry([slow, quick])
        let dispatcher = ToolDispatcher(registry: registry, policy: PermissionPolicy(mode: .act), approver: { _ in
            await withCheckedContinuation { cont in DispatchQueue.global().async { release.wait(); cont.resume(returning: true) } }
        })
        let host = ToolHost(dispatcher: dispatcher, exposing: ["slow", "quick"])
        let endpoint = try host.start(); defer { host.stop(); release.signal() }
        let first = try ToolHostClient(socketPath: endpoint.socketPath, token: endpoint.token)
        let second = try ToolHostClient(socketPath: endpoint.socketPath, token: endpoint.token)

        let pending = Task.detached { try first.call("slow", arguments: ["text": "x"]) }       // waits for the user
        try await Task.sleep(nanoseconds: 200_000_000)
        let answer = try second.call("quick", arguments: ["text": "x"])                         // another connection still works
        XCTAssertEqual(answer.text, "fast answer")
        release.signal()
        let finished = try await pending.value
        XCTAssertFalse(finished.isError)
    }

    func testLongToolNamesAreShortenedAndStillResolve() throws {
        let long = "mcp__github_enterprise__create_pull_request_review_comment_thread"
        let (tool, probe) = probeTool(long, result: "done")
        let host = makeHost([tool])
        let endpoint = try host.start(); defer { host.stop() }
        let alias = try XCTUnwrap(host.aliases.first)
        XCTAssertLessThanOrEqual(alias.count, ToolHost.maxAliasLength)
        XCTAssertNotEqual(alias, long)
        XCTAssertLessThanOrEqual(("mcp__offload__" + alias).count, 64, "fits the provider's limit with the command's prefix")
        let other = ToolHost.alias(for: long.dropLast() + "x")
        XCTAssertNotEqual(alias, other, "different names stay different")
        let client = try ToolHostClient(socketPath: endpoint.socketPath, token: endpoint.token)
        XCTAssertEqual(try client.list().first?["name"] as? String, alias)
        XCTAssertEqual(try client.call(alias, arguments: ["text": "x"]).text, "done")
        XCTAssertEqual(probe.calls.count, 1)
        XCTAssertEqual(ToolHost.alias(for: "search_memory"), "search_memory", "short names are left alone")
    }

    func testTheGateCanRefuseAndTheCallbacksSeeEveryCall() throws {
        let (look, probe) = probeTool("look")
        let host = makeHost([look])
        let seen = Box<[String]>([])
        host.beforeCall = { seen.append("before:\($0.name)") }
        host.afterCall = { seen.append("after:\($0.outcome)") }
        let open = Box<Bool>(true)
        host.gate = { _ in open.value ? nil : "no more calls" }
        let endpoint = try host.start(); defer { host.stop() }
        let client = try ToolHostClient(socketPath: endpoint.socketPath, token: endpoint.token)
        _ = try client.call("look", arguments: ["text": "x"])
        open.mutate { $0 = false }
        let refused = try client.call("look", arguments: ["text": "x"])
        XCTAssertEqual(refused.text, "no more calls")
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(seen.value, ["before:look", "after:ran"], "a refused call is neither announced nor counted")
        XCTAssertEqual(probe.calls.count, 1)
    }

    // MARK: The MCP bridge

    func testTheBridgeSpeaksMCPAndRelaysEverythingToTheHost() async throws {
        let (look, _) = probeTool("look", result: "relayed")
        let (press, _) = probeTool("press", tier: .act)
        let image = Data([0xFF, 0xD8, 0xFF, 0x01])
        let shot = FunctionTool(ToolSpec(name: "shot", description: "a picture")) { _ in .ok("with picture", image: image) }
        let host = makeHost([look, press, shot])
        let endpoint = try host.start(); defer { host.stop() }
        let bridge = try MCPBridge(socketPath: endpoint.socketPath, token: endpoint.token)

        func call(_ json: String) async throws -> [String: Any] {
            let maybe = await bridge.handle(json)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(maybe).utf8)) as? [String: Any])
        }
        let initialized = try await call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        XCTAssertNotNil(((initialized["result"] as? [String: Any])?["capabilities"] as? [String: Any])?["tools"])
        let note = await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(note)

        let listed = try await call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }.sorted(), ["look", "press", "shot"])
        let annotations = Dictionary(uniqueKeysWithValues: tools.map { ($0["name"] as! String, $0["annotations"] as? [String: Any]) })
        XCTAssertEqual(annotations["look"]??["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(annotations["press"]??["readOnlyHint"] as? Bool, false, "an acting tool is not announced as read-only")

        let text = try await call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"look","arguments":{"text":"hi"}}}"#)
        let content = try XCTUnwrap((text["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "relayed")
        XCTAssertEqual((text["result"] as? [String: Any])?["isError"] as? Bool, false)

        let picture = try await call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"shot","arguments":{}}}"#)
        let blocks = try XCTUnwrap((picture["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text", "image"])
        XCTAssertEqual(blocks[1]["data"] as? String, image.base64EncodedString())
        XCTAssertEqual(blocks[1]["mimeType"] as? String, "image/jpeg")

        let bad = try await call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"look","arguments":{}}}"#)
        XCTAssertEqual((bad["result"] as? [String: Any])?["isError"] as? Bool, true)
        let unknown = try await call(#"{"jsonrpc":"2.0","id":6,"method":"nope"}"#)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)

        host.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let gone = try await call(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"look","arguments":{"text":"x"}}}"#)
        XCTAssertEqual((gone["result"] as? [String: Any])?["isError"] as? Bool, true, "a stopped task is a tool error the model can finish on, not a crash")
        XCTAssertTrue((((gone["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("not reachable") == true)
    }
}
