import Foundation

public struct ApprovalRequest: Sendable {
    public var call: ToolCall
    public var spec: ToolSpec
    /// What would happen, in one line, as it is shown to the user.
    public var description: String
    /// Why the user is being asked.
    public var reason: String
}

public struct ToolResult: Sendable {
    public enum Outcome: Sendable, Equatable {
        case ran
        case failed
        /// The user said no.
        case declined
        /// Policy refused it; the tool never ran.
        case denied(String)
        /// The arguments did not fit the tool's schema.
        case invalid
        case unknown
    }
    public var call: ToolCall
    public var output: ToolOutput
    public var outcome: Outcome
    /// Whether the user was asked about it.
    public var asked: Bool
}

/// The path every tool call takes, whoever made it (the agent loop or an MCP client):
///
///     look up → repair and check arguments → pre-hooks → permission → approval → run → post-hooks
///
/// Nothing runs without passing the permission step, and a refusal is an ordinary tool result, so a
/// model sees "denied" and can choose another way.
public final class ToolDispatcher: @unchecked Sendable {
    public typealias Approver = @Sendable (ApprovalRequest) async -> Bool
    /// An extra reason to ask that the call's own tier does not capture. Only ever *adds* a question.
    public typealias Backstop = @Sendable (ToolCall, ToolSpec) -> String?

    public let registry: ToolRegistry
    private let lock = NSLock()
    private var _policy: PermissionPolicy
    private var _readOnlyOnly = false
    private let hooks: [ToolHook]
    private let approver: Approver?
    private let backstop: Backstop?
    private let observer: (@Sendable (ToolEvent) -> Void)?

    public init(
        registry: ToolRegistry, policy: PermissionPolicy, hooks: [ToolHook] = [], approver: Approver? = nil,
        backstop: Backstop? = nil, observer: (@Sendable (ToolEvent) -> Void)? = nil
    ) {
        self.registry = registry; self._policy = policy; self.hooks = hooks
        self.approver = approver; self.backstop = backstop; self.observer = observer
    }

    public var policy: PermissionPolicy {
        get { lock.lock(); defer { lock.unlock() }; return _policy }
        set { lock.lock(); _policy = newValue; lock.unlock() }
    }

    /// While true, only read-only tools run: the assistant is planning and has not been cleared to act.
    public var readOnlyOnly: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _readOnlyOnly }
        set { lock.lock(); _readOnlyOnly = newValue; lock.unlock() }
    }

    public func dispatch(_ requested: ToolCall) async -> ToolResult {
        let started = Date()
        var asked = false
        func finish(_ call: ToolCall, _ tier: AccessTier, _ output: ToolOutput, _ outcome: ToolResult.Outcome) -> ToolResult {
            let event: ToolEvent.Result
            switch outcome {
            case .ran: event = .ran
            case .failed: event = .failed
            case .declined: event = .declined
            case .denied: event = .denied
            case .invalid: event = .invalid
            case .unknown: event = .unknown
            }
            observer?(ToolEvent(tool: call.name, tier: tier, result: event, asked: asked, outputCharacters: output.text.count, seconds: Date().timeIntervalSince(started)))
            return ToolResult(call: call, output: output, outcome: outcome, asked: asked)
        }

        guard let tool = registry.tool(named: requested.name) else {
            return finish(requested, .readOnly, .error("unknown tool \"\(requested.name)\""), .unknown)
        }
        let spec = tool.spec
        var call = requested
        call.name = spec.name

        // The "irreversible" flag is part of the protocol with the model, not of the tool.
        if let flag = call.arguments.removeValue(forKey: ToolSpec.irreversibleFlag) { call.declaredIrreversible = call.declaredIrreversible || flag.asBool == true }

        call.arguments = SchemaCheck.coerce(call.arguments, to: spec.inputSchema)
        let problems = SchemaCheck.validate(call.arguments, against: spec.inputSchema)
        if !problems.isEmpty {
            return finish(call, spec.tier, .error("invalid arguments: " + problems.joined(separator: "; ")), .invalid)
        }

        // Pre-hooks: combine. Deny beats ask; argument rewrites chain; messages accumulate.
        var hookOverride: PermissionOverride?
        var hookReason: String?
        var hookMessages: [String] = []
        for hook in hooks {
            let r = await hook.preToolUse(call, spec: spec)
            if let updated = r.updatedArguments { call.arguments = SchemaCheck.coerce(updated, to: spec.inputSchema) }
            hookMessages += r.messages
            if let o = r.override, hookOverride != .deny { hookOverride = o; hookReason = r.reason ?? hookReason }
        }

        if let problem = await tool.preflight(call.arguments) {
            return finish(call, spec.tier, .error(problem), .invalid)
        }

        let tier = tool.tier(for: call.arguments)
        var decision: PermissionDecision
        if readOnlyOnly && tier != .readOnly {
            decision = .deny(reason: "planning only: '\(spec.name)' can change things, so it waits until the plan is approved")
        } else {
            decision = policy.decide(call, spec: spec, tier: tier, hookOverride: hookOverride, hookReason: hookReason)
            if decision == .allow, let reason = backstop?(call, spec) { decision = .ask(reason: reason) }
        }

        switch decision {
        case .deny(let reason):
            return finish(call, tier, .error("denied: \(reason)"), .denied(reason))
        case .ask(let reason):
            asked = true
            var description = tool.describe(call.arguments)
            if !call.thought.isEmpty { description += " — \(call.thought.prefix(200))" }
            let approved = await approver?(ApprovalRequest(call: call, spec: spec, description: description, reason: reason)) ?? false
            if !approved { return finish(call, tier, .error("the user declined this action"), .declined) }
        case .allow: break
        }

        var output: ToolOutput
        do { output = try await tool.execute(call.arguments) }
        catch { output = .error("error: \(error)") }
        if !hookMessages.isEmpty { output.text += "\n" + hookMessages.joined(separator: "\n") }

        for hook in hooks {
            output = output.isError ? await hook.postToolUseFailure(call, spec: spec, output: output) : await hook.postToolUse(call, spec: spec, output: output)
        }
        return finish(call, tier, output, output.isError ? .failed : .ran)
    }
}
