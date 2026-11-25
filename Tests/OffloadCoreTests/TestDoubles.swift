import Foundation
@testable import OffloadCore

/// Stand-ins used only by tests; they used to live in the product library.

/// Scripted model for tests and offline demos. The handler sees the full request.
final class MockModel: LanguageModel, @unchecked Sendable {
    let name: String
    let capabilities: ModelCapabilities
    private let handler: @Sendable (CompletionRequest) throws -> String
    private let lock = NSLock()
    private var _requests: [CompletionRequest] = []

    init(
        name: String = "mock", vision: Bool = false, contextChars: Int = 100_000, isLocal: Bool = true,
        handler: @escaping @Sendable (CompletionRequest) throws -> String
    ) {
        self.name = name
        self.capabilities = ModelCapabilities(vision: vision, contextChars: contextChars, isLocal: isLocal)
        self.handler = handler
    }

    var requests: [CompletionRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    private func record(_ request: CompletionRequest) { lock.lock(); _requests.append(request); lock.unlock() }

    func complete(_ request: CompletionRequest) async throws -> String {
        record(request)
        return try handler(request)
    }
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: String] = [:]
    init() {}
    func get(_ account: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func set(_ value: String, account: String) throws { lock.lock(); values[account] = value; lock.unlock() }
    func delete(_ account: String) { lock.lock(); values[account] = nil; lock.unlock() }
}

