import Foundation

// A Model Context Protocol *client*: lets the assistant use tools from MCP servers the user has
// added (a calendar, a task manager, a browser). Only stdio servers are supported, speaking the
// protocol's newline-delimited JSON-RPC 2.0. Everything a server returns is untrusted text.

public struct MCPServerConfig: Codable, Equatable, Sendable {
    public var name: String
    public var command: String
    public var args: [String]
    /// Extra environment for the server. A value of the form `keychain:<account>` is read from the
    /// Keychain when the server starts, so a secret never sits in the config file.
    public var env: [String: String]
    public var enabled: Bool
    /// The assistant is not offered MCP tools if a required server failed, and says so.
    public var required: Bool
    /// The user vouches that every tool of this server only reads. Otherwise a tool counts as
    /// read-only only when the server says so (`readOnlyHint`), and any other tool asks first.
    public var readOnly: Bool
    /// Identifiers are scrubbed from the arguments sent to this server (default on).
    public var redactArguments: Bool
    public var timeoutSeconds: Double
    /// When set, only these tools of the server are offered.
    public var allowedTools: [String]?

    public init(
        name: String, command: String, args: [String] = [], env: [String: String] = [:], enabled: Bool = true,
        required: Bool = false, readOnly: Bool = false, redactArguments: Bool = true, timeoutSeconds: Double = 60, allowedTools: [String]? = nil
    ) {
        self.name = name; self.command = command; self.args = args; self.env = env; self.enabled = enabled
        self.required = required; self.readOnly = readOnly; self.redactArguments = redactArguments
        self.timeoutSeconds = timeoutSeconds; self.allowedTools = allowedTools
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name), command: try c.decode(String.self, forKey: .command),
            args: try c.decodeIfPresent([String].self, forKey: .args) ?? [], env: try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true, required: try c.decodeIfPresent(Bool.self, forKey: .required) ?? false,
            readOnly: try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false, redactArguments: try c.decodeIfPresent(Bool.self, forKey: .redactArguments) ?? true,
            timeoutSeconds: try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 60, allowedTools: try c.decodeIfPresent([String].self, forKey: .allowedTools))
    }

    /// Two entries that start the same program with the same arguments are one server.
    var signature: String { ([command] + args).joined(separator: "\u{1}") }
}

/// How MCP names become tool names: `mcp__<server>__<tool>`, so two servers can both have a `search`
/// tool and a tool can never impersonate a built-in one.
public enum MCPNaming {
    public static func normalize(_ name: String) -> String {
        String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
    }

    /// Providers cap tool names (64 characters); a longer name is shortened with a stable hash.
    public static func qualified(server: String, tool: String) -> String {
        let full = "mcp__\(normalize(server))__\(normalize(tool))"
        guard full.count > 64 else { return full }
        let hash = String(Hashing.sha256Hex(full).prefix(8))
        return String(full.prefix(55)) + "_" + hash
    }
}

public enum MCPPhase: String, Sendable { case spawn, initialize, toolDiscovery, resourceDiscovery, ready, invocation, shutdown }

public enum MCPClientError: Error, CustomStringConvertible, Sendable {
    case spawnFailed(String)
    case timeout(method: String, seconds: Double)
    case closed(String)
    case rpc(code: Int, message: String)
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .spawnFailed(let m): return "could not start the server: \(m)"
        case .timeout(let method, let s): return "the server did not answer \(method) within \(Int(s)) seconds"
        case .closed(let m): return "the server closed the connection" + (m.isEmpty ? "" : " (\(m))")
        case .rpc(let code, let message): return "the server reported an error (\(code)): \(message)"
        case .protocolViolation(let m): return "unexpected reply from the server: \(m)"
        }
    }
}

// MARK: - Transport

/// Where a connection's lines go and come from. A real server is a child process; tests use an
/// in-process loopback.
protocol MCPTransport: AnyObject, Sendable {
    /// One JSON message per element.
    var incoming: AsyncStream<String> { get }
    func send(_ line: String) throws
    func close()
    /// The tail of what the server wrote to stderr: the usual explanation of a crash.
    var diagnostics: String { get }
}

