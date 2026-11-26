import Foundation

/// One message, source-independent.
public struct ChatLine: Sendable, Equatable {
    public var rowID: Int64
    public var date: Date
    public var sender: String   // "Me" for the user
    public var text: String
    public init(rowID: Int64, date: Date, sender: String, text: String) {
        self.rowID = rowID; self.date = date; self.sender = sender; self.text = text
    }
}

public struct ChatSummary: Sendable, Equatable {
    public var id: String       // opaque id used for selection
    public var name: String
    public var isGroup: Bool
    public var messageCount: Int
}

/// Splits a chat into conversation windows: a new window starts after a long silence or when the
/// current one is full. Windows are the unit of analysis, so each fits the small on-device model.
public enum ChatWindowing {
    public static func windows(_ lines: [ChatLine], maxChars: Int = 4_000, gap: TimeInterval = 8 * 3_600, maxMessageChars: Int = 600) -> [[ChatLine]] {
        var windows: [[ChatLine]] = []
        var current: [ChatLine] = []
        var size = 0
        for var line in lines.sorted(by: { $0.rowID < $1.rowID }) {
            if line.text.count > maxMessageChars { line.text = String(line.text.prefix(maxMessageChars)) + "…" }
            let cost = line.text.count + line.sender.count + 3
            if let last = current.last, line.date.timeIntervalSince(last.date) > gap || size + cost > maxChars {
                windows.append(current); current = []; size = 0
            }
            current.append(line)
            size += cost
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }

    public static func render(_ window: [ChatLine]) -> [String] { window.map { "\($0.sender): \($0.text)" } }
}

/// Reading a database that another app has open: copy it (with its write-ahead log) and read the
/// copy, so the source app is never blocked and nothing is ever written to the original.
enum DatabaseSnapshot {
    private static let counter = NSLock()
    nonisolated(unsafe) private static var opened = 0
    /// How many copies have been made in this process (a database can be gigabytes; tests assert
    /// that a run copies each source once, not once per item).
    static var openCount: Int { counter.lock(); defer { counter.unlock() }; return opened }

    /// What a failed copy means for the person using the app.
    enum CopyFailure: Equatable {
        /// The file is not there (the app that owns it is not installed, or never ran).
        case missing
        /// The system refused: for these databases that is almost always Full Disk Access.
        case denied
        /// Anything else (disk full, I/O error): not something a permission switch fixes.
        case other
    }

    /// Tells the cases apart by the error itself, not by looking at the path first: a file inside a
    /// protected folder can look absent to a process that is not allowed to see it, and that must
    /// still be reported as a permission problem. A refused read surfaces as Cocoa 513 over POSIX
    /// EPERM, an absent file as Cocoa 260 over POSIX ENOENT (checked on macOS 27).
    static func classify(_ error: Error) -> CopyFailure {
        var chain: [NSError] = []
        var next: NSError? = error as NSError
        while let e = next, chain.count < 4 { chain.append(e); next = e.userInfo[NSUnderlyingErrorKey] as? NSError }
        for e in chain where e.domain == NSPOSIXErrorDomain {
            if e.code == Int(ENOENT) { return .missing }
            if e.code == Int(EPERM) || e.code == Int(EACCES) { return .denied }
        }
        for e in chain where e.domain == NSCocoaErrorDomain {
            switch e.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .missing
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .denied
            default: continue
            }
        }
        return .other
    }

