import Foundation

/// Uses the user's **Claude subscription** through the official `claude` command-line tool
/// (`claude auth login` once; no API key). Each call is a one-shot `claude -p` run:
///   * in a fresh, empty working directory,
///   * with **no tools** (`--tools ""`) and no MCP servers, so text inside an email or a note that
///     tries to give the model instructions has nothing to act with,
///   * with no saved session, and with API-key variables removed from the environment so the
///     subscription — not a metered API key — is what gets used.
/// Everything sent is processed by Anthropic, so this model counts as *hosted* (`isLocal == false`).
public struct ClaudeCLIModel: LanguageModel {
    public let name: String
    public let capabilities: ModelCapabilities
    let executable: URL
    let model: String?
    let timeout: TimeInterval

    public init(executable: URL? = nil, model: String? = nil, timeout: TimeInterval = 300, contextChars: Int = 500_000) throws {
        guard let exe = executable ?? Subprocess.locate("claude"), FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw LLMError.unavailable("the `claude` command was not found. Install Claude Code and run `claude auth login`.")
        }
        self.executable = exe; self.model = model; self.timeout = timeout
        self.name = "claude-cli" + (model.map { ":\($0)" } ?? "")
        self.capabilities = ModelCapabilities(vision: false, contextChars: contextChars, isLocal: false)
    }

    static func arguments(system: String?, model: String?) -> [String] {
        var args = ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", ""]
        if let model, !model.isEmpty { args += ["--model", model] }
        if let system, !system.isEmpty { args += ["--system-prompt", system] }
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
            executable: executable, arguments: Self.arguments(system: system, model: model), stdin: Data(prompt.utf8),
            workingDirectory: scratch, environment: Self.environment(from: ProcessInfo.processInfo.environment), timeout: timeout)
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
