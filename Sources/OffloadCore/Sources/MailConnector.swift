import Foundation

public struct ParsedMail: Sendable, Equatable {
    public var subject: String
    public var from: String
    public var to: String
    public var date: Date?
    public var messageID: String
    public var body: String
}

/// A small, defensive MIME reader for Apple Mail's `.emlx` files (a byte count line, the RFC 822
/// message, then a property list). It handles what real mail needs — multipart nesting, quoted-
/// printable and base64, RFC 2047 encoded headers, common Western and Chinese charsets — and
/// ignores attachments. Anything it cannot decode becomes an empty body rather than garbage.
public enum EMLXParser {
    public static func parse(_ file: Data) -> ParsedMail? {
        guard let nl = file.firstIndex(of: 0x0A), let count = Int(String(decoding: file[file.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)), count > 0 else {
            return parseRFC822(file)  // a bare message without the emlx wrapper
        }
        let start = file.index(after: nl)
        let end = min(file.endIndex, file.index(start, offsetBy: count))
        return parseRFC822(file[start..<end])
    }

    static func parseRFC822(_ data: Data) -> ParsedMail? {
        let entity = Entity(Data(data))
        guard !entity.headers.isEmpty else { return nil }
        let body = entity.plainText().trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedMail(
            subject: decodeWords(entity.header("subject") ?? ""), from: decodeWords(entity.header("from") ?? ""),
            to: decodeWords(entity.header("to") ?? ""), date: entity.header("date").flatMap(parseDate),
            messageID: entity.header("message-id") ?? "", body: stripQuotedReply(body))
    }

    // MARK: Entities

    struct Entity {
        var headers: [String: String] = [:]   // lowercased name -> unfolded value
        var body = Data()

        init(_ raw: Data) {
            let (head, rest) = Self.split(raw)
            self.body = rest
            let text = String(decoding: head, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            var currentName: String?
            for line in text.components(separatedBy: "\n") {
                if line.first == " " || line.first == "\t", let n = currentName { headers[n, default: ""] += " " + line.trimmingCharacters(in: .whitespaces); continue }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].lowercased()
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                currentName = name
            }
        }

        func header(_ n: String) -> String? { headers[n] }

        static func split(_ data: Data) -> (Data, Data) {
            let bytes = [UInt8](data)
            var i = 0
            while i < bytes.count - 1 {
                if bytes[i] == 0x0A && bytes[i + 1] == 0x0A { return (Data(bytes[..<i]), Data(bytes[(i + 2)...])) }
                if i + 3 < bytes.count, bytes[i] == 0x0D, bytes[i + 1] == 0x0A, bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A { return (Data(bytes[..<i]), Data(bytes[(i + 4)...])) }
                i += 1
            }
            return (data, Data())
        }

        var contentType: (type: String, params: [String: String]) {
            let raw = headers["content-type"] ?? "text/plain; charset=us-ascii"
            let pieces = raw.split(separator: ";", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            var params: [String: String] = [:]
            for p in pieces.dropFirst() {
                guard let eq = p.firstIndex(of: "=") else { continue }
                params[p[..<eq].lowercased()] = p[p.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
            return ((pieces.first ?? "text/plain").lowercased(), params)
        }

        /// All readable text in this entity: text/plain parts preferred, HTML stripped as a fallback.
        func plainText() -> String {
            let (type, params) = contentType
            if headers["content-disposition"]?.lowercased().hasPrefix("attachment") == true { return "" }
            if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
                let parts = splitMultipart(boundary).map { Entity($0) }
                let plain = parts.filter { $0.contentType.type == "text/plain" || $0.contentType.type.hasPrefix("multipart/") }.map { $0.plainText() }.filter { !$0.isEmpty }
                if !plain.isEmpty { return plain.joined(separator: "\n\n") }
                return parts.map { $0.plainText() }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            guard type == "text/plain" || type == "text/html" else { return "" }
            let decoded = decodeTransfer()
            let text = EMLXParser.decodeCharset(decoded, params["charset"])
            return type == "text/html" ? HTMLText.strip(text) : text
        }

        func decodeTransfer() -> Data {
            switch (headers["content-transfer-encoding"] ?? "").lowercased() {
            case "base64": return Data(base64Encoded: String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters) ?? Data()
            case "quoted-printable": return EMLXParser.decodeQuotedPrintable(body)
            default: return body
            }
        }

        func splitMultipart(_ boundary: String) -> [Data] {
            let text = String(decoding: body, as: UTF8.self)
            let delimiter = "--" + boundary
            var parts: [Data] = []
            let chunks = text.components(separatedBy: delimiter)
            for chunk in chunks.dropFirst() {
                if chunk.hasPrefix("--") { break }
                var c = chunk
                // "\r\n" is ONE Character in Swift (a single grapheme cluster); removing two would eat
                // the first letter of the part's first header.
                if c.hasPrefix("\r\n") || c.hasPrefix("\n") { c.removeFirst() }
                parts.append(Data(c.utf8))
            }
            return parts
        }
    }

    // MARK: Decoding helpers

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = [UInt8](); let b = [UInt8](data); var i = 0
        while i < b.count {
            if b[i] == 0x3D {  // "="
                if i + 1 < b.count, b[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < b.count, let h = UInt8(String(bytes: [b[i + 1], b[i + 2]], encoding: .ascii) ?? "", radix: 16) { out.append(h); i += 3; continue }
            }
            out.append(b[i]); i += 1
        }
        return Data(out)
    }

    static func decodeCharset(_ data: Data, _ name: String?) -> String {
        let label = (name ?? "utf-8").lowercased()
        var encodings: [String.Encoding] = []
        if label == "utf-8" || label == "utf8" || label == "us-ascii" { encodings = [.utf8] }
        else if label.contains("8859-1") || label == "latin1" || label == "windows-1252" { encodings = [.isoLatin1, .windowsCP1252] }
        else {
            let cf = CFStringConvertIANACharSetNameToEncoding(label as CFString)
            if cf != kCFStringEncodingInvalidId { encodings = [String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))] }
        }
        for e in encodings { if let s = String(data: data, encoding: e) { return s } }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// RFC 2047: `=?charset?B|Q?text?=`
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?"), let re = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return s }
        let ns = s as NSString
        var out = s
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let charset = ns.substring(with: m.range(at: 1)), enc = ns.substring(with: m.range(at: 2)).lowercased(), payload = ns.substring(with: m.range(at: 3))
            let data: Data
            if enc == "b" { data = Data(base64Encoded: payload) ?? Data() }
            else { data = decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8)) }
            out = (out as NSString).replacingCharacters(in: m.range, with: decodeCharset(data, charset))
        }
        // Whitespace between adjacent encoded words is not content.
        return out.replacingOccurrences(of: #"(?<=\S) {2,}(?=\S)"#, with: " ", options: .regularExpression)
    }

