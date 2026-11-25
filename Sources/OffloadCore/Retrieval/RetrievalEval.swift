import Foundation

/// Compares retrieval configurations on a labelled corpus.
public struct RetrievalEval {
    public struct Config: Sendable {
        public let label: String
        public let embedder: Embedder?
        public let mode: SearchOptions.Mode
        public let bigrams: Bool
        public init(label: String, embedder: Embedder?, mode: SearchOptions.Mode, bigrams: Bool = true) {
            self.label = label; self.embedder = embedder; self.mode = mode; self.bigrams = bigrams
        }
    }

    public struct Metrics: Sendable {
        public var recallAt3 = 0.0
        public var recallAt5 = 0.0
        public var mrr = 0.0
        public var queries = 0
    }

    public struct Row: Sendable {
        public let label: String
        public let overall: Metrics
        public let byCategory: [EvalCorpus.Category: Metrics]
    }

    public init() {}

    /// Runs every config over the corpus. Documents are indexed once per distinct
    /// (embedder, bigrams) pair and shared between the modes that use them.
    public func run(
        docs: [EvalCorpus.Doc] = EvalCorpus.docs,
        queries: [EvalCorpus.Query] = EvalCorpus.queries,
        configs: [Config]
    ) async throws -> [Row] {
        var cache: [String: (KnowledgeStore, HybridSearcher)] = [:]
        var rows: [Row] = []
        for cfg in configs {
            let key = "\(cfg.embedder?.name ?? "none")|\(cfg.bigrams)"
            let searcher: HybridSearcher
            if let hit = cache[key] { searcher = hit.1 } else {
                let s = try KnowledgeStore(db: Database.inMemory(), tokenizer: LexicalTokenizer(includeCJKBigrams: cfg.bigrams))
                let indexer = Indexer(store: s, embedder: cfg.embedder)
                for d in docs {
                    try s.upsertItem(ItemRecord(
                        id: d.id, bucket: "eval", kind: .file, uri: d.id, title: d.id, itemDate: nil,
                        fingerprint: "1", summary: nil, verdict: .survivor, trust: .saved))
                    try await indexer.indexDocument(itemID: d.id, text: d.text)
                }
                let made = HybridSearcher(store: s, embedder: cfg.embedder)
                cache[key] = (s, made)
                searcher = made
            }

            var overall = Metrics()
            var per: [EvalCorpus.Category: Metrics] = [:]
            for q in queries {
                var opts = SearchOptions()
                opts.mode = cfg.mode
                opts.include = [.chunk]
                opts.limit = 10
                opts.perItemCap = 1
                opts.recencyBoost = nil
                let hits = try await searcher.search(q.text, options: opts)
                let ranked = hits.compactMap(\.itemID)
                let firstRel = ranked.firstIndex(where: q.relevant.contains)
                func add(_ m: inout Metrics) {
                    m.queries += 1
                    if let r = firstRel {
                        if r < 3 { m.recallAt3 += 1 }
                        if r < 5 { m.recallAt5 += 1 }
                        m.mrr += 1.0 / Double(r + 1)
                    }
                }
                add(&overall)
                add(&per[q.category, default: Metrics()])
            }
            func normalize(_ m: Metrics) -> Metrics {
                guard m.queries > 0 else { return m }
                let n = Double(m.queries)
                return Metrics(recallAt3: m.recallAt3 / n, recallAt5: m.recallAt5 / n, mrr: m.mrr / n, queries: m.queries)
            }
            rows.append(Row(label: cfg.label, overall: normalize(overall), byCategory: per.mapValues(normalize)))
        }
        return rows
    }

    /// A plain-text table of overall and per-category MRR / Recall@3.
    public static func format(_ rows: [Row]) -> String {
        let cats = EvalCorpus.Category.allCases
        func pct(_ x: Double) -> String { String(format: "%5.2f", x) }
        var s = "config".padding(toLength: 34, withPad: " ", startingAt: 0) + " | overall MRR  R@3  R@5"
        for c in cats { s += " | " + c.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0) + "MRR  R@3" }
        s += "\n" + String(repeating: "-", count: s.count) + "\n"
        for r in rows {
            s += r.label.padding(toLength: 34, withPad: " ", startingAt: 0)
            s += " | \(pct(r.overall.mrr))        \(pct(r.overall.recallAt3)) \(pct(r.overall.recallAt5))"
            for c in cats {
                let m = r.byCategory[c] ?? Metrics()
                s += " | " + "".padding(toLength: 11, withPad: " ", startingAt: 0) + "\(pct(m.mrr)) \(pct(m.recallAt3))"
            }
            s += "\n"
        }
        return s
    }
}
