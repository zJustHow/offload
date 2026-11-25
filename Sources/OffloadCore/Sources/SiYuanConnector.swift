import Foundation

/// Reads a SiYuan (思源笔记) workspace straight from its `data` folder: every document is a `.sy`
/// JSON file, so no running app, API token or network call is involved. Notebooks are the
/// sub-folders named like `20240101120000-abcdefg`; `assets`, `templates`, `plugins` and the like
/// are not notebooks and are skipped.
///
/// The `.sy` node layout used here (`Type`, `Children`, `Data`, `HeadingLevel`, `TextMarkType`,
/// `TextMarkTextContent`, …) follows SiYuan's documented file format but could not be checked
/// against a real workspace when this was written; fixtures follow that format.
public struct SiYuanConnector: Connector {
    public let dataDirectory: URL
    public let kind: SourceKind = .note
    public var bucket: String { "siyuan:" + dataDirectory.path }
    public let listsAllItems = true
    public var maxChars = 60_000

    public init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

    static let notebookName = try! NSRegularExpression(pattern: #"^\d{14}-[a-z0-9]{7}$"#)

    public func list() async throws -> [WorkItemRef] { try scan() }

    func scan() throws -> [WorkItemRef] {
        guard FileManager.default.fileExists(atPath: dataDirectory.path) else { throw ConnectorError.unreadable("SiYuan data folder not found: \(dataDirectory.path)") }
        var refs: [WorkItemRef] = []
        let notebooks = try FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
            .filter { Self.notebookName.firstMatch(in: $0.lastPathComponent, range: NSRange(location: 0, length: $0.lastPathComponent.utf16.count)) != nil }
        for box in notebooks {
            guard let walker = FileManager.default.enumerator(at: box, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "sy" {
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard v?.isRegularFile == true, (v?.fileSize ?? 0) > 0 else { continue }
                refs.append(WorkItemRef(
                    key: url.path, fingerprint: "\(v?.fileSize ?? 0)-\(Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0))",
                    date: v?.contentModificationDate, title: Self.title(of: url), uri: url.path, trust: .authored))
            }
        }
        return refs
    }

    public func load(_ ref: WorkItemRef) async throws -> ItemContent {
        let url = URL(fileURLWithPath: ref.key)
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.unreadable("not a readable SiYuan document")
        }
        // The notebook is the first folder under `data`. (Document folders carry IDs of the same
        // shape as notebook IDs, so "nearest ID-like folder" would pick the wrong one.)
        let relative = url.resolvingSymlinksInPath().path.replacingOccurrences(of: dataDirectory.resolvingSymlinksInPath().path + "/", with: "")
        let box = relative.split(separator: "/").first.map(String.init).flatMap { Self.isNotebookID($0) ? $0 : nil }
        let name = box.flatMap { notebookTitle(dataDirectory.appendingPathComponent($0)) }
        var text = Self.render(root)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "SiYuan" + (name.map { " notebook: \($0)" } ?? "") + "\n# \(ref.title)\n\n"
        return .text(String((header + text).prefix(maxChars)))
    }

    // MARK: Parsing

    static func isNotebookID(_ s: String) -> Bool { notebookName.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil }

    /// The document title lives near the top of the file, so a short read is enough for listing.
    static func title(of url: URL) -> String {
        if let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 4_096), let s = String(data: head, encoding: .utf8),
            let re = try? NSRegularExpression(pattern: #""title"\s*:\s*"((?:[^"\\]|\\.)*)""#),
            let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) {
            let raw = String(s[r])
            if let d = "\"\(raw)\"".data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) as? String, !decoded.isEmpty { return decoded }
            if !raw.isEmpty { return raw }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    func notebookTitle(_ box: URL) -> String? {
        guard let d = try? Data(contentsOf: box.appendingPathComponent(".siyuan/conf.json")), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["name"] as? String
    }

    /// Renders the block tree as readable Markdown-ish text.
    static func render(_ node: [String: Any], depth: Int = 0) -> String {
        let type = node["Type"] as? String ?? ""
        let children = node["Children"] as? [[String: Any]] ?? []
        func inline(_ nodes: [[String: Any]]) -> String { nodes.map(renderInline).joined() }

        switch type {
        case "NodeDocument", "NodeSuperBlock":
            return children.map { render($0, depth: depth) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case "NodeBlockquote":
            return children.map { render($0, depth: depth) }.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        case "NodeHeading":
            let level = max(1, min(6, node["HeadingLevel"] as? Int ?? 1))
            return String(repeating: "#", count: level) + " " + inline(children)
        case "NodeParagraph":
            return inline(children)
        case "NodeList":
            let ordered = ((node["ListData"] as? [String: Any])?["Typ"] as? Int) == 1
            return children.enumerated().map { i, item in
                let marker = ordered ? "\(i + 1). " : "- "
                let body = (item["Children"] as? [[String: Any]] ?? []).map { render($0, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: "\n")
                let indent = String(repeating: "  ", count: depth)
                return indent + marker + body.replacingOccurrences(of: "\n", with: "\n" + indent + "  ")
            }.joined(separator: "\n")
        case "NodeCodeBlock":
            let code = children.first { ($0["Type"] as? String) == "NodeCodeBlockCode" }?["Data"] as? String ?? ""
            return code.isEmpty ? "" : "```\n\(code)\n```"
        case "NodeTable":
            // Rows live either under a NodeTableHead or directly under the table.
            let rows = children.flatMap { child -> [[String: Any]] in
                (child["Type"] as? String) == "NodeTableHead" ? (child["Children"] as? [[String: Any]] ?? []) : [child]
            }
            return rows.map { row in
                (row["Children"] as? [[String: Any]] ?? []).map { inline($0["Children"] as? [[String: Any]] ?? []) }.joined(separator: " | ")
            }.joined(separator: "\n")
        case "NodeThematicBreak": return "---"
        case "NodeKramdownBlockIAL", "NodeBlockQueryEmbed", "NodeWidget", "NodeIFrame", "NodeVideo", "NodeAudio", "NodeAttributeView": return ""
        default:
            if let data = node["Data"] as? String, children.isEmpty, !type.hasSuffix("Marker") { return data }
            return children.map { render($0, depth: depth) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    static func renderInline(_ node: [String: Any]) -> String {
        let type = node["Type"] as? String ?? ""
        switch type {
        case "NodeText": return node["Data"] as? String ?? ""
        case "NodeTextMark":
            let types = (node["TextMarkType"] as? String ?? "").split(separator: " ").map(String.init)
            let content = node["TextMarkTextContent"] as? String ?? ""
            if types.contains("tag") { return "#" + content }
            return content   // links, block references, emphasis: keep the visible text
        case "NodeBr", "NodeSoftBreak": return "\n"
        case "NodeImage", "NodeKramdownSpanIAL", "NodeBlockRef": return ""
        case "NodeInlineMath": return node["Data"] as? String ?? ""
        default:
            if let data = node["Data"] as? String, !type.hasSuffix("Marker") { return data }
            return (node["Children"] as? [[String: Any]] ?? []).map(renderInline).joined()
        }
    }
}