    static func parseDate(_ s: String) -> Date? {
        let cleaned = s.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, dd MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = format
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }

    /// Drops quoted history ("> ..." lines and the "On ... wrote:" tail) so only what the sender
    /// actually wrote is analyzed.
    static func stripQuotedReply(_ body: String) -> String {
        var kept: [String] = []
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { continue }
            if t.hasPrefix("-----Original Message") || t.hasPrefix("________________________________") { break }
            if t.range(of: #"^On .{5,120} wrote:$"#, options: .regularExpression) != nil { break }
            if t.range(of: #"^.{0,40}(写道|寫道)[::]$"#, options: .regularExpression) != nil { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads Apple Mail's local message store (`~/Library/Mail/V*/…/*.emlx`). Needs Full Disk Access.
public struct MailConnector: Connector {
    public let root: URL
    public let kind: SourceKind = .mail
    public var bucket: String { "mail:" + root.path }
    public let listsAllItems = true
    /// Newest messages first; older mail is picked up on later runs as the budget allows.
    public var maxMessages = 800
    public var maxBodyChars = 8_000

    static let skippedMailboxes = ["junk", "spam", "trash", "deleted", "drafts", "垃圾", "已删除", "草稿", "outbox"]

    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail") }

    public init(root: URL = MailConnector.defaultRoot) { self.root = root }

    public func list() async throws -> [WorkItemRef] { try scan() }

    func scan() throws -> [WorkItemRef] {
        guard FileManager.default.fileExists(atPath: root.path) else { throw ConnectorError.unreadable("mail folder not found: \(root.path)") }
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsPackageDescendants])
        else { throw ConnectorError.permissionDenied("cannot enumerate \(root.path)") }
        var found: [(URL, Date, Int)] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasSuffix(".emlx"), !name.hasSuffix(".partial.emlx") else { continue }  // partial = body not downloaded
            let lowerPath = url.path.lowercased()
            if Self.skippedMailboxes.contains(where: { lowerPath.contains($0 + ".mbox") || lowerPath.contains("/" + $0) }) { continue }
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            found.append((url, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0))
        }
        found.sort { $0.1 > $1.1 }
        return found.prefix(maxMessages).map { url, mtime, size in
            let head = (try? FileHandle(forReadingFrom: url).read(upToCount: 6_000)) ?? Data()
            let parsed = EMLXParser.parse(head) ?? nil  // headers are all that is needed here
            return WorkItemRef(
                key: url.path, fingerprint: "\(size)-\(Int(mtime.timeIntervalSince1970))", date: parsed?.date ?? mtime,
                title: (parsed?.subject.isEmpty == false ? parsed!.subject : "(no subject)"), uri: url.path, trust: .correspondence)
        }
    }

    public func load(_ ref: WorkItemRef) async throws -> ItemContent {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ref.key)), let mail = EMLXParser.parse(data) else {
            throw ConnectorError.unreadable("cannot parse message")
        }
        let body = String(mail.body.prefix(maxBodyChars))
        return .text("From: \(mail.from)\nTo: \(mail.to)\nSubject: \(mail.subject)\n\n\(body)")
    }
}
