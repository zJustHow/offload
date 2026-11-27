import XCTest
@testable import OffloadCore

/// Calls tools of a real MCP server this code did not write: Claude Code's own (`claude mcp serve`).
/// Skipped unless `OFFLOAD_LIVE_MCP=1` and the `claude` command is installed. It only reads a file in a
/// folder the test creates; nothing else is touched.
final class LiveMCPTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OFFLOAD_LIVE_MCP"] == "1", "set OFFLOAD_LIVE_MCP=1 to run")
        try XCTSkipUnless(Subprocess.locate("claude") != nil, "the claude command is not installed")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("offload-live-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello from a real file\nsecond line, reference LD-55821\n".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    }
    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    func testCallingToolsOfARealIndependentServer() async throws {
        let manager = MCPClientManager(configs: [MCPServerConfig(name: "claude", command: "claude", args: ["mcp", "serve"], timeoutSeconds: 60)])
        let report = await manager.connectAll(timeout: 60)
        XCTAssertEqual(report.working, ["claude"], "\(report.failed)")
        let names = Set(report.tools.map(\.name))
        for expected in ["mcp__claude__Read", "mcp__claude__ToolSearch"] where !names.contains(expected) {
            XCTFail("\(expected) is not offered; the server offers \(names.sorted())")
        }
        XCTAssertGreaterThan(report.tools.count, 6, "enough tools that the agent would hide them behind tool_search")

        let asked = Box<[String]>([])
        let registry = ToolRegistry(await manager.tools())
        let d = ToolDispatcher(registry: registry, policy: PermissionPolicy(mode: .act), hooks: [UntrustedContentHook()],
                               approver: { asked.append($0.spec.name); return true })

        let file = dir.appendingPathComponent("note.txt").path
        let read = await d.dispatch(ToolCall(name: "mcp__claude__Read", arguments: ["file_path": .string(file)]))
        XCTAssertEqual(read.outcome, .ran, read.output.text)
        XCTAssertTrue(read.output.text.contains("hello from a real file"), read.output.text)
        XCTAssertTrue(read.output.text.contains("external source"), "labelled as data")
        XCTAssertEqual(asked.value, ["mcp__claude__Read"], "the server did not say Read is read-only, so it asked (once so far)")

        // Numbers the model sends as text are repaired to the integers the server's schema asks for.
        let second = await d.dispatch(ToolCall(name: "mcp__claude__Read", arguments: ["file_path": .string(file), "offset": "2", "limit": "1"]))
        XCTAssertEqual(second.outcome, .ran, second.output.text)
        XCTAssertTrue(second.output.text.contains("second line"), second.output.text)
        XCTAssertFalse(second.output.text.contains("hello from a real file"), "only the requested line: \(second.output.text)")

        let other = await d.dispatch(ToolCall(name: "mcp__claude__ToolSearch", arguments: ["query": "select:Read", "max_results": 1]))
        XCTAssertEqual(other.outcome, .ran, other.output.text)
        XCTAssertTrue(other.output.text.contains("Read"), other.output.text)

        let missing = await d.dispatch(ToolCall(name: "mcp__claude__Read", arguments: ["file_path": .string(dir.appendingPathComponent("nope.txt").path)]))
        XCTAssertTrue(missing.output.isError, "an error the server reports is an error result: \(missing.output.text)")

        let invalid = await d.dispatch(ToolCall(name: "mcp__claude__Read", arguments: [:]))
        XCTAssertEqual(invalid.outcome, .invalid, "the server's own schema rejects it before a request is sent")

        // A rule that allows the whole server means no question is asked.
        asked.mutate { $0.removeAll() }
        let quiet = ToolDispatcher(registry: registry, policy: PermissionPolicy(mode: .act, allow: [PermissionRule("mcp__claude__*")]), approver: { asked.append($0.spec.name); return true })
        let again = await quiet.dispatch(ToolCall(name: "mcp__claude__Read", arguments: ["file_path": .string(file)]))
        XCTAssertEqual(again.outcome, .ran, again.output.text)
        XCTAssertTrue(asked.value.isEmpty)
        await manager.shutdown()
    }
}
