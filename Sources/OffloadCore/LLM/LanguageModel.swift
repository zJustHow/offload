import Foundation

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var text: String
    /// Encoded images (JPEG or PNG). Only sent to models whose `capabilities.vision` is true.
    public var images: [Data]

    public init(_ role: Role, _ text: String, images: [Data] = []) {
        self.role = role; self.text = text; self.images = images
    }
    public static func system(_ t: String) -> ChatMessage { .init(.system, t) }
    public static func user(_ t: String, images: [Data] = []) -> ChatMessage { .init(.user, t, images: images) }
    public static func assistant(_ t: String) -> ChatMessage { .init(.assistant, t) }
}

public struct CompletionRequest: Sendable {
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var maxTokens: Int?
    /// Ask the provider for a JSON object where it has a native mode; callers still validate.
    public var jsonMode: Bool

    public init(messages: [ChatMessage], temperature: Double? = nil, maxTokens: Int? = nil, jsonMode: Bool = false) {
        self.messages = messages; self.temperature = temperature; self.maxTokens = maxTokens; self.jsonMode = jsonMode
    }
}

public struct ModelCapabilities: Sendable {
    public var vision: Bool
    /// Conservative budget for one request's prompt, in characters.
    public var contextChars: Int
    /// True when inference stays on this Mac (on-device, or a server on localhost).
    public var isLocal: Bool
    public init(vision: Bool = false, contextChars: Int, isLocal: Bool) {
        self.vision = vision; self.contextChars = contextChars; self.isLocal = isLocal
    }
}

public protocol LanguageModel: Sendable {
    var name: String { get }
    var capabilities: ModelCapabilities { get }
    func complete(_ request: CompletionRequest) async throws -> String
}

public extension LanguageModel {
    func complete(system: String, user: String, jsonMode: Bool = false, temperature: Double? = 0.2) async throws -> String {
        try await complete(CompletionRequest(messages: [.system(system), .user(user)], temperature: temperature, jsonMode: jsonMode))
    }
}
