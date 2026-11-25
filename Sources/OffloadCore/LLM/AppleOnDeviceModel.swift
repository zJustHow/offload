import Foundation
import FoundationModels

/// The system's built-in on-device language model (Apple Foundation Models). Nothing is
/// downloaded by this app and nothing leaves the Mac. The context window is small (about 4k
/// tokens), so callers must keep prompts short — `capabilities.contextChars` is deliberately
/// conservative — and the model is text-only.
public struct AppleOnDeviceModel: LanguageModel {
    public let name = "apple.on-device"
    public let capabilities = ModelCapabilities(vision: false, contextChars: 7_000, isLocal: true)

    public init() {}

    public static var availability: (available: Bool, reason: String) {
        switch SystemLanguageModel.default.availability {
        case .available: return (true, "available")
        case .unavailable(let reason): return (false, "\(reason)")
        }
    }

    public func complete(_ request: CompletionRequest) async throws -> String {
        let state = Self.availability
        guard state.available else { throw LLMError.unavailable("Apple on-device model: \(state.reason)") }

        // The session takes instructions separately; the rest of the conversation is flattened
        // into one prompt (each request here is self-contained anyway).
        let instructions = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        let turns = request.messages.filter { $0.role != .system }
        let prompt: String
        if turns.count == 1, let only = turns.first { prompt = only.text }
        else {
            prompt = turns.map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
        }

        let session = LanguageModelSession(instructions: instructions.isEmpty ? "You are a helpful assistant." : instructions)
        var options = GenerationOptions()
        if let t = request.temperature { options.temperature = t }
        if let m = request.maxTokens { options.maximumResponseTokens = m }
        do {
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw LLMError.badResponse("Apple on-device model: \(error)")
        }
    }
}
