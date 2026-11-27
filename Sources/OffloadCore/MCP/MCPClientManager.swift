import Foundation

public struct MCPFailedServer: Sendable, Equatable, Error {
    public var name: String
    public var phase: MCPPhase
    public var message: String
    public var required: Bool
    /// Trying again later could work (a timeout), as opposed to a program that is not installed.
    public var recoverable: Bool
}

/// What connecting to the configured servers achieved. One server failing does not stop the
/// others: the report says which worked and which did not, so the assistant can say so too.
public struct MCPDiscoveryReport: Sendable {
    public var tools: [ToolSpec] = []
    public var working: [String] = []
    public var failed: [MCPFailedServer] = []
    public var warnings: [String] = []
    /// Servers that offer resources (readable documents) as well as tools.
    public var resourceServers: [String] = []

    /// Some servers are up and some are not.
    public var isDegraded: Bool { !working.isEmpty && !failed.isEmpty }
    public var requiredFailures: [MCPFailedServer] { failed.filter(\.required) }

    /// One sentence for the user, or nil when everything worked (or nothing was configured).
    public var summary: String? {
        guard !failed.isEmpty else { return nil }
        let names = failed.map { "\($0.name) (\($0.message))" }.joined(separator: "; ")
        return working.isEmpty ? "No connected app could be reached: \(names)" : "Some connected apps could not be reached: \(names)"
    }
}

public struct MCPServerStatus: Sendable, Equatable {
    public var name: String
    public var connected: Bool
    public var toolCount: Int
}

