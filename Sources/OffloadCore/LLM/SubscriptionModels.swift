import Foundation

/// Uses the user's **Claude subscription** through the official `claude` command-line tool
/// (`claude auth login` once; no API key). Each call is a one-shot `claude -p` run:
///   * in a fresh, empty working directory,
///   * with **no tools** (`--tools ""`) and no MCP servers, so text inside an email or a note that
///     tries to give the model instructions has nothing to act with,
///   * with no saved session, and with API-key variables removed from the environment so the
///     subscription — not a metered API key — is what gets used.
/// Everything sent is processed by Anthropic, so this model counts as *hosted* (`isLocal == false`).
///
/// One exception to "no tools", opt-in and only for a request that sets `lookups` (answering a question):
/// with a `MemoryServer` the command is wired to Offload's own read-only MCP server and may call exactly
/// its four memory tools. It still has no built-in tools (no shell, no files, no web), and what the server
/// returns is redacted by the server.
public struct ClaudeCLIModel: LanguageModel {
    public let name: String
    public let capabilities: ModelCapabilities
    let executable: URL
    let model: String?
    let timeout: TimeInterval
    let memoryServer: MemoryServer?
    /// Set when this model may carry out whole tasks through the app's tools (`runTask`).
    let taskServer: MemoryServer?

    /// How to start `offload mcp` for the command to talk to: the `offload` program and which
    /// installation (data folder) it should read.
    public struct MemoryServer: Sendable, Equatable {
        public var executable: URL
        public var home: URL
        public init(executable: URL, home: URL) { self.executable = executable; self.home = home }

        /// The name the server is given in the command's MCP configuration; tool names are prefixed with it.
        static let serverName = "offload"

        /// The only tools the command may call: the server's read-only ones, spelled the way the command names them.
        var allowedTools: [String] { MCPServer.toolNames.map { "mcp__\(Self.serverName)__\($0)" } }

        /// The MCP configuration that makes the command talk to a running `ToolHost` instead (through `offload mcp --host`).
        func bridgeConfiguration(_ endpoint: ToolHost.Endpoint) -> String {
            let server: JSONValue = ["command": .string(executable.path), "args": ["mcp", "--host", .string(endpoint.socketPath)], "env": ["OFFLOAD_HOST_TOKEN": .string(endpoint.token)]]
            return JSONValue.object(["mcpServers": .object([Self.serverName: server])]).jsonText
        }

        /// The MCP configuration, as the JSON text the command's `--mcp-config` takes.
        var configuration: String {
            let server: JSONValue = ["command": .string(executable.path), "args": ["mcp"], "env": ["OFFLOAD_HOME": .string(home.path)]]
            return JSONValue.object(["mcpServers": .object([Self.serverName: server])]).jsonText
        }

