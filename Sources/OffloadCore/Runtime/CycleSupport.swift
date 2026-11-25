import Foundation

/// Structured progress for a cycle, so a UI can show real numbers instead of a sentence.
public struct CycleProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case starting, reading, embedding, knowledge, suggestions, finished }
    public var stage: Stage = .starting
    public var message = ""
    /// The source being read, in plain words ("Apple Mail", "Folder “Notes”").
    public var source: String?
    public var done = 0
    public var total = 0
    public var currentTitle: String?
    /// Running totals across every source in this run.
    public var kept = 0
    public var skipped = 0
    public var sensitive = 0

    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Plain-language names for source buckets.
public enum SourceNames {
    public static func friendly(_ bucket: String) -> String {
        switch true {
        case bucket.hasPrefix("files:"): return "Folder “\(URL(fileURLWithPath: String(bucket.dropFirst(6))).lastPathComponent)”"
        case bucket == "imessage": return "Messages"
        case bucket == "whatsapp": return "WhatsApp"
        case bucket.hasPrefix("mail:"): return "Apple Mail"
        case bucket == "calendar:apple": return "Apple Calendar"
        case bucket == "calendar:google": return "Google Calendar"
        case bucket == "applenotes": return "Apple Notes"
        case bucket.hasPrefix("siyuan:"): return "SiYuan"
        case bucket == "gmail": return "Gmail"
        default: return bucket
        }
    }
}

/// One finished run, kept so the app can show what happened and when.
public struct CycleRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var date: Date
    public var seconds: Double
    public var kept: Int
    public var skipped: Int
    public var sensitive: Int
    public var failed: Int
    public var notesCreated: Int
    public var notesChanged: Int
    public var suggestions: Int
    public var warnings: [String]
    public var cancelled: Bool
}

/// A small append-only log (one JSON object per line) of finished runs.
public final class CycleHistory: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let keep = 200

    public init(url: URL) { self.url = url }

    public func append(_ record: CycleRecord) {
        lock.lock(); defer { lock.unlock() }
        var records = readAll()
        records.append(record)
        if records.count > keep { records.removeFirst(records.count - keep) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let lines = records.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Newest first.
    public func recent(limit: Int = 20) -> [CycleRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(readAll().reversed().prefix(limit))
    }

    private func readAll() -> [CycleRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? dec.decode(CycleRecord.self, from: Data($0.utf8)) }
    }
}
