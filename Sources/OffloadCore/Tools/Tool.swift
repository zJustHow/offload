import Foundation

/// How much a tool can change. Ordered, and only ever compared with `covers`.
///
/// This is deliberately *not* mixed with "ask" or "allow everything": those are modes of the
/// session (`PermissionMode`), not amounts of privilege, and ranking them against a tier is how a
/// permission ladder ends up auto-allowing everything.
public enum AccessTier: String, Codable, Sendable, CaseIterable {
    /// Looks things up. Never changes anything and needs no approval.
    case readOnly = "read-only"
    /// Changes the user's own data (a note).
    case write
    /// Operates the Mac or reaches outside it: clicks, typing, opening things, the network.
    case act

    public var rank: Int {
        switch self { case .readOnly: return 0; case .write: return 1; case .act: return 2 }
    }
    public func covers(_ required: AccessTier) -> Bool { rank >= required.rank }
}

public enum ApprovalPolicy: Sendable, Equatable {
    /// Whatever the permission policy decides for the tool's tier.
    case byPolicy
    /// Ask every time, unless an explicit `allow` rule names the tool. For tools whose effects the
    /// app cannot judge: third-party MCP tools, anything that sends data out.
    case always
}

public enum ToolOrigin: Sendable, Equatable {
    case builtin
    case mcp(server: String)
}

public struct ToolSpec: Sendable {
    public var name: String
    public var description: String
    /// JSON Schema (an object) for the arguments.
    public var inputSchema: JSONValue
    public var tier: AccessTier
    public var approval: ApprovalPolicy
    /// Listed to the model only after `tool_search` finds it, so a long tool list does not crowd
    /// out a small model's context.
    public var deferred: Bool
    /// Its output comes from outside (a web page, a third-party server) and is presented as data.
    public var untrusted: Bool
    public var origin: ToolOrigin
    /// How a call looks in the text protocol's tool list, when the schema alone reads badly.
    public var promptExample: String?