        /// Finds the `offload` program: this process when it is the command-line tool, the one that
        /// sits next to the app inside its bundle, or one on the usual search path.
        public static func locate(home: URL) -> MemoryServer? {
            var candidates: [URL] = []
            if let exe = Bundle.main.executableURL {
                if exe.lastPathComponent == "offload" { candidates.append(exe) }
                candidates.append(exe.deletingLastPathComponent().appendingPathComponent("offload"))
            }
            if let found = Subprocess.locate("offload") { candidates.append(found) }
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }.map { MemoryServer(executable: $0, home: home) }
        }
    }

    public init(executable: URL? = nil, model: String? = nil, timeout: TimeInterval = 300, contextChars: Int = 500_000, memoryServer: MemoryServer? = nil, taskServer: MemoryServer? = nil) throws {
        guard let exe = executable ?? Subprocess.locate("claude"), FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw LLMError.unavailable("the `claude` command was not found. Install Claude Code and run `claude auth login`.")
        }
        self.executable = exe; self.model = model; self.timeout = timeout; self.memoryServer = memoryServer; self.taskServer = taskServer
        self.name = "claude-cli" + (model.map { ":\($0)" } ?? "")
        self.capabilities = ModelCapabilities(vision: false, contextChars: contextChars, isLocal: false, canLookUp: memoryServer != nil, runsOwnLoop: taskServer != nil)
    }

    static func arguments(system: String?, model: String?, memoryServer: MemoryServer? = nil) -> [String] {
        var args = ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", ""]
        if let memoryServer { args += ["--mcp-config", memoryServer.configuration, "--allowedTools", memoryServer.allowedTools.joined(separator: ",")] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let system, !system.isEmpty { args += ["--system-prompt", system] }
        return args
    }

    /// The arguments for a whole task: the same containment (no built-in tools, only the servers named here),
    /// with the app's bridge as the one MCP server and exactly the tools it offers allowed.
    /// `configFile` holds the MCP configuration (with the token in it), in a private folder: a command line can be
    /// read by other users with `ps`, a 0600 file in a 0700 folder cannot.
    static func taskArguments(_ task: DelegatedTask, model: String?, configFile: URL) -> [String] {
        var args = ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", ""]
        args += ["--mcp-config", configFile.path, "--allowedTools", task.tools.map { "mcp__\(MemoryServer.serverName)__\($0)" }.joined(separator: ",")]
        if let model, !model.isEmpty { args += ["--model", model] }
        if !task.system.isEmpty { args += ["--system-prompt", task.system] }
        return args
    }

    static func environment(from base: [String: String]) -> [String: String] {
        var env = base
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"] { env.removeValue(forKey: key) }
        return env
    }

    public func complete(_ request: CompletionRequest) async throws -> String {
        let (system, prompt) = Self.flatten(request.messages)
        let scratch = try Subprocess.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = try await Subprocess.run(
            executable: executable, arguments: Self.arguments(system: system, model: model, memoryServer: request.lookups ? memoryServer : nil), stdin: Data(prompt.utf8),
            workingDirectory: scratch, environment: Self.environment(from: ProcessInfo.processInfo.environment), timeout: timeout)
        return try Self.parse(result)
    }

    public func runTask(_ task: DelegatedTask) async throws -> String {
        guard let helper = taskServer else { throw LLMError.unavailable("this Claude model was not set up to carry out tasks (the `offload` program was not found)") }
        let scratch = try Subprocess.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let configFile = scratch.appendingPathComponent("mcp.json")
        try Data(helper.bridgeConfiguration(task.endpoint).utf8).write(to: configFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        let canceller = ProcessCanceller()
        let result = try await withTaskCancellationHandler {
            try await Subprocess.run(
                executable: executable, arguments: Self.taskArguments(task, model: model, configFile: configFile), stdin: Data(task.task.utf8), workingDirectory: scratch,
                environment: Self.environment(from: ProcessInfo.processInfo.environment), timeout: task.timeout, canceller: canceller)
        } onCancel: { canceller.cancel() }
        if Task.isCancelled { throw LLMError.cancelled }
        return try Self.parse(result)
    }

    static func flatten(_ messages: [ChatMessage]) -> (system: String?, prompt: String) {
        let system = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }
        let prompt = turns.count == 1 ? turns[0].text : turns.map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
        return (system.isEmpty ? nil : system, prompt)
    }

    static func parse(_ r: ProcessResult) throws -> String {
        if r.timedOut { throw LLMError.unavailable("claude timed out") }
        // Even failures come back as a JSON result object; prefer its message over raw stderr.
        if let obj = JSONExtract.firstObject(in: r.stdoutText), let text = obj["result"] as? String {
            if (obj["is_error"] as? Bool) == true { throw LLMError.badResponse(describeFailure(text)) }
            return text
        }
        let detail = r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status != 0 { throw LLMError.unavailable("claude exited with status \(r.status)" + (detail.isEmpty ? "" : ": \(detail.prefix(300))")) }
        throw LLMError.badResponse("claude returned no result")
    }

    static func describeFailure(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("usage limit") || lower.contains("rate limit") { return "Claude usage limit reached: \(text)" }
        if lower.contains("not logged in") || lower.contains("login") { return "Claude is not logged in. Run `claude auth login`. (\(text))" }
        return text
    }

    /// Login state without spending a request.
    public static func authStatus(executable: URL? = nil) async -> (loggedIn: Bool, method: String?, detail: String) {
        guard let exe = executable ?? Subprocess.locate("claude") else { return (false, nil, "`claude` is not installed") }
        guard let r = try? await Subprocess.run(executable: exe, arguments: ["auth", "status"], timeout: 20),
            let obj = JSONExtract.firstObject(in: r.stdoutText)
        else { return (false, nil, "could not read `claude auth status`") }
        let ok = obj["loggedIn"] as? Bool ?? false
        return (ok, obj["authMethod"] as? String, ok ? "logged in" : "not logged in; run `claude auth login`")
    }
}

