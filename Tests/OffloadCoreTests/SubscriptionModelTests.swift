import XCTest
@testable import OffloadCore

final class SubscriptionModelTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("offload-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func script(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: Claude

    func testClaudeArgumentsEnforceNoToolsNoMCPNoSession() {
        let args = ClaudeCLIModel.arguments(system: "be brief", model: "sonnet")
        XCTAssertEqual(Array(args.prefix(9)), ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", ""])
        XCTAssertEqual(Array(args.suffix(4)), ["--model", "sonnet", "--system-prompt", "be brief"])
        XCTAssertFalse(ClaudeCLIModel.arguments(system: nil, model: nil).contains("--system-prompt"))
    }

    func testSubscriptionRunsDropApiKeysFromTheEnvironment() {
        let env = ClaudeCLIModel.environment(from: ["PATH": "/bin", "ANTHROPIC_API_KEY": "sk-secret", "ANTHROPIC_AUTH_TOKEN": "t", "HOME": "/h"])
        XCTAssertEqual(env, ["PATH": "/bin", "HOME": "/h"], "otherwise the CLI would bill an API key instead of using the subscription")
        XCTAssertNil(CodexCLIModel.environment(from: ["OPENAI_API_KEY": "x", "PATH": "/bin"])["OPENAI_API_KEY"])
    }

    func testClaudeResultParsingAndFailureMessages() throws {
        func result(_ json: String, status: Int32 = 0, err: String = "") -> ProcessResult { ProcessResult(status: status, stdout: Data(json.utf8), stderr: Data(err.utf8), timedOut: false) }
        XCTAssertEqual(try ClaudeCLIModel.parse(result(#"{"type":"result","is_error":false,"result":"PONG"}"#)), "PONG")
        XCTAssertThrowsError(try ClaudeCLIModel.parse(result(#"{"is_error":true,"result":"Claude AI usage limit reached|1700000000"}"#))) { XCTAssertTrue("\($0)".contains("usage limit reached")) }
        XCTAssertThrowsError(try ClaudeCLIModel.parse(result(#"{"is_error":true,"result":"Not logged in · Please run /login"}"#))) { XCTAssertTrue("\($0)".contains("claude auth login")) }
        XCTAssertThrowsError(try ClaudeCLIModel.parse(result("garbage", status: 2, err: "boom"))) { XCTAssertTrue("\($0)".contains("status 2")) }
        XCTAssertThrowsError(try ClaudeCLIModel.parse(ProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: true))) { XCTAssertTrue("\($0)".contains("timed out")) }
        // Text before/after the JSON (warnings, banners) must not break parsing.
        XCTAssertEqual(try ClaudeCLIModel.parse(result("note: update available\n" + #"{"is_error":false,"result":"ok"}"#)), "ok")
    }

    func testClaudeEndToEndAgainstAStandInExecutable() async throws {
        let argLog = dir.appendingPathComponent("args.txt").path
        let fake = try script("claude", """
        printf '%s\\n' "$@" > "\(argLog)"
        echo "cwd-entries=$(ls -A | wc -l | tr -d ' ')" >> "\(argLog)"
        echo "api-key=${ANTHROPIC_API_KEY:-unset}" >> "\(argLog)"
        input=$(cat)
        printf '{"type":"result","is_error":false,"result":"echo: %s"}' "$input"
        """)
        setenv("ANTHROPIC_API_KEY", "should-not-leak", 1); defer { unsetenv("ANTHROPIC_API_KEY") }
        let model = try ClaudeCLIModel(executable: fake, model: "haiku")
        XCTAssertFalse(model.capabilities.isLocal, "a hosted model")
        let out = try await model.complete(CompletionRequest(messages: [.system("SYS"), .user("hello there")]))
        XCTAssertEqual(out, "echo: hello there", "the prompt travels on stdin, not in argv")
        let log = try String(contentsOfFile: argLog, encoding: .utf8)
        XCTAssertTrue(log.contains("--tools\n\n"), "no tools: the empty string is passed through intact")
        XCTAssertTrue(log.contains("--system-prompt\nSYS"))
        XCTAssertTrue(log.contains("cwd-entries=0"), "runs in an empty directory")
        XCTAssertTrue(log.contains("api-key=unset"), "the API key was stripped from the child's environment")
        XCTAssertFalse(log.contains("hello there"), "prompt text never appears on the command line")
    }

    func testSubprocessTimeoutKillsTheChildAndLargeOutputDoesNotDeadlock() async throws {
        let sleeper = try script("sleeper", "sleep 30")
        let start = Date()
        let r = try await Subprocess.run(executable: sleeper, arguments: [], timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)

        let chatty = try script("chatty", "head -c 3000000 /dev/zero | tr '\\0' 'x'; head -c 3000000 /dev/zero | tr '\\0' 'y' 1>&2")
        let big = try await Subprocess.run(executable: chatty, arguments: [], timeout: 30)
        XCTAssertEqual(big.stdout.count, 3_000_000)
        XCTAssertEqual(big.stderr.count, 3_000_000)
        XCTAssertFalse(big.timedOut)
    }

    // MARK: Codex

    func testCodexArgumentsAndEndToEndAgainstAStandInExecutable() async throws {
        let out = URL(fileURLWithPath: "/x/last.txt")
        let args = CodexCLIModel.arguments(model: "gpt-5", outputFile: out, images: [URL(fileURLWithPath: "/x/a.png")])
        XCTAssertEqual(args, ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "-o", "/x/last.txt", "-m", "gpt-5", "-i", "/x/a.png", "-"])

        let argLog = dir.appendingPathComponent("codex-args.txt").path
        let fake = try script("codex", """
        printf '%s\\n' "$@" > "\(argLog)"
        outfile=""
        while [ $# -gt 0 ]; do case "$1" in -o) outfile="$2"; shift;; esac; shift; done
        input=$(cat)
        printf 'codex says: %s' "$input" > "$outfile"
        """)
        let model = try CodexCLIModel(executable: fake)
        XCTAssertTrue(model.capabilities.vision)
        let reply = try await model.complete(CompletionRequest(messages: [.system("S"), .user("what is on screen?", images: [Data([0x89, 0x50, 0x4E, 0x47])])]))
        XCTAssertTrue(reply.hasPrefix("codex says: [Instructions]\nS"))
        XCTAssertTrue(reply.contains("what is on screen?"))
        let log = try String(contentsOfFile: argLog, encoding: .utf8)
        XCTAssertTrue(log.contains("--sandbox\nread-only"))
        XCTAssertTrue(log.contains("image0.png"), "screenshots are handed over as image files")

        let broken = try script("codex-nologin", "echo 'Error: not logged in, please run codex login' >&2; exit 1")
        do { _ = try await CodexCLIModel(executable: broken).complete(CompletionRequest(messages: [.user("x")])); XCTFail("expected failure") }
        catch { XCTAssertTrue("\(error)".contains("codex login")) }
    }

    func testMissingToolsGiveActionableErrors() {
        XCTAssertThrowsError(try ClaudeCLIModel(executable: URL(fileURLWithPath: "/nonexistent/claude"))) { XCTAssertTrue("\($0)".contains("claude auth login")) }
        XCTAssertThrowsError(try CodexCLIModel(executable: URL(fileURLWithPath: "/nonexistent/codex"))) { XCTAssertTrue("\($0)".contains("codex login")) }
        XCTAssertNil(Subprocess.locate("definitely-not-a-real-binary-\(UUID().uuidString)"))
    }

    // MARK: Opt-in live check (spends a few tokens of the user's subscription)

    func testLiveClaudeSubscriptionPing() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OFFLOAD_LIVE_CLI"] == "1", "set OFFLOAD_LIVE_CLI=1 to call the real claude CLI")
        let status = await ClaudeCLIModel.authStatus()
        try XCTSkipUnless(status.loggedIn, "claude is not logged in")
        let out = try await ClaudeCLIModel().complete(CompletionRequest(messages: [.system("You are a test endpoint. Follow the instruction exactly."), .user("Reply with exactly: PONG")]))
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "PONG")
    }
}
