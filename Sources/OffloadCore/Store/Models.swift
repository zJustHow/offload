import Foundation

/// Where an item came from.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case file, image, note, chat, mail, calendar
}

/// How much weight the knowledge builder should give an item as a statement *about the user*.
/// Saved material (screenshots, downloaded PDFs) is mostly about other people; the user's own
/// writing is the strongest evidence of who they are.
public enum Trust: String, Codable, Sendable {
    case authored        // the user wrote it (notes, drafts, documents they authored)
    case correspondence  // mail / chat conversations
    case schedule        // calendar snapshots
    case saved           // material the user kept but did not author
}

public enum Verdict: String, Codable, Sendable {
    case survivor   // worth keeping as knowledge
    case junk       // not worth keeping
    case sensitive  // dropped entirely for privacy
    case failed     // could not be processed (retryable)
}

public struct ItemRecord: Sendable, Equatable {
    public var id: String
    public var bucket: String
    public var kind: SourceKind
    public var uri: String
    public var title: String
    public var itemDate: Date?
    public var fingerprint: String
    public var summary: String?
    public var verdict: Verdict
    public var reason: String?
    public var trust: Trust
    public var createdAt: Date
    public var updatedAt: Date
    public var mergedAt: Date?

    public init(
        id: String, bucket: String, kind: SourceKind, uri: String, title: String, itemDate: Date?,
        fingerprint: String, summary: String?, verdict: Verdict, reason: String? = nil,
        trust: Trust, createdAt: Date = Date(), updatedAt: Date = Date(), mergedAt: Date? = nil
    ) {
        self.id = id; self.bucket = bucket; self.kind = kind; self.uri = uri; self.title = title
        self.itemDate = itemDate; self.fingerprint = fingerprint; self.summary = summary
        self.verdict = verdict; self.reason = reason; self.trust = trust
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.mergedAt = mergedAt
    }
}

/// A piece of raw (already privacy-filtered) text that is indexed for retrieval.
public struct ChunkRecord: Sendable, Equatable {
    public var id: Int64
    public var itemID: String
    public var ord: Int
    public var text: String
    public init(id: Int64 = 0, itemID: String, ord: Int, text: String) {
        self.id = id; self.itemID = itemID; self.ord = ord; self.text = text
    }
}

public struct NoteRecord: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String      // vault-relative, e.g. "Work/Acme/Fundraising.md"
    public var title: String
    public var body: String
    public var hash: String
    public var mtime: Date
    public init(path: String, title: String, body: String, hash: String, mtime: Date) {
        self.path = path; self.title = title; self.body = body; self.hash = hash; self.mtime = mtime
    }
}

/// A vector tagged with the embedding space it lives in. Vectors from different spaces are never
/// compared (a per-language model, for example, has one space per language).
public struct EmbeddedVector: Sendable, Equatable {
    public let space: String
    public let values: [Float]
    public init(space: String, values: [Float]) { self.space = space; self.values = values }
}

extension Array where Element == Float {
    var asData: Data { withUnsafeBufferPointer { Data(buffer: $0) } }
}

extension Data {
    var asFloats: [Float] {
        let n = count / MemoryLayout<Float>.size
        var out = [Float](repeating: 0, count: n)
        _ = out.withUnsafeMutableBytes { copyBytes(to: $0) }
        return out
    }
}
