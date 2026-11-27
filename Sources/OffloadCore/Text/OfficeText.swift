import Compression
import Foundation

/// Plain text of Word (`.docx`) and PowerPoint (`.pptx`) files.
///
/// Both formats are ZIP archives of XML parts, so no third-party library is needed: a small ZIP
/// reader (stored and DEFLATE entries) and a streaming XML pass over the few parts that hold text.
///
/// These files come from folders the user chose but are still untrusted input, so nothing in the
/// archive is taken on faith: every offset is bounds-checked, every entry is inflated through a stream
/// that stops at `maxEntryBytes` (a ZIP bomb cannot exhaust memory), XML external entities are not
/// resolved, and extraction stops once `maxChars` characters have been produced.
///
/// Word: the body, plus footnotes and endnotes. Paragraph, line-break, tab and table structure is kept
/// as newlines and tabs. PowerPoint: slides in presentation order (not file-name order, which stops
/// matching once slides are reordered), each introduced by "Slide N", followed by its speaker notes.
/// Not handled: legacy `.doc` / `.ppt`, password-protected files (those are not ZIP archives), text
/// inside charts, SmartArt and embedded objects, and ZIP64 archives.
public enum OfficeText {
    /// The most any single archive entry may inflate to.
    public static let maxEntryBytes = 32 * 1024 * 1024

    public static func docx(at url: URL, maxChars: Int = 200_000) throws -> String {
        try docx(Data(contentsOf: url, options: .mappedIfSafe), maxChars: maxChars, maxEntryBytes: maxEntryBytes)
    }

    public static func pptx(at url: URL, maxChars: Int = 200_000) throws -> String {
        try pptx(Data(contentsOf: url, options: .mappedIfSafe), maxChars: maxChars, maxEntryBytes: maxEntryBytes)
    }

    // MARK: Word

    static func docx(_ data: Data, maxChars: Int, maxEntryBytes: Int) throws -> String {
        let zip = try ZipArchive(data)
        guard let body = try zip.contents(of: "word/document.xml", limit: maxEntryBytes) else {
            throw ConnectorError.unreadable("not a Word document (no word/document.xml)")
        }
        var sections = [try extract(body, kind: .word, maxChars: maxChars)]
        for part in ["word/footnotes.xml", "word/endnotes.xml"] {
            guard let xml = try zip.contents(of: part, limit: maxEntryBytes) else { continue }
            let text = try extract(xml, kind: .word, maxChars: maxChars)
            if !text.isEmpty { sections.append(text) }
        }
        return String(sections.filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(maxChars))
    }

    // MARK: PowerPoint

    static func pptx(_ data: Data, maxChars: Int, maxEntryBytes: Int) throws -> String {
        let zip = try ZipArchive(data)
        let slides = (try? orderedSlides(in: zip, limit: maxEntryBytes)) ?? []
        guard !slides.isEmpty else { throw ConnectorError.unreadable("not a PowerPoint file (no slides)") }

        var blocks: [String] = []
        var total = 0
        for (index, part) in slides.enumerated() {
            guard let xml = try zip.contents(of: part, limit: maxEntryBytes) else { continue }
            let text = try extract(xml, kind: .drawing, maxChars: maxChars)
            let notes = (try? speakerNotes(for: part, in: zip, limit: maxEntryBytes, maxChars: maxChars)) ?? ""
            if text.isEmpty && notes.isEmpty { continue }
            var block = "Slide \(index + 1)"
            if !text.isEmpty { block += "\n" + text }
            if !notes.isEmpty { block += "\nNotes: " + notes }
            blocks.append(block)
            total += block.count
            if total > maxChars { break }
        }
        return String(blocks.joined(separator: "\n\n").prefix(maxChars))
    }

