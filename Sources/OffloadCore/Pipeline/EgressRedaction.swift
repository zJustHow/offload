import Foundation

/// The one place where text leaves this Mac for a hosted provider.
///
/// Ingestion already redacts chunks and rejects identifier-bearing summaries, but plenty of text
/// reaches a model without ever passing through the index: the raw item handed to triage, notes
/// (written by a model or edited by the user), the text on screen that a reply draft or an agent
/// reads, search queries, and the note text a remote embedder receives. Rather than patch every
/// call site, hosted models and remote embedders are wrapped so that everything they are sent goes
/// through `PIIScan.redact` first. Local models are returned untouched.
///
/// Limits worth knowing: this is the same regex set as ingestion, so it has the same blind spots
/// (names, addresses, free-text medical detail), and images cannot be scanned at all.
public struct RedactingModel: LanguageModel {
    let inner: LanguageModel

    public init(_ inner: LanguageModel) { self.inner = inner }

    // Forwarded unchanged: callers compare model names and read the capabilities.
    public var name: String { inner.name }
    public var capabilities: ModelCapabilities { inner.capabilities }

    public func complete(_ request: CompletionRequest) async throws -> String {
        var redacted = request
        redacted.messages = request.messages.map { message in
            var m = message
            m.text = PIIScan.redact(message.text).text
            return m
        }
        return try await inner.complete(redacted)
    }
}

/// Embedders send every text they embed to wherever they run; a remote one gets the redacted text.
public struct RedactingEmbedder: Embedder {
    let inner: Embedder

    public init(_ inner: Embedder) { self.inner = inner }

    public var name: String { inner.name }

    public func embed(_ texts: [String]) async throws -> [EmbeddedVector?] {
        try await inner.embed(texts.map { PIIScan.redact($0).text })
    }
}

public extension LanguageModel {
    /// `self` when inference stays on this Mac (or is already wrapped), a `RedactingModel` otherwise.
    func redactingIfHosted() -> LanguageModel {
        capabilities.isLocal || self is RedactingModel ? self : RedactingModel(self)
    }
}

public extension URL {
    /// True for a server on this machine, the only kind of endpoint treated as local.
    var isLoopbackHost: Bool { ["localhost", "127.0.0.1", "::1"].contains(host ?? "") }
}
