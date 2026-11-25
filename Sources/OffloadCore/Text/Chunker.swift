import Foundation

public struct TextChunk: Sendable, Equatable {
    public let ord: Int
    public let text: String
}

/// Splits text into retrieval-sized pieces. Sizes are in characters (not bytes or tokens) because
/// CJK text carries far more meaning per character than Latin text, and a character budget is
/// the one unit that behaves the same for both.
public struct Chunker: Sendable {
    public var targetChars: Int
    public var maxChars: Int
    public var overlapChars: Int

    public init(targetChars: Int = 900, maxChars: Int = 1400, overlapChars: Int = 120) {
        self.targetChars = targetChars
        self.maxChars = max(maxChars, targetChars)
        self.overlapChars = overlapChars
    }

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", ";", "\n"]

    /// Paragraph-aware packing for documents, notes and mail bodies.
    public func chunk(document raw: String) -> [TextChunk] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        if text.count <= maxChars { return [TextChunk(ord: 0, text: text)] }

        // Paragraphs first, then sentences for any paragraph that is itself too long.
        var units: [String] = []
        for para in text.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            if p.count <= maxChars { units.append(p) } else { units.append(contentsOf: splitSentences(p)) }
        }

        var chunks: [String] = []
        var current = ""
        for unit in units {
            if current.isEmpty { current = unit; continue }
            if current.count + 2 + unit.count <= targetChars {
                current += "\n\n" + unit
            } else {
                chunks.append(current)
                current = overlapTail(of: current) + unit
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.enumerated().map { TextChunk(ord: $0.offset, text: $0.element) }
    }

    /// Packs `Name: message` lines into windows, repeating the last two lines of a window at the
    /// start of the next so a reply is never separated from the question it answers.
    public func chunk(conversation lines: [String]) -> [TextChunk] {
        var windows: [[String]] = []
        var current: [String] = []
        var size = 0
        var fresh = 0  // lines in `current` that no earlier window already contains
        for line in lines {
            let l = line.count > maxChars ? String(line.prefix(maxChars)) : line
            if size + l.count + 1 > targetChars, fresh > 0 {
                windows.append(current)
                current = Array(current.suffix(2))
                size = current.reduce(0) { $0 + $1.count + 1 }
                fresh = 0
            }
            current.append(l)
            size += l.count + 1
            fresh += 1
        }
        if fresh > 0 { windows.append(current) }
        return windows.enumerated().map { TextChunk(ord: $0.offset, text: $0.element.joined(separator: "\n")) }
    }

    // MARK: - internals

    private func splitSentences(_ paragraph: String) -> [String] {
        var pieces: [String] = []
        var buf = ""
        for ch in paragraph {
            buf.append(ch)
            if Self.sentenceEnders.contains(ch), buf.count >= 40 {
                pieces.append(buf); buf = ""
            }
            if buf.count >= maxChars { pieces.append(buf); buf = "" }
        }
        if !buf.isEmpty { pieces.append(buf) }
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func overlapTail(of chunk: String) -> String {
        guard overlapChars > 0, chunk.count > overlapChars else { return "" }
        var tail = String(chunk.suffix(overlapChars))
        // Start on a boundary rather than mid-word when the text has spaces.
        if let space = tail.firstIndex(where: { $0 == " " || $0 == "\n" }), tail.distance(from: tail.startIndex, to: space) < overlapChars / 2 {
            tail = String(tail[tail.index(after: space)...])
        }
        return tail + " "
    }
}
