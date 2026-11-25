import Accelerate
import Foundation
import NaturalLanguage

/// Produces dense vectors for text. An embedder may return `nil` for a text it cannot handle
/// (for example a language it has no model for); such chunks stay searchable lexically.
///
/// Vectors carry a `space` identifier and are only ever compared within the same space. That
/// matters for per-language models: a Chinese vector and an English vector come from unrelated
/// models, so comparing them would be meaningless.
public protocol Embedder: Sendable {
    var name: String { get }
    func embed(_ texts: [String]) async throws -> [EmbeddedVector?]
}

// MARK: - Language detection

public enum TextLanguage {
    /// Picks the language to embed in. `NLLanguageRecognizer` alone is unreliable on mixed
    /// Chinese/English text (it often answers "English" for a Chinese sentence that merely
    /// contains a few English words), so CJK density decides first.
    public static func detect(_ text: String) -> NLLanguage? {
        var cjk = 0, kana = 0, letters = 0
        for s in text.unicodeScalars.prefix(2000) {
            if (0x3040...0x30FF).contains(s.value) { kana += 1; cjk += 1 }
            else if LexicalTokenizer.isCJK(s) { cjk += 1 }
            else if s.properties.isAlphabetic { letters += 1 }
        }
        let total = cjk + letters
        if total == 0 { return nil }
        if Double(cjk) / Double(total) > 0.2 { return kana > 0 ? .japanese : .simplifiedChinese }
        return NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(1000))) ?? .english
    }
}

func l2normalized(_ v: [Float]) -> [Float] {
    var sumSquares: Float = 0
    vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
    guard sumSquares > 0 else { return v }
    var inv = 1 / sumSquares.squareRoot()
    var out = [Float](repeating: 0, count: v.count)
    vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
    return out
}

// MARK: - Apple sentence embeddings (built into macOS, no download)

/// `NLEmbedding.sentenceEmbedding`: one static model per language, fast (a few ms per text) and
/// fully on-device. Quality is modest — similarity scores of related and unrelated sentences sit
/// close together — which is why fusion in this project uses ranks, never raw scores.
public final class AppleSentenceEmbedder: Embedder, @unchecked Sendable {
    public let name = "apple.sentence"
    private var models: [String: NLEmbedding?] = [:]
    private let lock = NSLock()

    public init() {}

    private func model(for language: NLLanguage) -> NLEmbedding? {
        lock.lock(); defer { lock.unlock() }
        if let cached = models[language.rawValue] { return cached }
        let m = NLEmbedding.sentenceEmbedding(for: language)
        models[language.rawValue] = .some(m)
        return m
    }

    public func embed(_ texts: [String]) async throws -> [EmbeddedVector?] {
        texts.map { text in
            guard let lang = TextLanguage.detect(text), let m = model(for: lang),
                let raw = m.vector(for: String(text.prefix(2000)))
            else { return nil }
            return EmbeddedVector(space: "\(name).\(lang.rawValue)", values: l2normalized(raw.map { Float($0) }))
        }
    }
}

// MARK: - Apple contextual (BERT-style) embeddings, mean-pooled

public final class AppleContextualEmbedder: Embedder, @unchecked Sendable {
    public let name = "apple.contextual"
    private var models: [String: NLContextualEmbedding?] = [:]
    private let lock = NSLock()

    public init() {}

    private func model(for language: NLLanguage) -> NLContextualEmbedding? {
        lock.lock(); defer { lock.unlock() }
        if let cached = models[language.rawValue] { return cached }
        var m = NLContextualEmbedding(language: language)
        if let candidate = m {
            if (try? candidate.load()) == nil { m = nil }
        }
        models[language.rawValue] = .some(m)
        return m
    }

    public func embed(_ texts: [String]) async throws -> [EmbeddedVector?] {
        texts.map { full in
            let text = String(full.prefix(1200))
            guard let lang = TextLanguage.detect(text), let m = model(for: lang),
                let result = try? m.embeddingResult(for: text, language: lang)
            else { return nil }
            var sum = [Float](repeating: 0, count: m.dimension)
            var n: Float = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
                for i in 0..<min(vec.count, sum.count) { sum[i] += Float(vec[i]) }
                n += 1
                return true
            }
            guard n > 0 else { return nil }
            return EmbeddedVector(space: "\(name).\(lang.rawValue)", values: l2normalized(sum))
        }
    }
}

// MARK: - OpenAI-compatible HTTP embeddings (OpenAI, Ollama, LM Studio, OpenRouter...)

/// Any endpoint implementing `POST {base}/embeddings`. With a multilingual model (for example
/// bge-m3) this gives a single shared space for every language, so cross-language retrieval
/// (Chinese query, English document) works — something the per-language Apple models cannot do.
public struct OpenAICompatibleEmbedder: Embedder {
    public let name: String
    let baseURL: URL
    let model: String
    let apiKey: String?
    let batchSize: Int

    public init(baseURL: URL, model: String, apiKey: String? = nil, batchSize: Int = 32) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey; self.batchSize = batchSize
        self.name = "oai.\(model)"
    }

    public func embed(_ texts: [String]) async throws -> [EmbeddedVector?] {
        var out: [EmbeddedVector?] = []
        var start = 0
        while start < texts.count {
            let batch = Array(texts[start..<min(start + batchSize, texts.count)])
            var req = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": batch.map { String($0.prefix(6000)) }])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let items = obj["data"] as? [[String: Any]]
            else { throw LLMError.badResponse("embeddings endpoint returned an unexpected response") }
            let sorted = items.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
            for item in sorted {
                guard let arr = item["embedding"] as? [Double] else { out.append(nil); continue }
                out.append(EmbeddedVector(space: name, values: l2normalized(arr.map { Float($0) })))
            }
            start += batch.count
        }
        return out
    }
}

// MARK: - Hashing embedder (dependency-free baseline and test double)

/// Signed feature hashing of word tokens and character trigrams. It has no semantic knowledge —
/// similarity is lexical overlap — but it is deterministic, instant and works for every language,
/// which makes it the fallback when no real embedder is available and the baseline in evals.
public struct HashingEmbedder: Embedder {
    public let name = "hash.v1"
    public let dimension: Int
    private let tokenizer = LexicalTokenizer(includeCJKBigrams: true)

    public init(dimension: Int = 512) { self.dimension = dimension }

    public func embed(_ texts: [String]) async throws -> [EmbeddedVector?] {
        texts.map { text in
            var v = [Float](repeating: 0, count: dimension)
            for tok in tokenizer.tokens(text) {
                add(tok, weight: 1, to: &v)
                if tok.unicodeScalars.allSatisfy({ !LexicalTokenizer.isCJK($0) }), tok.count > 4 {
                    let chars = Array(tok)
                    for i in 0..<(chars.count - 2) { add(String(chars[i..<(i + 3)]), weight: 0.4, to: &v) }
                }
            }
            return EmbeddedVector(space: name, values: l2normalized(v))
        }
    }

    private func add(_ feature: String, weight: Float, to v: inout [Float]) {
        // FNV-1a over UTF-8; the next bit picks the sign so collisions cancel instead of piling up.
        var h: UInt64 = 0xcbf29ce484222325
        for b in feature.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let idx = Int(h % UInt64(dimension))
        v[idx] += ((h >> 40) & 1 == 0 ? 1 : -1) * weight
    }
}