/// A server run as a child process. Arguments are an array (no shell), the environment is built
/// from a short allow-list plus what the user configured (so the app's own keys do not leak into a
/// third-party program), and the working directory is an empty scratch folder.
final class MCPProcessTransport: MCPTransport, @unchecked Sendable {
    let incoming: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = Data()
    private var closed = false
    private let scratch: URL?

    init(config: MCPServerConfig, secrets: @Sendable (String) -> String? = { Keychain.get(account: $0) }) throws {
        var cont: AsyncStream<String>.Continuation!
        incoming = AsyncStream { cont = $0 }
        continuation = cont

        guard let executable = Self.resolve(config.command) else { throw MCPClientError.spawnFailed("'\(config.command)' was not found") }
        var env = Self.baseEnvironment()
        for (key, value) in config.env {
            if value.hasPrefix("keychain:") {
                let account = String(value.dropFirst("keychain:".count))
                guard let secret = secrets(account) else { throw MCPClientError.spawnFailed("no Keychain item '\(account)' for \(key)") }
                env[key] = secret
            } else { env[key] = value }
        }
        scratch = try? Subprocess.makeScratchDirectory()

        process.executableURL = executable
        process.arguments = config.args
        process.environment = env
        if let scratch { process.currentDirectoryURL = scratch }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        signal(SIGPIPE, SIG_IGN)   // a server that exited must make a write fail, not kill this app

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; self.finish(); return }
            self.feed(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.appendError(data)
        }
        process.terminationHandler = { [weak self] _ in
            // The stdout handler normally sees end-of-file first; this covers a child that left the pipe open.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self?.finish() }
        }
        do { try process.run() } catch { throw MCPClientError.spawnFailed("\(error.localizedDescription)") }
    }

    private func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { lines.append(text) }
        }
        lock.unlock()
        lines.forEach { continuation.yield($0) }
    }

    private func appendError(_ data: Data) {
        lock.lock(); errorTail.append(data); if errorTail.count > 4_096 { errorTail = errorTail.suffix(4_096) }; lock.unlock()
    }

    private func finish() { continuation.finish() }

    var diagnostics: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errorTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func send(_ line: String) throws {
        guard process.isRunning else { throw MCPClientError.closed(diagnostics) }
        try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func close() {
        lock.lock(); let already = closed; closed = true; lock.unlock()
        guard !already else { return }
        try? stdin.fileHandleForWriting.close()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if p.isRunning { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        continuation.finish()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    static func resolve(_ command: String) -> URL? {
        if command.contains("/") {
            let path = (command as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return Subprocess.locate(command)
    }

    /// Enough to run node, python and friends; deliberately not the app's own environment.
    static func baseEnvironment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        var path = inherited
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin"] where !path.contains(extra) { path.append(extra) }
        return [
            "PATH": path.joined(separator: ":"), "HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(),
            "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory(),
        ]
    }
}

/// A transport that answers in-process, for tests (and for wiring `MCPServer` straight to a client).
final class MCPLoopbackTransport: MCPTransport, @unchecked Sendable {
    let incoming: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let handler: @Sendable (String) async -> String?
    private let lock = NSLock()
    private var isClosed = false
    var diagnostics: String { "" }

    init(handler: @escaping @Sendable (String) async -> String?) {
        var cont: AsyncStream<String>.Continuation!
        incoming = AsyncStream { cont = $0 }
        continuation = cont
        self.handler = handler
    }

    func send(_ line: String) throws {
        lock.lock(); let closed = isClosed; lock.unlock()
        if closed { throw MCPClientError.closed("") }
        Task { if let reply = await handler(line) { continuation.yield(reply) } }
    }

    func close() { lock.lock(); isClosed = true; lock.unlock(); continuation.finish() }
    /// Simulates the server dying.
    func crash() { close() }
}

// MARK: - Connection

struct MCPToolInfo: Sendable {
    var name: String
    var description: String
    var inputSchema: JSONValue
    var readOnlyHint: Bool
}

struct MCPResourceInfo: Sendable {
    var uri: String
    var name: String
    var description: String
}

struct MCPCallResult: Sendable {
    var text: String
    var isError: Bool
}

/// One server: the handshake, request/response matching with timeouts, and a reconnect when the
/// process has died. Server-to-client requests are answered (`ping`) or refused (everything else:
/// this client offers no sampling and no roots).
actor MCPConnection {
    static let clientVersion = "0.2.0"
    static let maxOutputCharacters = 40_000

    let config: MCPServerConfig
    private let makeTransport: @Sendable () throws -> MCPTransport
    private var transport: MCPTransport?
    private var reader: Task<Void, Never>?
    private struct Pending { var continuation: CheckedContinuation<JSONValue, Error>; var timeout: Task<Void, Never> }
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private(set) var capabilities: JSONValue = .null
    private(set) var toolsChanged = false
    /// The handshake finished: requests other than `initialize` may be sent.
    private var ready = false
    /// A connection being made right now, so two calls that arrive together share it.
    private var connecting: Task<Void, Error>?

    init(config: MCPServerConfig, makeTransport: @escaping @Sendable () throws -> MCPTransport) {
        self.config = config; self.makeTransport = makeTransport
    }

    var isConnected: Bool { transport != nil }
    var supportsResources: Bool { capabilities["resources"] != nil }

    /// Connects if there is no working connection, and waits for the one already being made if there is one.
    func ensureConnected(timeout: TimeInterval) async throws {
        if transport != nil, ready { return }
        if let pendingConnection = connecting { return try await pendingConnection.value }
        let task = Task { try await self.connect(timeout: timeout) }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    func connect(timeout: TimeInterval) async throws {
        close()
        let t = try makeTransport()
        transport = t
        reader = Task { [weak self] in
            for await line in t.incoming { await self?.receive(line) }
            await self?.transportClosed(t)
        }
        do {
            let result = try await request("initialize", [
                "protocolVersion": "2025-03-26", "capabilities": [:],
                "clientInfo": ["name": "offload", "version": .string(Self.clientVersion)],
            ], timeout: timeout)
            capabilities = result["capabilities"] ?? .null
            try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            ready = true
        } catch { close(); throw error }
    }

    func close() {
        ready = false
        reader?.cancel(); reader = nil
        let t = transport
        transport = nil
        t?.close()
        failAll(MCPClientError.closed(t?.diagnostics ?? ""))
    }

    func listTools(timeout: TimeInterval) async throws -> [MCPToolInfo] {
        var tools: [MCPToolInfo] = []
        var cursor: String?
        for _ in 0..<20 {
            let page = try await request("tools/list", cursor.map { ["cursor": .string($0)] } ?? [:], timeout: timeout)
            for t in page["tools"]?.asArray ?? [] {
                guard let name = t["name"]?.asString, !name.isEmpty else { continue }
                tools.append(MCPToolInfo(
                    name: name, description: t["description"]?.asString ?? "",
                    inputSchema: t["inputSchema"]?.asObject != nil ? t["inputSchema"]! : JSONSchema.none,
                    readOnlyHint: t["annotations"]?["readOnlyHint"]?.asBool == true))
            }
            cursor = page["nextCursor"]?.asString
            if cursor == nil { break }
        }
        toolsChanged = false
        return tools
    }

    func listResources(timeout: TimeInterval) async throws -> [MCPResourceInfo] {
        try await ensureConnected(timeout: timeout)
        var out: [MCPResourceInfo] = []
        var cursor: String?
        for _ in 0..<10 {
            let page = try await request("resources/list", cursor.map { ["cursor": .string($0)] } ?? [:], timeout: timeout)
            for r in page["resources"]?.asArray ?? [] {
                guard let uri = r["uri"]?.asString else { continue }
                out.append(MCPResourceInfo(uri: uri, name: r["name"]?.asString ?? uri, description: r["description"]?.asString ?? ""))
            }
            cursor = page["nextCursor"]?.asString
            if cursor == nil { break }
        }
        return out
    }

    func readResource(uri: String, timeout: TimeInterval) async throws -> String {
        try await ensureConnected(timeout: timeout)
        let r = try await request("resources/read", ["uri": .string(uri)], timeout: timeout)
        let parts = (r["contents"]?.asArray ?? []).map { c -> String in
            if let text = c["text"]?.asString { return text }
            return "[binary content omitted: \(c["mimeType"]?.asString ?? "unknown type")]"
        }
        return Self.capped(parts.joined(separator: "\n"))
    }

    func callTool(_ name: String, arguments: JSONObject) async throws -> MCPCallResult {
        try await ensureConnected(timeout: min(config.timeoutSeconds, 30))   // the process died: start it again
        let r = try await request("tools/call", ["name": .string(name), "arguments": .object(arguments)], timeout: config.timeoutSeconds)
        var parts: [String] = []
        for block in r["content"]?.asArray ?? [] {
            switch block["type"]?.asString {
            case "text": parts.append(block["text"]?.asString ?? "")
            case "image": parts.append("[image omitted]")
            case "audio": parts.append("[audio omitted]")
            case "resource": parts.append(block["resource"]?["text"]?.asString ?? "[resource: \(block["resource"]?["uri"]?.asString ?? "?")]")
            case "resource_link": parts.append("[link: \(block["uri"]?.asString ?? "?")]")
            default: break
            }
        }
        if parts.isEmpty, let structured = r["structuredContent"], !structured.isNull { parts.append(structured.jsonText) }
        return MCPCallResult(text: Self.capped(parts.joined(separator: "\n")), isError: r["isError"]?.asBool == true)
    }

    static func capped(_ text: String) -> String {
        text.count > maxOutputCharacters ? String(text.prefix(maxOutputCharacters)) + "\n[output cut at \(maxOutputCharacters) characters]" : text
    }

    // MARK: JSON-RPC

    private func send(_ message: JSONValue) throws {
        guard let transport else { throw MCPClientError.closed("") }
        try transport.send(message.jsonText)
    }

    private func request(_ method: String, _ params: JSONObject, timeout: TimeInterval) async throws -> JSONValue {
        guard transport != nil else { throw MCPClientError.closed("") }
        let id = nextID
        nextID += 1
        let message: JSONValue = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": .object(params)]
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
                if !Task.isCancelled { await self?.expire(id, method: method, seconds: timeout) }
            }
            pending[id] = Pending(continuation: continuation, timeout: timer)
            do { try send(message) } catch { resolve(id, .failure(error)) }
        }
    }

    private func resolve(_ id: Int, _ result: Result<JSONValue, Error>) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.timeout.cancel()
        p.continuation.resume(with: result)
    }

    private func expire(_ id: Int, method: String, seconds: Double) {
        resolve(id, .failure(MCPClientError.timeout(method: method, seconds: seconds)))
    }

    private func failAll(_ error: Error) {
        for id in Array(pending.keys) { resolve(id, .failure(error)) }
    }

    private func transportClosed(_ t: MCPTransport) {
        guard transport === t else { return }     // an old transport that was already replaced
        transport = nil
        ready = false
        failAll(MCPClientError.closed(t.diagnostics))
    }

    private func receive(_ line: String) {
        guard let message = JSONValue(jsonText: line), case .object(let o) = message else { return }
        let method = o["method"]?.asString
        if let method {
            if let id = o["id"] {
                // A request from the server. Only ping is meaningful to a client with no capabilities.
                let reply: JSONValue = method == "ping"
                    ? ["jsonrpc": "2.0", "id": id, "result": [:]]
                    : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Method not found: \(method)")]]
                try? send(reply)
            } else if method == "notifications/tools/list_changed" { toolsChanged = true }
            return
        }
        guard let id = o["id"]?.asInt else { return }
        if let error = o["error"] {
            resolve(id, .failure(MCPClientError.rpc(code: error["code"]?.asInt ?? -1, message: error["message"]?.asString ?? "unknown error")))
        } else {
            resolve(id, .success(o["result"] ?? .null))
        }
    }
}
