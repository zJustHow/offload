import Foundation

/// What the session as a whole is allowed to do without asking.
///
/// `readOnly`, `write` and `act` are privilege tiers: the session may use tools up to that tier
/// freely. `prompt` and `allow` are *modes of asking*, not tiers: `prompt` asks about everything
/// (even a lookup), `allow` asks about nothing. They are never ranked against a tier, which is the
/// mistake that makes a permission ladder auto-allow every tool.
public enum PermissionMode: String, Codable, Sendable, CaseIterable {
    case readOnly = "read-only"
    case write
    case act
    case prompt
    case allow

    /// Whether a session in this mode may run a tool needing `tier` without asking.
    public func covers(_ tier: AccessTier) -> Bool {
        switch self {
        case .allow: return true
        case .prompt: return false
        case .readOnly: return AccessTier.readOnly.covers(tier)
        case .write: return AccessTier.write.covers(tier)
        case .act: return AccessTier.act.covers(tier)
        }
    }

    var tier: AccessTier? {
        switch self { case .readOnly: return .readOnly; case .write: return .write; case .act: return .act; default: return nil }
    }
}

/// `name`, `prefix*`, or `name(pattern)` where `pattern` (with `*` wildcards) is matched against
/// every text argument of the call: `open_url(https://example.com/*)`, `mcp__notes__*`.
public struct PermissionRule: Sendable, Equatable, Codable {
    public let raw: String
    let tool: String
    let argumentPattern: String?

    public init(_ raw: String) {
        self.raw = raw.trimmingCharacters(in: .whitespaces)
        if let open = self.raw.firstIndex(of: "("), self.raw.hasSuffix(")") {
            tool = String(self.raw[..<open]).trimmingCharacters(in: .whitespaces)
            argumentPattern = String(self.raw[self.raw.index(after: open)..<self.raw.index(before: self.raw.endIndex)])
        } else { tool = self.raw; argumentPattern = nil }
    }

    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }

    public func matches(_ call: ToolCall) -> Bool {
        guard Self.glob(tool, matches: call.name, caseInsensitive: true) else { return false }
        guard let argumentPattern else { return true }
        return call.arguments.values.contains { value in
            guard let text = value.asString else { return false }
            return Self.glob(argumentPattern, matches: text, caseInsensitive: false)
        }
    }

    /// `*` matches any run of characters; everything else is literal.
    static func glob(_ pattern: String, matches text: String, caseInsensitive: Bool) -> Bool {
        let p = Array(caseInsensitive ? pattern.lowercased() : pattern), t = Array(caseInsensitive ? text.lowercased() : text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if pi < p.count, p[pi] == t[ti] { pi += 1; ti += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

public enum PermissionOverride: Sendable, Equatable { case deny, ask }

public enum PermissionDecision: Sendable, Equatable {
    case allow
    case ask(reason: String)
    case deny(reason: String)
}

/// Decides whether one tool call runs, needs the user's say-so, or is refused.
///
/// Order, first match wins: a denied tool name; a `deny` rule; a hook's deny, then ask; an `ask`
/// rule; then either an `allow` rule or the session mode covering the call's tier lets it run.
/// Anything left either asks (the session is `prompt`, or is one step short of the tier needed) or
/// is refused (a read-only session asked to act).
public struct PermissionPolicy: Sendable, Equatable, Codable {
    public var mode: PermissionMode
    public var allow: [PermissionRule]
    public var deny: [PermissionRule]
    public var ask: [PermissionRule]
    public var deniedTools: [String]

    public init(mode: PermissionMode = .act, allow: [PermissionRule] = [], deny: [PermissionRule] = [], ask: [PermissionRule] = [], deniedTools: [String] = []) {
        self.mode = mode; self.allow = allow; self.deny = deny; self.ask = ask; self.deniedTools = deniedTools
    }

    /// Looks things up, changes nothing, asks nothing.
    public static let readOnly = PermissionPolicy(mode: .readOnly)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(PermissionMode.self, forKey: .mode) ?? .act
        allow = try c.decodeIfPresent([PermissionRule].self, forKey: .allow) ?? []
        deny = try c.decodeIfPresent([PermissionRule].self, forKey: .deny) ?? []
        ask = try c.decodeIfPresent([PermissionRule].self, forKey: .ask) ?? []
        deniedTools = try c.decodeIfPresent([String].self, forKey: .deniedTools) ?? []
    }

    public func decide(
        _ call: ToolCall, spec: ToolSpec, tier: AccessTier,
        hookOverride: PermissionOverride? = nil, hookReason: String? = nil
    ) -> PermissionDecision {
        let name = ToolSpec.canonical(call.name)
        if deniedTools.contains(where: { ToolSpec.canonical($0) == name }) {
            return .deny(reason: "tool '\(call.name)' is disabled in the settings")
        }
        if let rule = deny.first(where: { $0.matches(call) }) {
            return .deny(reason: "'\(call.name)' is blocked by the rule '\(rule.raw)'")
        }
        switch hookOverride {
        case .deny: return .deny(reason: hookReason ?? "'\(call.name)' was blocked by a hook")
        case .ask: return .ask(reason: hookReason ?? "a hook asks for approval of '\(call.name)'")
        case nil: break
        }
        if let rule = ask.first(where: { $0.matches(call) }) { return .ask(reason: "the rule '\(rule.raw)' asks for approval") }
        let granted = allow.first(where: { $0.matches(call) }) != nil
        // A session two tiers short of what the tool needs refuses it outright, whatever the tool's approval policy:
        // a read-only session is not asked to approve something that acts.
        if !granted, let have = mode.tier, tier.rank - have.rank >= 2 {
            return .deny(reason: "'\(call.name)' needs \(tier.rawValue) access, which this session does not have (\(mode.rawValue))")
        }
        if spec.approval == .always && !granted {
            return .ask(reason: spec.origin == .builtin ? "'\(call.name)' needs your approval" : "'\(call.name)' comes from an external server and needs your approval")
        }
        if granted || mode.covers(tier) { return .allow }

        // Not covered. A session one step short of the tier can ask; a stricter one refuses.
        if mode == .prompt { return .ask(reason: "'\(call.name)' needs your approval") }
        if let have = mode.tier, tier.rank - have.rank == 1 {
            return .ask(reason: "'\(call.name)' needs \(tier.rawValue) access; this session has \(have.rawValue)")
        }
        return .deny(reason: "'\(call.name)' needs \(tier.rawValue) access, which this session does not have (\(mode.rawValue))")
    }
}