/// Owns the connections to the user's MCP servers and turns their tools into ordinary `Tool`s.
public actor MCPClientManager {
    typealias TransportFactory = @Sendable (MCPServerConfig) throws -> MCPTransport

    private let configs: [MCPServerConfig]
    private let transportFactory: TransportFactory
    private var connections: [String: MCPConnection] = [:]      // by normalized server name
    private var toolCounts: [String: Int] = [:]
    /// Qualified tool name -> the name the server itself uses.
    var rawNames: [String: String] = [:]
    private var report = MCPDiscoveryReport()
    private var discovered = false

    public init(configs: [MCPServerConfig]) {
        self.init(configs: configs, transportFactory: { try MCPProcessTransport(config: $0) })
    }

    init(configs: [MCPServerConfig], transportFactory: @escaping TransportFactory) {
        self.configs = configs; self.transportFactory = transportFactory
    }

    /// Server names whose tools get their arguments scrubbed (and `*`, the resource tools, always).
    public var redactingServers: Set<String> {
        Set(configs.filter { $0.enabled && $0.redactArguments }.map { MCPNaming.normalize($0.name) }).union(["*"])
    }

    /// Connects to every enabled server at once and collects their tools. Safe to call again: it
    /// reconnects and refreshes.
    public func connectAll(timeout: TimeInterval = 20) async -> MCPDiscoveryReport {
        var result = MCPDiscoveryReport()
        var seenNames = Set<String>(), seenSignatures = Set<String>()
        var usable: [MCPServerConfig] = []
        for c in configs where c.enabled {
            let key = MCPNaming.normalize(c.name)
            if key.isEmpty || c.command.isEmpty { result.warnings.append("A connected app has no name or no command and was skipped."); continue }
            if !seenNames.insert(key).inserted { result.warnings.append("Two connected apps are both called '\(c.name)'; only the first is used."); continue }
            if !seenSignatures.insert(c.signature).inserted { result.warnings.append("'\(c.name)' starts the same program as another entry and was skipped."); continue }
            usable.append(c)
        }

        for connection in connections.values { await connection.close() }
        connections = [:]; toolCounts = [:]; rawNames = [:]

        let outcomes = await withTaskGroup(of: (MCPServerConfig, Result<(MCPConnection, [MCPToolInfo], Bool), MCPFailedServer>).self) { group in
            for c in usable {
                let factory = transportFactory
                group.addTask {
                    let connection = MCPConnection(config: c, makeTransport: { try factory(c) })
                    var phase = MCPPhase.initialize
                    do {
                        try await connection.connect(timeout: timeout)
                        phase = .toolDiscovery
                        let tools = try await connection.listTools(timeout: timeout)
                        return (c, .success((connection, tools, await connection.supportsResources)))
                    } catch {
                        await connection.close()
                        var recoverable = true
                        if case MCPClientError.spawnFailed = error { phase = .spawn; recoverable = false }
                        return (c, .failure(MCPFailedServer(name: c.name, phase: phase, message: "\(error)", required: c.required, recoverable: recoverable)))
                    }
                }
            }
            var all: [(MCPServerConfig, Result<(MCPConnection, [MCPToolInfo], Bool), MCPFailedServer>)] = []
            for await o in group { all.append(o) }
            return all
        }

        var taken = Set<String>()
        for (config, outcome) in outcomes.sorted(by: { $0.0.name < $1.0.name }) {
            switch outcome {
            case .failure(let failure):
                result.failed.append(failure)
            case .success(let (connection, tools, hasResources)):
                connections[MCPNaming.normalize(config.name)] = connection
                result.working.append(config.name)
                if hasResources { result.resourceServers.append(config.name) }
                var exposed = 0
                for info in tools {
                    if let allowed = config.allowedTools, !allowed.contains(info.name) { continue }
                    let qualified = MCPNaming.qualified(server: config.name, tool: info.name)
                    guard taken.insert(qualified).inserted else {
                        result.warnings.append("'\(config.name)' has two tools that both become \(qualified); only the first is used.")
                        continue
                    }
                    result.tools.append(Self.spec(for: info, qualified: qualified, config: config))
                    rawNames[qualified] = info.name
                    exposed += 1
                }
                toolCounts[MCPNaming.normalize(config.name)] = exposed
            }
        }
        report = result
        discovered = true
        return result
    }

    /// The tools of the last `connectAll`, plus resource tools when a server has resources.
    public func tools() -> [Tool] {
        var out: [Tool] = report.tools.map { RemoteMCPTool(spec: $0, manager: self) }
        if !report.resourceServers.isEmpty { out += resourceTools() }
        return out
    }

    public func status() -> [MCPServerStatus] {
        configs.filter(\.enabled).map { c in
            let key = MCPNaming.normalize(c.name)
            return MCPServerStatus(name: c.name, connected: connections[key] != nil, toolCount: toolCounts[key] ?? 0)
        }
    }

    public func shutdown() async {
        for connection in connections.values { await connection.close() }
        connections = [:]
    }

    // MARK: Calls

    func call(server: String, tool: String, arguments: JSONObject) async throws -> ToolOutput {
        guard let connection = connections[MCPNaming.normalize(server)] else { throw MCPClientError.closed("'\(server)' is not connected") }
        let r = try await connection.callTool(tool, arguments: arguments)
        return ToolOutput(r.text, isError: r.isError)
    }

    // MARK: Tool specs

    static func spec(for info: MCPToolInfo, qualified: String, config: MCPServerConfig) -> ToolSpec {
        let readOnly = config.readOnly || info.readOnlyHint
        return ToolSpec(
            name: qualified,
            description: "(\(config.name)) " + sanitize(info.description.isEmpty ? info.name : info.description),
            inputSchema: info.inputSchema,
            tier: readOnly ? .readOnly : .act,
            // A third-party tool whose effects the app cannot judge asks every time, unless the
            // user has allowed it by name (or vouched for the whole server with `readOnly`).
            approval: readOnly ? .byPolicy : .always,
            untrusted: true,
            origin: .mcp(server: MCPNaming.normalize(config.name)),
            promptExample: nil)
    }

    /// A server's description goes into the model's prompt: it is the easiest place to plant
    /// instructions. Keep it short, one line, and without control characters.
    static func sanitize(_ text: String) -> String {
        let cleaned = text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : String($0) }.joined()
        let oneLine = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return oneLine.count > 400 ? String(oneLine.prefix(400)) + "…" : oneLine
    }

    private func resourceTools() -> [Tool] {
        [
            FunctionTool(ToolSpec(
                name: "list_mcp_resources", description: "list documents offered by connected apps (calendars, notes, files)",
                inputSchema: JSONSchema.object(["server": JSONSchema.string("limit to one connected app")]),
                tier: .readOnly, deferred: true, untrusted: true, origin: .mcp(server: "*"), promptExample: #"{"server": "..."}"#
            )) { [self] args in
                let wanted = args.string("server").map(MCPNaming.normalize)
                var lines: [String] = []
                for (key, connection) in await self.connections where wanted == nil || wanted == key {
                    guard await connection.supportsResources else { continue }
                    let resources = try await connection.listResources(timeout: 20)
                    lines += resources.prefix(100).map { "[\(connection.config.name)] \($0.uri) — \(Self.sanitize($0.name))" }
                }
                return .ok(lines.isEmpty ? "(no resources)" : lines.joined(separator: "\n"))
            },
            FunctionTool(ToolSpec(
                name: "read_mcp_resource", description: "read one document offered by a connected app",
                inputSchema: JSONSchema.object(["server": JSONSchema.string(), "uri": JSONSchema.string()], required: ["server", "uri"]),
                tier: .readOnly, deferred: true, untrusted: true, origin: .mcp(server: "*"), promptExample: #"{"server": "...", "uri": "..."}"#
            )) { [self] args in
                guard let server = args.string("server"), let uri = args.string("uri") else { return .error("server and uri are required") }
                guard let connection = await self.connections[MCPNaming.normalize(server)] else { return .error("'\(server)' is not connected") }
                return .ok(try await connection.readResource(uri: uri, timeout: 30))
            },
        ]
    }
}

/// A tool of an MCP server, run through its connection.
struct RemoteMCPTool: Tool {
    let spec: ToolSpec
    let manager: MCPClientManager

    func execute(_ arguments: JSONObject) async throws -> ToolOutput {
        guard case .mcp(let server) = spec.origin else { return .error("not an MCP tool") }
        // The qualified name is not the server's name for the tool; the manager keeps the mapping.
        guard let raw = await manager.rawName(for: spec.name) else { return .error("unknown MCP tool") }
        return try await manager.call(server: server, tool: raw, arguments: arguments)
    }

    func describe(_ arguments: JSONObject) -> String { "\(spec.name)(\(arguments.summary()))" }
}

extension MCPClientManager {
    /// The server's own name for a tool, from its qualified name.
    func rawName(for qualified: String) -> String? { rawNames[qualified] }
}