    static func open(_ url: URL) throws -> (db: Database, cleanup: () -> Void) {
        counter.lock(); opened += 1; counter.unlock()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("offload-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: copy) } catch {
            try? FileManager.default.removeItem(at: dir)
            switch classify(error) {
            case .missing:
                throw ConnectorError.unreadable("\(url.lastPathComponent) not found at \(url.path); is the app installed and has it been opened on this Mac?")
            case .denied:
                throw ConnectorError.permissionDenied("cannot read \(url.lastPathComponent) (Full Disk Access needed?): \(error.localizedDescription)")
            case .other:
                throw ConnectorError.unreadable("cannot read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: side.path) { try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        let db = try Database(path: copy.path)
        return (db, { try? FileManager.default.removeItem(at: dir) })
    }
}

/// One copy of a source database, shared by `list()` and the `load()` calls that follow it.
/// `list()` takes a fresh copy (so changes since the last run are seen); `load()` reuses it, which
/// both avoids copying a possibly huge file once per item and guarantees an item's content matches
/// the fingerprint it was listed with. The copy is deleted when the connector goes away.
final class SnapshotBox: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var current: (db: Database, cleanup: () -> Void)?

    init(url: URL) { self.url = url }
    deinit { current?.cleanup() }

    /// Drops the old copy and takes a new one.
    func refresh() throws -> Database {
        lock.lock(); defer { lock.unlock() }
        current?.cleanup(); current = nil
        current = try DatabaseSnapshot.open(url)
        return current!.db
    }

    /// The current copy, taking one if there is none yet.
    func database() throws -> Database {
        lock.lock(); defer { lock.unlock() }
        if let c = current { return c.db }
        current = try DatabaseSnapshot.open(url)
        return current!.db
    }
}

/// Conversation windows per chat, computed once per `list()` and reused by `load()`.
final class ChatCache: @unchecked Sendable {
    typealias Chat = (info: ConversationInfo, windows: [[ChatLine]])
    let snapshot: SnapshotBox
    private let lock = NSLock()
    private var memo: [String: Chat] = [:]

    init(url: URL) { snapshot = SnapshotBox(url: url) }

    func reset() throws -> Database {
        lock.lock(); memo = [:]; lock.unlock()
        return try snapshot.refresh()
    }

    func chat(_ id: String, build: (Database) throws -> Chat) throws -> Chat {
        lock.lock(); let hit = memo[id]; lock.unlock()
        if let hit { return hit }
        let built = try build(try snapshot.database())
        lock.lock(); memo[id] = built; lock.unlock()
        return built
    }
}

// MARK: - iMessage

public struct IMessageConnector: Connector {
    public let databaseURL: URL
    public let selectedChatIDs: Set<String>
    public let kind: SourceKind = .chat
    public var bucket: String { "imessage" }
    public let listsAllItems = false
    public var maxWindowChars = 4_000
    private let cache: ChatCache

    public static var defaultDatabase: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db") }

    public init(databaseURL: URL = IMessageConnector.defaultDatabase, selectedChatIDs: Set<String>) {
        self.databaseURL = databaseURL; self.selectedChatIDs = selectedChatIDs; self.cache = ChatCache(url: databaseURL)
    }

    /// Chats available for the user to opt into. Reads names and counts only, never message text.
    public static func listChats(databaseURL: URL = defaultDatabase) throws -> [ChatSummary] {
        let (db, cleanup) = try DatabaseSnapshot.open(databaseURL)
        defer { cleanup() }
        return try db.query(
            """
            SELECT c.guid, COALESCE(NULLIF(c.display_name,''), c.chat_identifier), c.style, COUNT(m.ROWID)
            FROM chat c JOIN chat_message_join j ON j.chat_id = c.ROWID JOIN message m ON m.ROWID = j.message_id
            WHERE m.associated_message_type = 0 AND m.item_type = 0
            GROUP BY c.ROWID ORDER BY COUNT(m.ROWID) DESC
            """, []
        ) { ChatSummary(id: $0.text(0), name: $0.text(1), isGroup: $0.int(2) == 43, messageCount: Int($0.int(3))) }
    }

    public func list() async throws -> [WorkItemRef] {
        _ = try cache.reset()   // one fresh copy for the whole run
        var refs: [WorkItemRef] = []
        for chat in selectedChatIDs.sorted() {
            let (info, windows) = try cache.chat(chat) { try Self.read(chat, in: $0, maxChars: maxWindowChars) }
            for window in windows {
                let digest = Hashing.sha256Hex("\(window.count)|\(window.last?.rowID ?? 0)|\(window.reduce(0) { $0 + $1.text.count })")
                refs.append(WorkItemRef(
                    key: "\(chat)#\(window.first?.rowID ?? 0)", fingerprint: digest, date: window.last?.date,
                    title: "Chat with \(info.name)", uri: "imessage://\(chat)", trust: .correspondence))
            }
        }
        return refs
    }

    public func load(_ ref: WorkItemRef) async throws -> ItemContent {
        // key = "<chat guid>#<first rowid>"
        let parts = ref.key.components(separatedBy: "#")
        guard parts.count == 2, let first = Int64(parts[1]) else { throw ConnectorError.unreadable("bad key") }
        let (info, windows) = try cache.chat(parts[0]) { try Self.read(parts[0], in: $0, maxChars: maxWindowChars) }
        guard let window = windows.first(where: { $0.first?.rowID == first }) else { throw ConnectorError.unreadable("window no longer exists") }
        return .conversation(lines: ChatWindowing.render(window), info: info)
    }

    static func read(_ chatID: String, in db: Database, maxChars: Int) throws -> ChatCache.Chat {
        guard let row = try db.query("SELECT COALESCE(NULLIF(display_name,''), chat_identifier), style FROM chat WHERE guid = ?", [.text(chatID)], { ($0.text(0), $0.int(1)) }).first
        else { throw ConnectorError.unreadable("chat not found") }
        let lines = try db.query(
            """
            SELECT m.ROWID, m.date, m.is_from_me, COALESCE(h.id, ''), m.text, m.attributedBody
            FROM message m
            JOIN chat_message_join j ON j.message_id = m.ROWID
            JOIN chat c ON c.ROWID = j.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE c.guid = ? AND m.associated_message_type = 0 AND m.item_type = 0
            ORDER BY m.ROWID
            """, [.text(chatID)]
        ) { r -> ChatLine? in
            // Newer macOS versions leave `text` empty and keep the body in a typedstream blob.
            var text = r.optText(4) ?? ""
            if text.isEmpty { text = TypedStream.extractText(from: r.blob(5)) ?? "" }
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ChatLine(rowID: r.int(0), date: Self.appleDate(r.double(1)), sender: r.int(2) == 1 ? "Me" : (r.text(3).isEmpty ? "Them" : r.text(3)), text: text)
        }.compactMap { $0 }
        return (ConversationInfo(name: row.0, isGroup: row.1 == 43), ChatWindowing.windows(lines, maxChars: maxChars))
    }

    /// iMessage stores nanoseconds since 2001-01-01 on modern macOS and seconds on old versions.
    static func appleDate(_ raw: Double) -> Date {
        let seconds = raw > 1_000_000_000_000 ? raw / 1_000_000_000 : raw
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}

/// Minimal reader for the `attributedBody` typedstream blob: finds the `NSString` payload.
/// Layout after the class name: `0x01 0x94 0x84 0x01 0x2B`, then a length (one byte, or `0x81`
/// followed by a little-endian UInt16, or `0x82` + UInt32), then that many UTF-8 bytes.
enum TypedStream {
    static func extractText(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard let at = find(marker, in: bytes) else { return nil }
        var i = at + marker.count
        // Skip the class-hierarchy bytes up to the "+" (0x2B) string tag.
        while i < bytes.count, bytes[i] != 0x2B { i += 1; if i - at > 24 { return nil } }
        i += 1
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i]); i += 1
        if length == 0x81, i + 2 <= bytes.count { length = Int(bytes[i]) | Int(bytes[i + 1]) << 8; i += 2 }
        else if length == 0x82, i + 4 <= bytes.count { length = (0..<4).reduce(0) { $0 | Int(bytes[i + $1]) << (8 * $1) }; i += 4 }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(data: Data(bytes[i..<(i + length)]), encoding: .utf8)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }
}

// MARK: - WhatsApp (macOS app database)

/// Reads the WhatsApp desktop app's local database. NOTE: the table and column names below come
/// from the app's Core Data schema as commonly documented and could not be verified against a real
/// database in this build environment; the connector is covered by tests against a fixture that
/// follows that schema, so a schema change would show up as a read error rather than wrong data.
public struct WhatsAppConnector: Connector {
    public let databaseURL: URL
    public let selectedChatIDs: Set<String>
    public let kind: SourceKind = .chat
    public var bucket: String { "whatsapp" }
    public let listsAllItems = false
    public var maxWindowChars = 4_000
    private let cache: ChatCache

