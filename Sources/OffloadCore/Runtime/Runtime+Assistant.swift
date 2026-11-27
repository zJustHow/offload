import Foundation

/// Holds the connection to the user's MCP servers for one `Runtime`.
final class AssistantToolState: @unchecked Sendable {
    private let lock = NSLock()
    private var manager: MCPClientManager?
    private(set) var report: MCPDiscoveryReport?

    func manager(for configs: [MCPServerConfig]) -> MCPClientManager {
        lock.lock(); defer { lock.unlock() }
        if let manager { return manager }
        let m = MCPClientManager(configs: configs)
        manager = m
        return m
    }

    func store(_ report: MCPDiscoveryReport) { lock.lock(); self.report = report; lock.unlock() }
    func take() -> MCPClientManager? { lock.lock(); defer { lock.unlock() }; let m = manager; manager = nil; report = nil; return m }
}

/// What a caller (the notch, the command line) may change about how the assistant is set up for one run.
public struct AssistantOverrides: Sendable {
    public var policy: PermissionPolicy?
    public var planFirst: Bool?
    /// false = ignore the configured MCP servers for this run.
    public var useMCP = true
    public init() {}
}

public extension Runtime {
    /// The tools beyond the built-in ones that the user's settings give the assistant (note editing,
    /// web access, MCP apps), the hooks they need, and a sentence about anything that could not be set up.
    func assistantExtras(useMCP: Bool = true) async -> (tools: [Tool], hooks: [ToolHook], notice: String?) {
        let settings = config.agent
        var tools: [Tool] = []
        var hooks: [ToolHook] = []
        if settings.noteEditing {
            tools.append(NoteTools.proposeEdit(memory: memory, editor: VaultEditor(workspace: workspace, store: store, indexer: indexer)))
        }
        if settings.webTools {
            tools += WebTools.make(policy: WebPolicy(allowedDomains: settings.webAllowedDomains, blockedDomains: settings.webBlockedDomains))
        }

        var notice: String?
        if useMCP, !config.mcpServers.filter(\.enabled).isEmpty {
            let manager = assistantTools.manager(for: config.mcpServers)
            let report: MCPDiscoveryReport
            if let known = assistantTools.report { report = known } else { report = await manager.connectAll(); assistantTools.store(report) }
            tools += await manager.tools()
            let redacting = await manager.redactingServers
            hooks.append(ArgumentRedactionHook(appliesTo: { spec in
                if case .mcp(let server) = spec.origin { return redacting.contains(server) }
                return false
            }))
            for line in report.warnings { AppLog.shared.warning("MCP: \(line)") }
            for failure in report.failed { AppLog.shared.warning("MCP server \(failure.name) is unavailable in phase \(failure.phase.rawValue): \(failure.message)") }
            notice = report.summary
        }
        return (tools, hooks, notice)
    }

    /// The assistant, configured the way the user set it up: their permission rules, the MCP servers
    /// they added, note editing and (if they turned it on) web access. `notice` is a sentence about
    /// anything that could not be set up (an app that did not start), or nil.
    func makeAgent(
        computer: ComputerController?, confirm: @escaping @Sendable (String) async -> Bool,
        ask: @escaping @Sendable (String) async -> String? = { _ in nil }, overrides: AssistantOverrides = AssistantOverrides(),
        approval: (@Sendable (ApprovalRequest) async -> Bool)? = nil, askChoice: (@Sendable (String, [String]) async -> String?)? = nil
    ) async -> (agent: Agent, notice: String?) {
        let settings = config.agent
        var options = AgentOptions()
        options.policy = overrides.policy ?? settings.permissions
        options.planFirst = overrides.planFirst ?? settings.planFirst
        options.observer = ToolAudit.logger()
        options.approval = approval
        options.askChoice = askChoice
        let extras = await assistantExtras(useMCP: overrides.useMCP)
        options.extraTools = extras.tools
        options.hooks = extras.hooks
        return (Agent(model: assistantModel, memory: memory, computer: computer, confirm: confirm, ask: ask, options: options), extras.notice)
    }

    /// Forgets the connections to MCP servers and stops their processes. The next `makeAgent` reconnects.
    func shutdownAssistantTools() async {
        await assistantTools.take()?.shutdown()
    }
}