    public init(
        name: String, description: String, inputSchema: JSONValue = JSONSchema.none, tier: AccessTier = .readOnly,
        approval: ApprovalPolicy = .byPolicy, deferred: Bool = false, untrusted: Bool = false,
        origin: ToolOrigin = .builtin, promptExample: String? = nil
    ) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.tier = tier
        self.approval = approval; self.deferred = deferred; self.untrusted = untrusted; self.origin = origin
        self.promptExample = promptExample
    }

    /// Lower-case with separators removed, so `Search_Memory`, `search-memory` and `searchmemory`
    /// find the same tool. Models get capitalization and underscores wrong all the time.
    public static func canonical(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var requiredNames: [String] { inputSchema["required"]?.asArray?.compactMap(\.asString) ?? [] }

    /// One line of the text protocol's tool list: `- name {"arg": ...}: description`.
    public var promptLine: String {
        let args = promptExample ?? Self.placeholderObject(for: inputSchema, required: requiredNames)
        return "- \(name) \(args): \(description)"
    }

    private static func placeholderObject(for schema: JSONValue, required: [String]) -> String {
        let properties = schema["properties"]?.asObject ?? [:]
        let names = required + properties.keys.filter { !required.contains($0) }.sorted()
        let parts = names.compactMap { name -> String? in
            guard let p = properties[name] else { return nil }
            let value: String
            switch p["type"]?.asString {
            case "integer", "number": value = "0"
            case "boolean": value = "false"
            case "array": value = "[...]"
            case "object": value = "{...}"
            default:
                if let e = p["enum"]?.asArray?.compactMap(\.asString), !e.isEmpty { value = e.map { "\"\($0)\"" }.joined(separator: " or ") } else { value = "\"...\"" }
            }
            return "\"\(name)\": \(value)"
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    /// The definition handed to a model with native tool calling. Tools that act get one extra
    /// optional flag, so the model can still say "this cannot be undone" the way it does in the
    /// text protocol; the dispatcher strips it before the tool sees the arguments.
    public func nativeDefinition() -> ToolSpec {
        guard tier == .act, case .object(var schema) = inputSchema else { return self }
        var properties = schema["properties"]?.asObject ?? [:]
        properties[Self.irreversibleFlag] = JSONSchema.boolean("true when this cannot be undone: sending, submitting, paying, deleting, posting, signing")
        schema["properties"] = .object(properties)
        var copy = self
        copy.inputSchema = .object(schema)
        return copy
    }

    public static let irreversibleFlag = "irreversible"
}

/// One request from a model to run a tool.
public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: JSONObject
    /// The model's stated reason, shown in confirmations.
    public var thought: String
    /// The model said this cannot be undone. Only ever adds a confirmation.
    public var declaredIrreversible: Bool

    public init(id: String = UUID().uuidString, name: String, arguments: JSONObject = [:], thought: String = "", declaredIrreversible: Bool = false) {
        self.id = id; self.name = name; self.arguments = arguments; self.thought = thought; self.declaredIrreversible = declaredIrreversible
    }
}

public struct ToolOutput: Sendable, Equatable {
    public var text: String
    public var image: Data?
    public var isError: Bool

    public init(_ text: String, image: Data? = nil, isError: Bool = false) {
        self.text = text; self.image = image; self.isError = isError
    }
    public static func ok(_ text: String, image: Data? = nil) -> ToolOutput { ToolOutput(text, image: image) }
    public static func error(_ text: String) -> ToolOutput { ToolOutput(text, isError: true) }
}

public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    /// What *this call* needs. Usually the tool's own tier; a tool whose risk depends on its
    /// arguments (a shell command, a URL) can say more. The ceiling is whatever it returns.
    func tier(for arguments: JSONObject) -> AccessTier
    /// Wording for a confirmation or a log line.
    func describe(_ arguments: JSONObject) -> String
    /// A reason this call cannot work, found before the user is asked about it. A tool that can
    /// check its own arguments (is this edit allowed? is this address reachable?) says so here, so
    /// nobody is asked to approve something that was going to fail.
    func preflight(_ arguments: JSONObject) async -> String?
    func execute(_ arguments: JSONObject) async throws -> ToolOutput
}

public extension Tool {
    func tier(for arguments: JSONObject) -> AccessTier { spec.tier }
    func describe(_ arguments: JSONObject) -> String { "\(spec.name)(\(arguments.summary()))" }
    func preflight(_ arguments: JSONObject) async -> String? { nil }
}

/// A tool defined by a closure; most of them are.
public struct FunctionTool: Tool {
    public let spec: ToolSpec
    private let handler: @Sendable (JSONObject) async throws -> ToolOutput
    private let tierResolver: (@Sendable (JSONObject) -> AccessTier)?
    private let describer: (@Sendable (JSONObject) -> String)?
    private let preflighter: (@Sendable (JSONObject) async -> String?)?

    public init(
        _ spec: ToolSpec,
        tier: (@Sendable (JSONObject) -> AccessTier)? = nil,
        describe: (@Sendable (JSONObject) -> String)? = nil,
        preflight: (@Sendable (JSONObject) async -> String?)? = nil,
        handler: @escaping @Sendable (JSONObject) async throws -> ToolOutput
    ) {
        self.spec = spec; self.handler = handler; self.tierResolver = tier; self.describer = describe; self.preflighter = preflight
    }

    public func preflight(_ arguments: JSONObject) async -> String? { await preflighter?(arguments) }

    public func tier(for arguments: JSONObject) -> AccessTier { tierResolver?(arguments) ?? spec.tier }
    public func describe(_ arguments: JSONObject) -> String { describer?(arguments) ?? "\(spec.name)(\(arguments.summary()))" }
    public func execute(_ arguments: JSONObject) async throws -> ToolOutput { try await handler(arguments) }
}
