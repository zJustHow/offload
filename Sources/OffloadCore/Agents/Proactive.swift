import Foundation

public struct Card: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case reply, followUp, reminder, booking, research }
    public enum Confidence: String, Sendable, Codable { case low, medium, high }
    public var id: String
    public var createdAt: Date
    public var kind: Kind
    public var title: String
    public var why: String
    /// The artifact the user reviews: a draft message, a numbered plan, or a short briefing.
    public var preparedContent: String
    public var sources: [String]
    public var confidence: Confidence
    public var status: String
}

extension KnowledgeStore {
    /// Replaces the previous deck of ready cards with `cards`; dismissed and done cards are kept.
    public func replaceReadyCards(_ cards: [Card]) throws {
        try db.transaction {
            try db.run("DELETE FROM cards WHERE status = 'ready'")
            for c in cards {
                let payload = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
                try db.run("INSERT OR REPLACE INTO cards(id,created_at,kind,title,payload,status) VALUES(?,?,?,?,?,?)",
                    [.text(c.id), .double(Clock.epoch(c.createdAt)), .text(c.kind.rawValue), .text(c.title), .text(payload), .text(c.status)])
            }
        }
    }

    public func cards(status: String = "ready") throws -> [Card] {
        try db.query("SELECT payload FROM cards WHERE status = ? ORDER BY created_at DESC", [.text(status)]) { r in
            try? JSONDecoder().decode(Card.self, from: Data(r.text(0).utf8))
        }.compactMap { $0 }
    }

    public func setCardStatus(id: String, status: String) throws {
        try db.run("UPDATE cards SET status = ? WHERE id = ?", [.text(status), .text(id)])
    }
}

/// Prepares suggestions overnight: things the user probably wants help with, each researched
/// against what is actually known and written up as something to review. Nothing here sends,
/// books or changes anything — a card is only ever a proposal.
///
/// Two passes, as in any careful assistant: first a cheap *judge* over summaries picks candidates
/// (so the expensive step runs on a handful, not everything); then each candidate is *grounded*
/// with a hybrid search of the user's notes and sources, and dropped if the evidence does not
/// support it. "Unverified" is a valid, honest outcome and is shown as low confidence.
public final class ProactivePlanner: @unchecked Sendable {
    private let store: KnowledgeStore
    private let memory: MemoryService
    private let model: LanguageModel
    public var maxCards = 5

    public init(store: KnowledgeStore, memory: MemoryService, model: LanguageModel) {
        self.store = store; self.memory = memory; self.model = model
    }

    public struct Candidate: Sendable, Equatable { var kind: Card.Kind; var title: String; var why: String; var query: String }

    @discardableResult
    public func run(now: Date = Date()) async throws -> [Card] {
        let candidates = try await judge(now: now)
        var cards: [Card] = []
        for c in candidates.prefix(maxCards) {
            if let card = try await prepare(c, now: now) { cards.append(card) }
        }
        try store.replaceReadyCards(cards)
        return cards
    }

    // MARK: Pass 1: judge

