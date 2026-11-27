import OffloadUI
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
        // Plain, semibold headings and relaxed 15-pt body text, as in a ChatGPT answer.
        case .heading(let level, let t): inline(t).font(.system(size: level == 1 ? 28 : level == 2 ? 21 : 17, weight: .semibold)).foregroundStyle(Theme.text).padding(.top, level == 1 ? 0 : 8).accessibilityAddTraits(.isHeader)
        case .bullet(let t): HStack(alignment: .firstTextBaseline, spacing: 10) { Text("•").foregroundStyle(Theme.tertiary); inline(t).font(.system(size: 15)).foregroundStyle(Theme.text).lineSpacing(4) }
        case .quote(let t): HStack(spacing: 12) { Capsule().fill(Theme.borderStrong).frame(width: 3); inline(t).font(.system(size: 15)).foregroundStyle(Theme.secondary).lineSpacing(4) }
        case .code(let t): Text(t).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .paragraph(let t): inline(t).font(.system(size: 15)).foregroundStyle(Theme.text).lineSpacing(5)
        case .rule: Divider().overlay(Theme.border)
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