/// Uses the user's **ChatGPT subscription** through the `codex` command-line tool (`codex login`).
///
/// Unlike the Claude path, this could NOT be exercised against the real tool in the environment it
/// was written in (it is not installed there): the flags follow Codex CLI's documented `exec`
/// interface and the argument handling is tested against a stand-in executable. Codex has no switch
/// that removes its shell tool, so a read-only sandbox in an empty directory is the containment;
/// prefer the Claude backend for anything that reads untrusted text, or keep Codex for the
/// assistant role, whose input is the user's own request.
public struct CodexCLIModel: LanguageModel {
    public let name: String
    public let capabilities: ModelCapabilities
    let executable: URL
    let model: String?
    let timeout: TimeInterval

    public init(executable: URL? = nil, model: String? = nil, timeout: TimeInterval = 300, contextChars: Int = 200_000) throws {
        guard let exe = executable ?? Subprocess.locate("codex"), FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw LLMError.unavailable("the `codex` command was not found. Install the Codex CLI and run `codex login`.")
        }
        self.executable = exe; self.model = model; self.timeout = timeout
        self.name = "codex-cli" + (model.map { ":\($0)" } ?? "")
        // Codex accepts images (`-i`), so this backend can see screenshots.
        self.capabilities = ModelCapabilities(vision: true, contextChars: contextChars, isLocal: false)
    }

    static func arguments(model: String?, outputFile: URL, images: [URL]) -> [String] {
        var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "-o", outputFile.path]
        if let model, !model.isEmpty { args += ["-m", model] }
        for i in images { args += ["-i", i.path] }
        args.append("-")   // the prompt is read from stdin
        return args
    }

    static func environment(from base: [String: String]) -> [String: String] {
        var env = base
        env.removeValue(forKey: "OPENAI_API_KEY")   // use the ChatGPT login, not a metered key
        return env
    }

    public func complete(_ request: CompletionRequest) async throws -> String {
        let (system, prompt) = ClaudeCLIModel.flatten(request.messages)
        let full = (system.map { "[Instructions]\n\($0)\n\n[Request]\n" } ?? "") + prompt
        let scratch = try Subprocess.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var imageURLs: [URL] = []
        if capabilities.vision {
            for (i, data) in request.messages.flatMap(\.images).enumerated() {
                let url = scratch.appendingPathComponent("image\(i).\(data.starts(with: [0x89, 0x50]) ? "png" : "jpg")")
                try data.write(to: url); imageURLs.append(url)
            }
        }
        let out = scratch.appendingPathComponent("last-message.txt")
        let r = try await Subprocess.run(
            executable: executable, arguments: Self.arguments(model: model, outputFile: out, images: imageURLs), stdin: Data(full.utf8),
            workingDirectory: scratch, environment: Self.environment(from: ProcessInfo.processInfo.environment), timeout: timeout)
        if r.timedOut { throw LLMError.unavailable("codex timed out") }
        if let text = try? String(contentsOf: out, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let detail = (r.stderrText.isEmpty ? r.stdoutText : r.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status != 0 {
            let lower = detail.lowercased()
            if lower.contains("login") || lower.contains("not authenticated") || lower.contains("sign in") { throw LLMError.unavailable("Codex is not logged in. Run `codex login`.") }
            throw LLMError.unavailable("codex exited with status \(r.status): \(detail.prefix(300))")
        }
        throw LLMError.badResponse("codex produced no final message")
    }

    public static func loginStatus(executable: URL? = nil) async -> (loggedIn: Bool, detail: String) {
        guard let exe = executable ?? Subprocess.locate("codex") else { return (false, "`codex` is not installed") }
        guard let r = try? await Subprocess.run(executable: exe, arguments: ["login", "status"], timeout: 20) else { return (false, "could not run `codex login status`") }
        let text = (r.stdoutText + r.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.status == 0, text.isEmpty ? (r.status == 0 ? "logged in" : "not logged in") : String(text.prefix(120)))
    }
}