    public static var defaultDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")
    }

    public init(databaseURL: URL = WhatsAppConnector.defaultDatabase, selectedChatIDs: Set<String>) {
        self.databaseURL = databaseURL; self.selectedChatIDs = selectedChatIDs; self.cache = ChatCache(url: databaseURL)
    }

    public static func listChats(databaseURL: URL = defaultDatabase) throws -> [ChatSummary] {
        let (db, cleanup) = try DatabaseSnapshot.open(databaseURL)
        defer { cleanup() }
        return try db.query(
            """
            SELECT s.ZCONTACTJID, COALESCE(NULLIF(s.ZPARTNERNAME,''), s.ZCONTACTJID), s.ZSESSIONTYPE, COUNT(m.Z_PK)
            FROM ZWACHATSESSION s JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK
            WHERE m.ZTEXT IS NOT NULL AND m.ZTEXT != ''
            GROUP BY s.Z_PK ORDER BY COUNT(m.Z_PK) DESC
            """, []
        ) { ChatSummary(id: $0.text(0), name: $0.text(1), isGroup: $0.int(2) == 1, messageCount: Int($0.int(3))) }
    }

    public func list() async throws -> [WorkItemRef] {
        _ = try cache.reset()
        var refs: [WorkItemRef] = []
        for chat in selectedChatIDs.sorted() {
            let (info, windows) = try cache.chat(chat) { try Self.read(chat, in: $0, maxChars: maxWindowChars) }
            for window in windows {
                let digest = Hashing.sha256Hex("\(window.count)|\(window.last?.rowID ?? 0)|\(window.reduce(0) { $0 + $1.text.count })")
                refs.append(WorkItemRef(
                    key: "\(chat)#\(window.first?.rowID ?? 0)", fingerprint: digest, date: window.last?.date,
                    title: "WhatsApp: \(info.name)", uri: "whatsapp://\(chat)", trust: .correspondence))
            }
        }
        return refs
    }

