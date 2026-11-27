import Foundation

/// The one list of what an assistant can do. The text protocol's tool list, the native tool
/// definitions, the MCP server's `tools/list` and execution all come from here, so a tool is
/// declared once.
public final class ToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var byName: [String: Tool] = [:]
    private var order: [String] = []

    public init(_ tools: [Tool] = []) { tools.forEach { register($0) } }

    /// Adds a tool, replacing any tool of the same name (an MCP server reconnecting, say).
    public func register(_ tool: Tool) {
        lock.lock(); defer { lock.unlock() }
        let name = tool.spec.name
        if byName[name] == nil { order.append(name) }
        byName[name] = tool
    }

    public func unregister(where predicate: (ToolSpec) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        for name in order where byName[name].map({ predicate($0.spec) }) == true { byName[name] = nil }
        order.removeAll { byName[$0] == nil }
    }

    public var tools: [Tool] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { byName[$0] }
    }
    public var specs: [ToolSpec] { tools.map(\.spec) }
    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return byName.isEmpty }

    /// Exact name first, then the canonical form (case, underscores and dashes ignored).
    public func tool(named name: String) -> Tool? {
        lock.lock(); defer { lock.unlock() }
        if let t = byName[name] { return t }
        let wanted = ToolSpec.canonical(name)
        guard !wanted.isEmpty else { return nil }
        let matches = order.filter { ToolSpec.canonical($0) == wanted }
        return matches.count == 1 ? byName[matches[0]] : nil
    }

    /// A registry holding only the tools `allowed` names (every tool when nil), minus `denied`.
    /// How an assistant is restricted to a profile such as "look things up, change nothing".
    public func subset(allowing allowed: Set<String>? = nil, denying denied: Set<String> = []) -> ToolRegistry {
        let a = allowed.map { Set($0.map(ToolSpec.canonical)) }
        let d = Set(denied.map(ToolSpec.canonical))
        return ToolRegistry(tools.filter { t in
            let c = ToolSpec.canonical(t.spec.name)
            return (a?.contains(c) ?? true) && !d.contains(c)
        })
    }

    /// Splits the tools into those listed to the model now and those it has to search for.
    /// A tool is hidden when it is marked `deferred`, or when it comes from an MCP server and the
    /// servers together offer more than `autoDeferMCPAbove` tools; a tool the model already found
    /// (`activated`) is listed.
    public func partition(activated: Set<String> = [], autoDeferMCPAbove limit: Int = 6) -> (visible: [ToolSpec], hidden: [ToolSpec]) {
        let all = specs
        let mcpCount = all.filter { if case .mcp = $0.origin { return true } else { return false } }.count
        var visible: [ToolSpec] = [], hidden: [ToolSpec] = []
        for spec in all {
            var isHidden = spec.deferred
            if case .mcp = spec.origin, mcpCount > limit { isHidden = true }
            if isHidden && !activated.contains(spec.name) { hidden.append(spec) } else { visible.append(spec) }
        }
        return (visible, hidden)
    }

    // MARK: Search

    /// Finds tools by words in their name or description. `select:a,b` picks tools by name;
    /// `+word` makes a word mandatory. Results are ranked, best first.
    public static func search(_ query: String, in specs: [ToolSpec], limit: Int = 5) -> [ToolSpec] {
        let lowered = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered.hasPrefix("select:") {
            let names = lowered.dropFirst("select:".count).split(separator: ",").map { ToolSpec.canonical(String($0)) }.filter { !$0.isEmpty }
            return names.compactMap { wanted in specs.first { ToolSpec.canonical($0.name) == wanted } }.prefix(limit).map { $0 }
        }
        var required: [String] = [], optional: [String] = []
        for term in lowered.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if term.hasPrefix("+"), term.count > 1 { required.append(String(term.dropFirst())) } else { optional.append(term) }
        }
        let terms = required.isEmpty ? optional : required + optional

        var scored: [(score: Int, spec: ToolSpec)] = []
        for spec in specs {
            let name = spec.name.lowercased()
            let canonicalName = ToolSpec.canonical(spec.name)
            let description = spec.description.lowercased()
            let haystack = "\(name) \(description) \(canonicalName)"
            let canonicalHaystack = canonicalName + ToolSpec.canonical(spec.description)
            if required.contains(where: { !haystack.contains($0) }) { continue }
            var score = 0
            for term in terms {
                let canonicalTerm = ToolSpec.canonical(term)
                if haystack.contains(term) { score += 2 }
                if name == term { score += 8 }
                if name.contains(term) { score += 4 }
                if canonicalName == canonicalTerm { score += 12 }
                if !canonicalTerm.isEmpty, canonicalHaystack.contains(canonicalTerm) { score += 3 }
            }
            if score == 0 && !lowered.isEmpty { continue }
            scored.append((score, spec))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.spec.name < $1.spec.name }
        return scored.prefix(limit).map(\.spec)
    }
}