    /// Slide parts in the order of the deck: `presentation.xml` lists the slides by relationship id,
    /// the relationships file maps ids to parts. Falls back to the numbers in the file names.
    private static func orderedSlides(in zip: ZipArchive, limit: Int) throws -> [String] {
        if let presentation = try zip.contents(of: "ppt/presentation.xml", limit: limit),
           let relsData = try zip.contents(of: "ppt/_rels/presentation.xml.rels", limit: limit) {
            let ids = SlideIDParser.parse(presentation)
            let targets = Dictionary(RelationshipParser.parse(relsData).map { ($0.id, $0.target) }, uniquingKeysWith: { first, _ in first })
            let ordered = ids.compactMap { targets[$0] }.map { resolve($0, relativeTo: "ppt") }.filter { zip.has($0) }
            if !ordered.isEmpty { return ordered }
        }
        let prefix = "ppt/slides/slide", suffix = ".xml"
        return zip.names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix), let n = Int(name.dropFirst(prefix.count).dropLast(suffix.count)) else { return nil }
            return (n, name)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func speakerNotes(for slidePart: String, in zip: ZipArchive, limit: Int, maxChars: Int) throws -> String {
        let directory = (slidePart as NSString).deletingLastPathComponent
        let relsPart = directory + "/_rels/" + (slidePart as NSString).lastPathComponent + ".rels"
        guard let relsData = try zip.contents(of: relsPart, limit: limit),
              let rel = RelationshipParser.parse(relsData).first(where: { $0.type.hasSuffix("/notesSlide") })
        else { return "" }
        let notesPart = resolve(rel.target, relativeTo: directory)
        guard let xml = try zip.contents(of: notesPart, limit: limit) else { return "" }
        // The notes page repeats the slide number as a field of its own; drop lines that are only digits.
        return try extract(xml, kind: .drawing, maxChars: maxChars)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.allSatisfy(\.isNumber) }
            .joined(separator: "\n")
    }

    /// A relationship target (`../notesSlides/notesSlide1.xml`, or absolute `/ppt/...`) as an archive path.
    static func resolve(_ target: String, relativeTo directory: String) -> String {
        var parts = target.hasPrefix("/") ? [] : directory.split(separator: "/").map(String.init)
        for component in target.split(separator: "/") {
            if component == ".." { _ = parts.popLast() } else if component != "." { parts.append(String(component)) }
        }
        return parts.joined(separator: "/")
    }

    // MARK: XML text

    fileprivate static func extract(_ xml: Data, kind: TextExtractor.Kind, maxChars: Int) throws -> String {
        let collector = TextExtractor(kind: kind, maxChars: maxChars)
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        let finished = parser.parse()
        // Whatever was read before a parse error is still worth having; only nothing at all is a failure.
        if !finished, !collector.truncated, collector.text.isEmpty { throw ConnectorError.unreadable("malformed XML") }
        return tidy(collector.text)
    }

    private static func tidy(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r", with: "")
        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Text collection

private final class TextExtractor: NSObject, XMLParserDelegate {
    enum Kind { case word, drawing }

    private let kind: Kind
    private let maxChars: Int
    private var stack: [String] = []
    /// Stack depth at which an `mc:Fallback` began. Office writes shapes twice (a modern form and a
    /// fallback for old readers); only the first is read, or text boxes would appear twice.
    private var skipping: Int?
    private var inText = false
    private var cellDepth = 0
    private var emitted = 0
    private(set) var text = ""
    private(set) var truncated = false

    init(kind: Kind, maxChars: Int) { self.kind = kind; self.maxChars = maxChars }

    private func isContent(_ namespace: String?) -> Bool {
        guard let namespace else { return false }
        return namespace.contains(kind == .word ? "wordprocessingml" : "drawingml")
    }

    private func emit(_ s: String, _ parser: XMLParser) {
        text += s
        emitted += s.count
        if emitted > maxChars { truncated = true; parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let parent = stack.last
        if skipping == nil, name == "Fallback", namespaceURI?.contains("markup-compatibility") == true { skipping = stack.count }
        stack.append(name)
        guard skipping == nil, isContent(namespaceURI) else { return }
        switch name {
        case "t": inText = true
        case "tc": cellDepth += 1
        // In Word a tab or break is content only inside a run (`w:tabs/w:tab` defines tab stops).
        case "tab" where kind == .word && parent == "r": emit("\t", parser)
        case "br", "cr": if kind == .drawing || parent == "r" { emit("\n", parser) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if !stack.isEmpty { stack.removeLast() }
        if let depth = skipping {
            if stack.count == depth { skipping = nil }
            return
        }
        guard isContent(namespaceURI) else { return }
        switch name {
        case "t": inText = false
        // Inside a table cell a paragraph break would split the row apart; a space keeps it on one line.
        case "p": emit(cellDepth > 0 ? " " : "\n", parser)
        case "tr": emit("\n", parser)
        case "tc":
            cellDepth = max(0, cellDepth - 1)
            while text.last == " " { text.removeLast() }
            emit("\t", parser)
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText, skipping == nil { emit(string, parser) }
    }
}

private final class RelationshipParser: NSObject, XMLParserDelegate {
    struct Relationship { var id: String; var type: String; var target: String }
    private var found: [Relationship] = []

    static func parse(_ data: Data) -> [Relationship] {
        let delegate = RelationshipParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.found
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "Relationship" { found.append(Relationship(id: attributes["Id"] ?? "", type: attributes["Type"] ?? "", target: attributes["Target"] ?? "")) }
    }
}

/// The relationship ids of `<p:sldId id="256" r:id="rId2"/>`, in deck order.
private final class SlideIDParser: NSObject, XMLParserDelegate {
    private var ids: [String] = []

    static func parse(_ data: Data) -> [String] {
        let delegate = SlideIDParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.ids
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard (qualifiedName ?? name).hasSuffix("sldId") || name == "sldId",
              let id = attributes.first(where: { $0.key.hasSuffix(":id") })?.value else { return }
        ids.append(id)
    }
}

// MARK: - ZIP

private struct ZipArchive {
    struct Entry {
        var flags: Int, method: Int, compressedSize: Int, uncompressedSize: Int, headerOffset: Int
        var isZip64: Bool
    }

    private let bytes: ByteReader
    private var entries: [String: Entry] = [:]
    private(set) var names: [String] = []

    init(_ data: Data) throws {
        bytes = ByteReader(data: data)
        guard data.count >= 22 else { throw ConnectorError.unreadable("not a ZIP archive") }

        // The end-of-central-directory record is at the very end, followed only by a comment.
        var end: Int?
        var i = data.count - 22
        while i >= max(0, data.count - 22 - 65_535) {
            if try bytes.u32(i) == 0x0605_4B50 { end = i; break }
            i -= 1
        }
        guard let end else { throw ConnectorError.unreadable("not a ZIP archive") }
        let total = try bytes.u16(end + 10)
        let directoryOffset = try bytes.u32(end + 16)
        if total == 0xFFFF || directoryOffset == 0xFFFF_FFFF { throw ConnectorError.unreadable("ZIP64 archives are not supported") }

        var position = directoryOffset
        for _ in 0..<total {
            guard try bytes.u32(position) == 0x0201_4B50 else { throw ConnectorError.unreadable("corrupt ZIP directory") }
            let compressed = try bytes.u32(position + 20), uncompressed = try bytes.u32(position + 24)
            let nameLength = try bytes.u16(position + 28), extraLength = try bytes.u16(position + 30), commentLength = try bytes.u16(position + 32)
            let offset = try bytes.u32(position + 42)
            let name = String(decoding: try bytes.slice(position + 46, nameLength), as: UTF8.self)
            if !name.hasSuffix("/"), entries[name] == nil {
                entries[name] = Entry(
                    flags: try bytes.u16(position + 8), method: try bytes.u16(position + 10),
                    compressedSize: compressed, uncompressedSize: uncompressed, headerOffset: offset,
                    isZip64: compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || offset == 0xFFFF_FFFF)
                names.append(name)
            }
            position += 46 + nameLength + extraLength + commentLength
        }
    }

    func has(_ name: String) -> Bool { entries[name] != nil }

    /// The inflated bytes of one entry, or nil when the archive has no such entry.
    func contents(of name: String, limit: Int) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        if entry.isZip64 { throw ConnectorError.unreadable("ZIP64 entries are not supported") }
        if entry.flags & 1 != 0 { throw ConnectorError.unreadable("\(name) is encrypted") }
        if entry.uncompressedSize > limit { throw ConnectorError.unreadable("\(name) is larger than \(limit) bytes") }

        let header = entry.headerOffset
        guard try bytes.u32(header) == 0x0403_4B50 else { throw ConnectorError.unreadable("corrupt ZIP entry") }
        let start = header + 30 + (try bytes.u16(header + 26)) + (try bytes.u16(header + 28))
        let payload = try bytes.slice(start, entry.compressedSize)
        switch entry.method {
        case 0:
            guard payload.count <= limit else { throw ConnectorError.unreadable("\(name) is larger than \(limit) bytes") }
            return payload
        case 8: return try Self.inflate(payload, limit: limit)
        default: throw ConnectorError.unreadable("unsupported ZIP compression method \(entry.method)")
        }
    }

    /// Raw DEFLATE (which is what `COMPRESSION_ZLIB` decodes), stopping as soon as `limit` is exceeded.
    static func inflate(_ input: Data, limit: Int) throws -> Data {
        if input.isEmpty { return Data() }
        let chunk = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { destination.deallocate(); stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw ConnectorError.unreadable("cannot start decompression")
        }
        defer { compression_stream_destroy(stream) }

        var output = Data()
        var failure: ConnectorError?
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            stream.pointee.dst_ptr = destination
            stream.pointee.dst_size = chunk
            while true {
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 { output.append(destination, count: produced) }
                if output.count > limit { failure = .unreadable("entry is larger than \(limit) bytes"); return }
                if status == COMPRESSION_STATUS_END { return }
                if status != COMPRESSION_STATUS_OK { failure = .unreadable("corrupt compressed data"); return }
                if produced == 0, stream.pointee.src_size == 0 { failure = .unreadable("truncated compressed data"); return }
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = chunk
            }
        }
        if let failure { throw failure }
        return output
    }
}

/// Little-endian reads that fail instead of trapping when a (possibly hostile) offset is out of range.
private struct ByteReader {
    let data: Data

    private func byte(_ offset: Int) throws -> Int {
        guard offset >= 0, offset < data.count else { throw ConnectorError.unreadable("corrupt ZIP archive") }
        return Int(data[data.startIndex + offset])
    }

    func u16(_ offset: Int) throws -> Int { try byte(offset) | byte(offset + 1) << 8 }

    func u32(_ offset: Int) throws -> Int { try byte(offset) | byte(offset + 1) << 8 | byte(offset + 2) << 16 | byte(offset + 3) << 24 }

    func slice(_ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else { throw ConnectorError.unreadable("corrupt ZIP archive") }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
    }
}
