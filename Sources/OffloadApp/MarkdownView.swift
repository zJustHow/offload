import SwiftUI

/// A small Markdown renderer for the subset notes use: headings, bullets, quotes, code, paragraphs,
/// inline styling, and `[[wikilinks]]` that navigate within the knowledge base.
struct MarkdownView: View {
    let text: String
    let openNote: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in row(block) }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "offload-note" { openNote(url.host(percentEncoded: false)?.removingPercentEncoding ?? ""); return .handled }
            return .systemAction
        })
        .textSelection(.enabled)
    }

    private enum Block { case heading(Int, String), bullet(String), quote(String), code(String), paragraph(String), rule }

    private var blocks: [Block] {
        var out: [Block] = []
        var code: [String]?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { continue }
            if line.hasPrefix("### ") { out.append(.heading(3, String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { out.append(.heading(2, String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { out.append(.heading(1, String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { out.append(.bullet(String(line.dropFirst(2)))) }
            else if line.hasPrefix("> ") { out.append(.quote(String(line.dropFirst(2)))) }
            else if line == "---" { out.append(.rule) }
            else { out.append(.paragraph(line)) }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        return out
    }

    @ViewBuilder private func row(_ b: Block) -> some View {
        switch b {
        case .heading(let level, let t): inline(t).font(level == 1 ? .largeTitle.bold() : level == 2 ? .title2.bold() : .headline).padding(.top, level == 1 ? 0 : 6).accessibilityAddTraits(.isHeader)
        case .bullet(let t): HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(.secondary); inline(t) }
        case .quote(let t): HStack(spacing: 10) { Rectangle().fill(.tertiary).frame(width: 3); inline(t).foregroundStyle(.secondary) }
        case .code(let t): Text(t).font(.system(.callout, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .paragraph(let t): inline(t).lineSpacing(3)
        case .rule: Divider()
        }
    }

    private func inline(_ s: String) -> Text {
        // [[Title]] / [[Title|alias]] -> a link this view handles itself.
        var md = s
        if let re = try? NSRegularExpression(pattern: #"\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]+))?\]\]"#) {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let target = ns.substring(with: m.range(at: 1))
                let label = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : target
                let enc = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? target
                md = (md as NSString).replacingCharacters(in: m.range, with: "[\(label)](offload-note://\(enc))")
            }
        }
        let attributed = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(attributed)
    }
}
