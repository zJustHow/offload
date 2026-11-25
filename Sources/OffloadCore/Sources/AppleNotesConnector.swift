import Foundation

/// gzip container reader. Apple Notes stores each note as a gzip stream; the DEFLATE payload is
/// handed to the system decompressor after the variable-length gzip header is skipped.
enum Gzip {
    static func decompress(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw ConnectorError.unreadable("not a gzip stream") }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { throw ConnectorError.unreadable("truncated gzip") }; i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {   // file name, comment: zero-terminated
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { throw ConnectorError.unreadable("truncated gzip") }
        let deflate = Data(b[i..<(b.count - 8)]) as NSData   // the last 8 bytes are CRC32 + size
        do { return try deflate.decompressed(using: .zlib) as Data } catch { throw ConnectorError.unreadable("corrupt gzip data") }
    }
}

/// The few Protocol Buffers wire-format rules needed to pull text out of a note, without a schema
/// or a dependency: varints, 32/64-bit values and length-delimited fields.
enum ProtoReader {
    struct Field { let number: Int; let bytes: Data? }

    static func fields(in data: Data) -> [Field] {
        let b = [UInt8](data)
        var i = 0
        var out: [Field] = []
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { break }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0: guard varint() != nil else { return out }; out.append(Field(number: number, bytes: nil))
            case 1: i += 8; out.append(Field(number: number, bytes: nil))
            case 5: i += 4; out.append(Field(number: number, bytes: nil))
            case 2:
                guard let len = varint(), len <= UInt64(b.count - i) else { return out }
                out.append(Field(number: number, bytes: Data(b[i..<(i + Int(len))]))); i += Int(len)
            default: return out   // groups / unknown wire types: stop rather than guess
            }
        }
        return out
    }

    /// Notes are `NoteStoreProto { document = 2 { note = 3 { note_text = 2 } } }`.
    static func noteText(from data: Data) -> String? {
        guard let doc = fields(in: data).first(where: { $0.number == 2 })?.bytes,
            let note = fields(in: doc).first(where: { $0.number == 3 })?.bytes,
            let text = fields(in: note).first(where: { $0.number == 2 })?.bytes
        else { return nil }
        return String(data: text, encoding: .utf8)
    }
}

/// Reads Apple Notes from its local Core Data store. The table has changed shape between macOS
/// versions, so the connector asks the database which columns exist and selects only those.
/// Password-protected notes, notes marked for deletion and the Recently Deleted folder are skipped.
/// Needs Full Disk Access. The store layout comes from public reverse-engineering notes and could
/// not be checked against a real database in the environment this was written in; it is covered by
/// fixtures that follow that layout.
public struct AppleNotesConnector: Connector {
    public let databaseURL: URL
    public let kind: SourceKind = .note
    public let bucket = "applenotes"
    public let listsAllItems = true
    private let snapshot: SnapshotBox

    public static var defaultDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }

    public init(databaseURL: URL = AppleNotesConnector.defaultDatabase) { self.databaseURL = databaseURL; self.snapshot = SnapshotBox(url: databaseURL) }

    public func list() async throws -> [WorkItemRef] {
        let db = try snapshot.refresh()   // one copy per run; `load` reuses it
        let cols = Set(try db.query("PRAGMA table_info(ZICCLOUDSYNCINGOBJECT)", []) { $0.text(1) })
        guard cols.contains("ZNOTEDATA") else { throw ConnectorError.unreadable("this does not look like an Apple Notes database") }
        func col(_ alias: String, _ name: String, fallback: String = "NULL") -> String { cols.contains(name) ? "\(alias).\(name)" : fallback }

        let sql = """
            SELECT n.Z_PK, \(col("n", "ZIDENTIFIER")), \(col("n", "ZTITLE1")), \(col("n", "ZMODIFICATIONDATE1")), \(col("n", "ZCREATIONDATE1"))
            FROM ZICCLOUDSYNCINGOBJECT n
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = \(col("n", "ZFOLDER", fallback: "-1"))
            WHERE n.ZNOTEDATA IS NOT NULL
              AND COALESCE(\(col("n", "ZMARKEDFORDELETION", fallback: "0")), 0) = 0
              AND COALESCE(\(col("n", "ZISPASSWORDPROTECTED", fallback: "0")), 0) = 0
              AND COALESCE(\(col("f", "ZFOLDERTYPE", fallback: "0")), 0) != 1
            """
        return try db.query(sql, []) { r in
            let pk = r.int(0)
            let id = r.optText(1) ?? "pk\(pk)"
            let modified = r.optDouble(3) ?? r.optDouble(4)
            return WorkItemRef(
                key: id, fingerprint: "\(Int(modified ?? 0))-\(pk)", date: modified.map { Date(timeIntervalSinceReferenceDate: $0) },
                title: (r.optText(2)?.isEmpty == false ? r.text(2) : "Untitled note"),
                uri: "notes://showNote?identifier=\(id)", trust: .authored)
        }
    }

    public func load(_ ref: WorkItemRef) async throws -> ItemContent {
        let db = try snapshot.database()
        let cols = Set(try db.query("PRAGMA table_info(ZICCLOUDSYNCINGOBJECT)", []) { $0.text(1) })
        let match = cols.contains("ZIDENTIFIER") && !ref.key.hasPrefix("pk") ? "n.ZIDENTIFIER = ?" : "n.Z_PK = ?"
        let param: SQLValue = match.hasPrefix("n.Z_PK") ? .int(Int(ref.key.dropFirst(2)) ?? -1) : .text(ref.key)
        let folderColumn = cols.contains("ZFOLDER") ? "n.ZFOLDER" : "-1"
        let rows = try db.query(
            """
            SELECT d.ZDATA, f.ZTITLE2 FROM ZICCLOUDSYNCINGOBJECT n
            JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = \(folderColumn)
            WHERE \(match)
            """, [param]) { ($0.blob(0), $0.optText(1)) }
        guard let (blob, folder) = rows.first, !blob.isEmpty else { throw ConnectorError.unreadable("note no longer exists") }
        // Some notes are stored uncompressed; accept both.
        let proto = blob.starts(with: [0x1F, 0x8B]) ? try Gzip.decompress(blob) : blob
        guard let text = ProtoReader.noteText(from: proto) else { throw ConnectorError.unreadable("could not read this note's contents") }
        let clean = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .text((folder.map { "Apple Notes folder: \($0)\n\n" } ?? "") + clean)
    }
}
