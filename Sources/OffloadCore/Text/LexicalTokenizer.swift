import Foundation
import NaturalLanguage

/// Turns free text into the token stream that the lexical (BM25) index stores and queries.
///
/// SQLite's built-in tokenizers cannot split Chinese/Japanese/Korean into words, and Apple's
/// `NLTokenizer` drops CJK text entirely when it is mixed with Latin text in one string (it picks
/// one dominant language for the whole input). So the text is first cut into *script runs*
/// (CJK vs. alphanumeric), each run is tokenized on its own, and the results are joined with
/// spaces so that FTS5's plain `unicode61` tokenizer only has to split on whitespace.
///
/// CJK character bigrams are optionally added next to the word tokens. Word segmentation is
/// statistical and can disagree between the indexed text and a query ("租房合同" vs "租房" +
/// "合同"); bigrams give the lexical index a segmentation-independent way to match.
public struct LexicalTokenizer: Sendable, Equatable {
    public var includeCJKBigrams: Bool

    public init(includeCJKBigrams: Bool = true) { self.includeCJKBigrams = includeCJKBigrams }

    private enum RunKind { case cjk, word, separator }

    // MARK: - Public API

    /// Tokens for indexing, in order, lowercased. Duplicates are kept (term frequency matters).
    public func tokens(_ text: String) -> [String] {
        var out: [String] = []
        for run in runs(of: text) {
            switch run.kind {
            case .separator: continue
            case .word: out.append(run.text.lowercased())
            case .cjk:
                let words = segmentCJK(run.text)
                out.append(contentsOf: words)
                if includeCJKBigrams { out.append(contentsOf: Self.bigrams(of: run.text)) }
            }
        }
        return out
    }

    /// The string stored in the FTS table's `seg` column.
    public func indexText(_ text: String) -> String { tokens(text).joined(separator: " ") }

    /// Distinct, noise-filtered tokens for a query, in first-seen order.
    public func queryTokens(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for run in runs(of: text) {
            switch run.kind {
            case .separator: continue
            case .word:
                let t = run.text.lowercased()
                if Self.latinStopwords.contains(t) { continue }
                if seen.insert(t).inserted { out.append(t) }
            case .cjk:
                for w in segmentCJK(run.text) where !Self.isCJKStopword(w) {
                    if seen.insert(w).inserted { out.append(w) }
                }
                if includeCJKBigrams {
                    for b in Self.bigrams(of: run.text) where !Self.isCJKStopword(b) {
                        if seen.insert(b).inserted { out.append(b) }
                    }
                }
            }
        }
        return out
    }

    /// Builds a safe FTS5 `MATCH` expression: every token quoted (so operators and punctuation in
    /// user text cannot be parsed as FTS syntax), OR-joined so BM25 ranks by how many terms match.
    public func ftsQuery(_ text: String, maxTerms: Int = 48) -> String? {
        let toks = queryTokens(text).prefix(maxTerms)
        if toks.isEmpty { return nil }
        return toks.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
    }

    // MARK: - Script helpers

    public static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF,  // Han
            0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF,                       // kana
            0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:                       // Hangul
            return true
        default: return false
        }
    }

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        if s == "_" { return true }
        let cat = s.properties.generalCategory
        switch cat {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark:
            return true
        default: return false
        }
    }

    private struct Run { let kind: RunKind; let text: String }

    private func runs(of text: String) -> [Run] {
        var runs: [Run] = []
        var current = String.UnicodeScalarView()
        var currentKind: RunKind = .separator
        func flush() {
            if !current.isEmpty { runs.append(Run(kind: currentKind, text: String(current))) }
            current = String.UnicodeScalarView()
        }
        for s in text.unicodeScalars {
            let kind: RunKind = Self.isCJK(s) ? .cjk : (Self.isWordScalar(s) ? .word : .separator)
            if kind != currentKind { flush(); currentKind = kind }
            if kind != .separator { current.append(s) }
        }
        flush()
        return runs
    }

    private func segmentCJK(_ run: String) -> [String] {
        let language: NLLanguage
        if run.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { language = .japanese }
        else if run.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { language = .korean }
        else { language = .simplifiedChinese }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = run
        tokenizer.setLanguage(language)
        var out: [String] = []
        tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
            out.append(String(run[range]))
            return true
        }
        // If the tokenizer produced nothing usable, fall back to single characters.
        return out.isEmpty ? run.map(String.init) : out
    }

    static func bigrams(of run: String) -> [String] {
        let chars = Array(run)
        guard chars.count >= 2 else { return [] }
        return (0..<(chars.count - 1)).map { String(chars[$0]) + String(chars[$0 + 1]) }
    }

    // MARK: - Stopwords

    private static let cjkStop: Set<Character> = Set("的了在和是我你他她它们这那有就也都要会与及或吗呢吧啊着过到把被对从为以其之而但并很更最不没一个上下里中来去说能可还又只才请问什么怎么哪些多少如何")
    static func isCJKStopword(_ token: String) -> Bool {
        // Noise only when *every* character is a function word (single chars, or bigrams such as
        // "的了"). A word that merely contains one, like "会议", must survive.
        !token.isEmpty && token.allSatisfy { cjkStop.contains($0) }
    }

    private static let latinStopwords: Set<String> = [
        "the", "a", "an", "of", "to", "in", "on", "at", "for", "and", "or", "is", "are", "was", "were",
        "be", "been", "what", "which", "who", "whom", "how", "when", "where", "why", "did", "do", "does",
        "my", "me", "i", "you", "your", "it", "its", "this", "that", "these", "those", "with", "about",
        "from", "by", "as", "if", "then", "than", "so", "we", "our", "us", "he", "she", "they", "them",
    ]
}