    func judge(now: Date) async throws -> [Candidate] {
        let budget = model.capabilities.contextChars
        var context = ""
        if let readme = try? memory.note(path: "README.md") { context += "## About the user\n\(readme.prefix(min(1_500, budget / 8)))\n\n" }
        let recent = try store.db.query(
            """
            SELECT kind, title, summary, item_date FROM items
            WHERE verdict = 'survivor' AND summary IS NOT NULL AND (
                (kind = 'calendar' AND item_date BETWEEN ? AND ?) OR (kind != 'calendar' AND item_date >= ?))
            ORDER BY item_date DESC LIMIT 40
            """, [.double(Clock.epoch(now) - 2 * 86_400), .double(Clock.epoch(now) + 14 * 86_400), .double(Clock.epoch(now) - 7 * 86_400)]
        ) { ($0.text(0), $0.text(1), $0.text(2), $0.optDouble(3).map(Clock.date)) }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        context += "## Recent and upcoming items\n"
        for (kind, title, summary, date) in recent {
            let line = "- [\(kind)] \(title)\(date.map { " (\(f.string(from: $0)))" } ?? ""): \(summary.prefix(300))\n"
            if context.count + line.count > Int(Double(budget) * 0.55) { break }
            context += line
        }
        guard !recent.isEmpty else { return [] }

        let system = """
            You decide what a personal assistant should prepare for the user tonight. Today is \(f.string(from: now)). \
            From the context, pick at most \(maxCards) concrete things the user likely needs help with: replies they owe, \
            commitments or deadlines coming up, renewals or trials about to bill, trips or plans needing a next step. \
            Only choose things the context actually supports; never invent obligations. Prefer time-sensitive items. \
            Reply with ONLY JSON: {"candidates":[{"kind":"reply|followUp|reminder|booking|research","title":"...","why":"one sentence citing the context","query":"words to search the user's notes for the details"}]}
            """
        let raw = try await model.complete(CompletionRequest(messages: [.system(system), .user(context)], temperature: 0.2, maxTokens: 1_200, jsonMode: true))
        return Self.parseCandidates(raw)
    }

    static func parseCandidates(_ raw: String) -> [Candidate] {
        guard let obj = JSONExtract.firstObject(in: raw), let list = obj["candidates"] as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let title = d["title"] as? String, !title.isEmpty, let why = d["why"] as? String else { return nil }
            let kind = Card.Kind(rawValue: d["kind"] as? String ?? "") ?? .research
            return Candidate(kind: kind, title: title, why: why, query: (d["query"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title)
        }
    }

    // MARK: Pass 2: ground and prepare

    func prepare(_ c: Candidate, now: Date) async throws -> Card? {
        var opts = SearchOptions(); opts.limit = 6; opts.perItemCap = 1
        let hits = try await memory.search(c.query + " " + c.title, options: opts)
        let evidence = MemoryService.render(hits, maxChars: max(1_500, model.capabilities.contextChars / 3))
        let system = """
            You prepare one suggestion for the user to review, using ONLY the evidence given. Decide a verdict: \
            "confirmed" (the evidence supports it), "updated" (the evidence changes a detail; use the corrected one), \
            "stale" (the evidence shows it no longer applies) or "unverified" (the evidence is not enough). Then write \
            "prepared_content": for a reply, the exact message to send; for a plan, a short numbered list; otherwise a short \
            briefing. Never invent facts, amounts, dates or recipients; for anything missing write a placeholder like \
            [confirm date]. Reply with ONLY JSON: {"verdict":"...","prepared_content":"...","confidence":"low|medium|high","sources":[evidence numbers]}
            """
        let user = "Suggestion: \(c.title)\nReason: \(c.why)\n\nEvidence:\n\(evidence)"
        let raw = try await model.complete(CompletionRequest(messages: [.system(system), .user(user)], temperature: 0.3, maxTokens: 1_500, jsonMode: true))
        guard let obj = JSONExtract.firstObject(in: raw), let verdict = (obj["verdict"] as? String)?.lowercased(), verdict != "stale",
            let content = (obj["prepared_content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
        else { return nil }
        let numbers = (obj["sources"] as? [Any])?.compactMap { ($0 as? Int) ?? Int("\($0)") } ?? []
        let sources = numbers.compactMap { $0 >= 1 && $0 <= hits.count ? (hits[$0 - 1].notePath ?? hits[$0 - 1].source?.uri) : nil }
        var confidence = Card.Confidence(rawValue: (obj["confidence"] as? String ?? "").lowercased()) ?? .low
        // Unverified, or grounded in nothing at all, can never be presented as confident.
        if verdict == "unverified" || sources.isEmpty { confidence = .low }
        return Card(
            id: Hashing.stableID("card", c.title, "\(Int(now.timeIntervalSince1970 / 86_400))"), createdAt: now, kind: c.kind,
            title: c.title, why: c.why, preparedContent: content, sources: sources, confidence: confidence, status: "ready")
    }
}
