import Foundation

/// A tool call the model made through a provider's native tool calling.
public struct ModelToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: JSONObject
    public init(id: String, name: String, arguments: JSONObject) { self.id = id; self.name = name; self.arguments = arguments }
}

/// The answer to one `ModelToolCall`, sent back in the next user turn.
public struct ToolResultBlock: Sendable, Equatable {
    public var toolCallID: String
    public var name: String
    public var text: String
    public var images: [Data]
    public var isError: Bool
    public init(toolCallID: String, name: String, text: String, images: [Data] = [], isError: Bool = false) {
        self.toolCallID = toolCallID; self.name = name; self.text = text; self.images = images; self.isError = isError
    }
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var text: String
    /// Encoded images (JPEG or PNG). Only sent to models whose `capabilities.vision` is true.
    public var images: [Data]
    /// Native tool calling only: the calls an assistant message made...
    public var toolCalls: [ModelToolCall]
    /// ...and, in the user message that follows, their results.
    public var toolResults: [ToolResultBlock]
    /// The provider's own content blocks for an assistant message, to be sent back exactly as they
    /// arrived. Anthropic models that think return signed `thinking` blocks that must be replayed
    /// unchanged; editing anything before them (or dropping one from the middle) is an error. Empty
    /// for every other provider, and cleared whenever the history is rewritten.
    public var providerBlocks: [JSONValue]

    public init(_ role: Role, _ text: String, images: [Data] = [], toolCalls: [ModelToolCall] = [], toolResults: [ToolResultBlock] = [], providerBlocks: [JSONValue] = []) {
        self.role = role; self.text = text; self.images = images; self.toolCalls = toolCalls; self.toolResults = toolResults; self.providerBlocks = providerBlocks
    }
    public static func system(_ t: String) -> ChatMessage { .init(.system, t) }
    public static func user(_ t: String, images: [Data] = []) -> ChatMessage { .init(.user, t, images: images) }
    public static func assistant(_ t: String, toolCalls: [ModelToolCall] = [], providerBlocks: [JSONValue] = []) -> ChatMessage {
        .init(.assistant, t, toolCalls: toolCalls, providerBlocks: providerBlocks)
    }
    public static func toolResults(_ results: [ToolResultBlock]) -> ChatMessage { .init(.user, "", toolResults: results) }
}

public struct CompletionRequest: Sendable {
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var maxTokens: Int?
    /// Ask the provider for a JSON object where it has a native mode; callers still validate.
    public var jsonMode: Bool
    /// The model may look things up in the user's knowledge base itself while it answers, when the
    /// backend can do that (`capabilities.canLookUp`); every other backend ignores this. Only the
    /// question-answering path sets it: reading untrusted items and writing notes never do.
    public var lookups: Bool

    public init(messages: [ChatMessage], temperature: Double? = nil, maxTokens: Int? = nil, jsonMode: Bool = false, lookups: Bool = false) {
        self.messages = messages; self.temperature = temperature; self.maxTokens = maxTokens; self.jsonMode = jsonMode; self.lookups = lookups
    }
}

public struct ModelCapabilities: Sendable {
    public var vision: Bool
    /// Conservative budget for one request's prompt, in characters.
    public var contextChars: Int
    /// True when inference stays on this Mac (on-device, or a server on localhost).
    public var isLocal: Bool
    /// The provider takes tool definitions and returns structured tool calls (`completeWithTools`).
    /// Off for models that only produce text: the agent then uses its JSON text protocol.
    public var nativeTools: Bool
    /// The backend can search and read the knowledge base on its own during a request
    /// (a subscription command-line tool wired to Offload's read-only MCP server).
    public var canLookUp: Bool
    /// The backend can carry out a whole task itself, calling the assistant's tools back in this process
    /// through a `ToolHost` (`runTask`), instead of being asked for one action per turn.
    public var runsOwnLoop: Bool
    public init(vision: Bool = false, contextChars: Int, isLocal: Bool, nativeTools: Bool = false, canLookUp: Bool = false, runsOwnLoop: Bool = false) {
        self.vision = vision; self.contextChars = contextChars; self.isLocal = isLocal; self.nativeTools = nativeTools; self.canLookUp = canLookUp; self.runsOwnLoop = runsOwnLoop
    }
}

/// Tokens a request used, as the provider reports them. Cache fields make prompt caching measurable:
/// if `cacheReadInputTokens` stays zero across the steps of one run, something in the prefix changes.
public struct ModelUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int = 0, cacheReadInputTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens; self.cacheReadInputTokens = cacheReadInputTokens
    }
}

/// A whole task handed to a backend that runs its own loop (`ModelCapabilities.runsOwnLoop`).
public struct DelegatedTask: Sendable {
    public var system: String
    public var task: String
    /// Where the backend reaches this process's tools, and which ones it may call (names as the bridge lists them).
    public var endpoint: ToolHost.Endpoint
    public var tools: [String]
    public var timeout: TimeInterval
    public init(system: String, task: String, endpoint: ToolHost.Endpoint, tools: [String], timeout: TimeInterval = 900) {
        self.system = system; self.task = task; self.endpoint = endpoint; self.tools = tools; self.timeout = timeout
    }
}

/// What a model said when it was offered tools: some text, and zero or more tool calls.
public struct ModelReply: Sendable, Equatable {
    public var text: String
    public var toolCalls: [ModelToolCall]
    /// Why the model stopped, in one vocabulary for every provider: `end_turn`, `tool_use`,
    /// `max_tokens` (cut off: any tool call may be incomplete), `refusal`. Nil when not reported.
    public var stopReason: String?
    public var usage: ModelUsage?
    /// See `ChatMessage.providerBlocks`.
    public var providerBlocks: [JSONValue]
    public init(text: String, toolCalls: [ModelToolCall] = [], stopReason: String? = nil, usage: ModelUsage? = nil, providerBlocks: [JSONValue] = []) {
        self.text = text; self.toolCalls = toolCalls; self.stopReason = stopReason; self.usage = usage; self.providerBlocks = providerBlocks
    }
}

public protocol LanguageModel: Sendable {
    var name: String { get }
    var capabilities: ModelCapabilities { get }
    func complete(_ request: CompletionRequest) async throws -> String
    /// One turn of a tool-using conversation through the provider's native tool calling. Only
    /// called when `capabilities.nativeTools` is true.
    func completeWithTools(_ request: CompletionRequest, tools: [ToolSpec]) async throws -> ModelReply
    /// Carries out a whole task, calling tools back through `task.endpoint`, and returns its final message.
    /// Only called when `capabilities.runsOwnLoop` is true.
    func runTask(_ task: DelegatedTask) async throws -> String
}

public extension LanguageModel {
    func completeWithTools(_ request: CompletionRequest, tools: [ToolSpec]) async throws -> ModelReply {
        throw LLMError.unavailable("\(name) does not support native tool calling")
    }

    func runTask(_ task: DelegatedTask) async throws -> String {
        throw LLMError.unavailable("\(name) cannot carry out a task by itself")
    }

    func complete(system: String, user: String, jsonMode: Bool = false, temperature: Double? = 0.2) async throws -> String {
        try await complete(CompletionRequest(messages: [.system(system), .user(user)], temperature: temperature, jsonMode: jsonMode))
    }
}