    public func load(_ ref: WorkItemRef) async throws -> ItemContent {
        let parts = ref.key.components(separatedBy: "#")
        guard parts.count == 2, let first = Int64(parts[1]) else { throw ConnectorError.unreadable("bad key") }
        let (info, windows) = try cache.chat(parts[0]) { try Self.read(parts[0], in: $0, maxChars: maxWindowChars) }
        guard let window = windows.first(where: { $0.first?.rowID == first }) else { throw ConnectorError.unreadable("window no longer exists") }
        return .conversation(lines: ChatWindowing.render(window), info: info)
    }

    static func read(_ chatID: String, in db: Database, maxChars: Int) throws -> ChatCache.Chat {
        guard let session = try db.query(
            "SELECT Z_PK, COALESCE(NULLIF(ZPARTNERNAME,''), ZCONTACTJID), ZSESSIONTYPE FROM ZWACHATSESSION WHERE ZCONTACTJID = ?", [.text(chatID)],
            { ($0.int(0), $0.text(1), $0.int(2)) }).first
        else { throw ConnectorError.unreadable("chat not found") }
        let lines = try db.query(
            """
            SELECT m.Z_PK, m.ZMESSAGEDATE, m.ZISFROMME, COALESCE(gm.ZMEMBERJID, ''), m.ZTEXT
            FROM ZWAMESSAGE m LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER
            WHERE m.ZCHATSESSION = ? AND m.ZTEXT IS NOT NULL AND m.ZTEXT != '' ORDER BY m.Z_PK
            """, [.int(session.0)]
        ) { r in
            ChatLine(rowID: r.int(0), date: Date(timeIntervalSinceReferenceDate: r.double(1)),
                     sender: r.int(2) == 1 ? "Me" : (r.text(3).isEmpty ? session.1 : r.text(3)), text: r.text(4))
        }
        return (ConversationInfo(name: session.1, isGroup: session.2 == 1), ChatWindowing.windows(lines, maxChars: maxChars))
    }
}
