import Foundation

public struct VaultUpdateReport: Sendable {
    public var considered = 0
    public var merged = 0
    public var batches = 0
    public var failedBatches = 0
    public var created = 0
    public var changed = 0
    public var rejected: [String: Int] = [:]
    public var portraitUpdated = false
    public var abortedReason: String?
    public var notesInVault = 0
    /// Items the model neither used nor set aside: offered again next run.
    public var deferred = 0
    /// Items given up on after repeated attempts.
    public var gaveUp = 0
}

/// Turns pending item summaries into knowledge-base edits.
///
/// How it works, and why:
///  * **Edits, not files.** The model proposes `create` / `append` / `rewrite` operations as JSON.
///    Code validates every one (paths, limits, shrink guard, duplicate titles) and applies them to
///    a *staging copy* of the vault; the model never touches the filesystem.
///  * **Retrieval-assisted merging.** For each batch of evidence, the hybrid searcher finds the
///    existing notes most related to it and shows the model their text, so it extends the right
///    note instead of creating a near-duplicate — and this keeps working when the vault is far
///    larger than a prompt.
///  * **Provenance.** Operations cite the evidence numbers they used; the citations are stored in
///    `note_evidence`, linking every note to the source items behind it.
///  * **Atomic and polite.** The live folder is only ever replaced by a single atomic swap, and
///    only if the user did not edit a note while the run was going (fingerprint check). On any
///    failure nothing is marked merged, so the evidence is retried next time.
public final class VaultBuilder: @unchecked Sendable {
    private let store: KnowledgeStore
    private let model: LanguageModel
    private let embedder: Embedder?
    private let workspace: VaultWorkspace
    private let limits: VaultLimits

    public init(store: KnowledgeStore, model: LanguageModel, embedder: Embedder?, workspace: VaultWorkspace, limits: VaultLimits = VaultLimits()) {
        self.store = store; self.model = model; self.embedder = embedder; self.workspace = workspace; self.limits = limits
    }

    public func update(shouldSkip: @Sendable () -> Bool = { false }, progress: (@Sendable (String) -> Void)? = nil) async throws -> VaultUpdateReport {
        var report = VaultUpdateReport()
        let pending = try store.unmergedSurvivors()
        report.considered = pending.count
        guard !pending.isEmpty else { report.notesInVault = try workspace.readAll().count; return report }
        if shouldSkip() { report.abortedReason = "the user is editing the knowledge base"; return report }

        let fingerprintBefore = try workspace.fingerprint()
        let staging = try workspace.makeStaging()
        var keepStaging = false
        defer { if !keepStaging { workspace.discard(staging: staging) } }

        var notes = try workspace.readAll(in: staging)
        let originalNotes = notes

        // A throwaway index over the staged notes, used to find the notes related to each batch.
        let scratch = try KnowledgeStore(db: Database.inMemory(), tokenizer: store.tokenizer)
        let scratchIndexer = Indexer(store: scratch, embedder: embedder)
        for (path, body) in notes { try await scratchIndexer.indexNote(path: path, body: body) }
        try await scratchIndexer.embedPending()
        let searcher = HybridSearcher(store: scratch, embedder: embedder)

        var evidenceByPath: [String: Set<String>] = [:]
        var doneIDs: [String] = []     // used in a note, or explicitly set aside by the model
        var retryIDs: [String] = []    // not accounted for: offered again next time (bounded)
        var changedPaths: [String] = []
        var createdPaths = Set<String>()

        let contextChars = model.capabilities.contextChars
        // Small models lose track of long evidence lists; bound the items per call by context size.
        let maxItems = min(25, max(2, contextChars / 2_500))
        let batches = Self.slice(pending, budget: Int(Double(contextChars) * 0.35), maxItems: maxItems)
        for (n, batch) in batches.enumerated() {
            try Task.checkCancellation()   // staging is discarded by `defer`; nothing is half-applied
            progress?("Updating knowledge: batch \(n + 1) of \(batches.count)")
            report.batches += 1
            let related = try await relatedNotes(for: batch, notes: notes, searcher: searcher)
            let prompt = Self.mergePrompt(batch: batch, notes: notes, related: related, limits: limits, budget: contextChars)

            guard let reply = try await requestOperations(prompt: prompt) else {
                report.failedBatches += 1
                continue  // no accounting at all: a failed call says nothing about these items
            }
            let result = VaultOps.apply(reply.ops, to: &notes, limits: limits)
            for r in result.rejected { report.rejected[r.reason.rawValue, default: 0] += 1 }

            // Which evidence numbers did an *applied* operation actually use?
            var used = Set<Int>()
            for (opIndex, path) in result.effectivePaths {
                let numbers = reply.ops[opIndex].evidence.filter { $0 >= 1 && $0 <= batch.count }
                used.formUnion(numbers)
                evidenceByPath[path, default: []].formUnion(numbers.map { batch[$0 - 1].id })
            }
            let skipped = Set(reply.skipped)
            for (i, item) in batch.enumerated() {
                if used.contains(i + 1) || skipped.contains(i + 1) { doneIDs.append(item.id) } else { retryIDs.append(item.id) }
            }

            for path in result.changedPaths {
                if let body = notes[path] { notes[path] = VaultOps.cleanLinks(in: VaultOps.collapseDuplicates(in: body), existing: notes) }
                if !changedPaths.contains(path) { changedPaths.append(path) }
                if originalNotes[path] == nil { createdPaths.insert(path) }
                try await scratchIndexer.indexNote(path: path, body: notes[path] ?? "")
            }
            try await scratchIndexer.embedPending()
        }

        // The portrait is refreshed only when the vault actually changed (or has none yet).
        let portraitPaths = changedPaths.filter { $0 != "README.md" }
        if (!portraitPaths.isEmpty || notes["README.md"] == nil), notes.keys.contains(where: { $0 != "README.md" }) {
            progress?("Writing the portrait")
            if let portrait = try? await writePortrait(notes: notes) {
                notes["README.md"] = VaultREADME.render(portrait: portrait, notes: notes)
                report.portraitUpdated = true
            } else if let old = notes["README.md"] {
                // Keep the old portrait but regenerate the map so its links stay accurate.
                notes["README.md"] = Self.refreshMap(of: old, notes: notes)
            }
            if notes["README.md"] != nil, !changedPaths.contains("README.md") { changedPaths.append("README.md") }
        }
        report.created = createdPaths.filter { $0 != "README.md" }.count
        report.changed = changedPaths.count

        if !changedPaths.isEmpty {
            // The user may have saved a note while the model was working; never overwrite that.
            if try workspace.fingerprint() != fingerprintBefore {
                report.abortedReason = "a note changed while the update was running; will retry next time"
                return report
            }
            try workspace.write(notes, paths: changedPaths, into: staging)
            try workspace.swap(staging: staging)
            keepStaging = true  // consumed by the swap
            try await syncIndex(evidence: evidenceByPath)
        }

        // Bookkeeping happens only once the outcome is durable.
        try store.markMerged(ids: doneIDs)
        let outcome = try store.recordMergeAttempt(ids: retryIDs)
        report.merged = doneIDs.count + outcome.gaveUp
        report.gaveUp = outcome.gaveUp
        report.deferred = outcome.retry
        report.notesInVault = notes.count
        return report
    }

    /// Rebuilds the notes index from the live folder (also used after the user edits notes).
    public func syncIndex(evidence: [String: Set<String>] = [:]) async throws {
        let indexer = Indexer(store: store, embedder: embedder)
        let live = try workspace.readAll()
        for (path, body) in live { try await indexer.indexNote(path: path, body: body) }
        for stale in try store.notePaths() where live[stale] == nil { try store.deleteNote(path: stale) }
        for (path, ids) in evidence where live[path] != nil { try store.addEvidence(notePath: path, itemIDs: Array(ids)) }
        try await indexer.embedPending()
    }

    // MARK: - Model calls

    private func requestOperations(prompt: String) async throws -> (ops: [VaultOperation], skipped: [Int])? {
        for attempt in 0..<2 {
            let suffix = attempt == 0 ? "" : "\n\nYour previous reply was not valid JSON. Reply with ONLY the JSON object."
            let raw: String
            do {
                raw = try await model.complete(CompletionRequest(
                    messages: [.system(Self.mergeSystemPrompt), .user(prompt + suffix)], temperature: 0.2, maxTokens: 4_000, jsonMode: true))
            } catch { return nil }
            if let reply = VaultOps.parseReply(raw) { return reply }
        }
        return nil
    }

    private func writePortrait(notes: [String: String]) async throws -> String {
        let budget = max(1_500, Int(Double(model.capabilities.contextChars) * 0.5))
        var listing = ""
        for path in notes.keys.sorted() where path != "README.md" {
            let body = notes[path]!
            let entry = "- \(VaultOps.title(of: body, path: path)) (\(path)): \(VaultREADME.firstLine(of: body, limit: 160))\n"
            if listing.count + entry.count > budget { break }
            listing += entry
        }
        let system = """
            You write the opening portrait of a personal knowledge base: a short, factual description \
            of who this person is, for an AI assistant that will read it before anything else. Use \
            ONLY the notes listed. Two to four short paragraphs, plain Markdown, no headings, no \
            lists. Cover: what they do, what they are working on, key people and places, and \
            practical preferences or routines, as far as the notes support. Do not speculate. \
            The notes describe ONE person, the owner; other people they mention (family, colleagues) \
            are not the owner. \
            Write in the language most of the notes are written in.
            """
        let text = try await model.complete(CompletionRequest(
            messages: [.system(system), .user("Notes:\n\(listing)")], temperature: 0.3, maxTokens: 900))
        let portrait = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard portrait.count > 40 else { throw LLMError.badResponse("portrait too short") }
        return portrait
    }

    private func relatedNotes(for batch: [ItemRecord], notes: [String: String], searcher: HybridSearcher) async throws -> [String] {
        guard !notes.isEmpty else { return [] }
        var query = batch.map { "\($0.title). \($0.summary ?? "")" }.joined(separator: " ")
        query = String(query.prefix(1_500))
        var opts = SearchOptions()
        opts.include = [.note]
        opts.limit = 5
        opts.provenanceWeight = 0
        let hits = try await searcher.search(query, options: opts)
        return hits.compactMap(\.notePath).filter { $0 != "README.md" }
    }

    // MARK: - Prompts (pure, unit-tested)

    static let mergeSystemPrompt = """
        You maintain a personal knowledge base: a folder of Markdown notes about one person's life \
        and work. It is read mostly by AI assistants that need to understand this person quickly, so \
        notes must be specific, factual and well organized.

        You receive: the paths of all existing notes, the text of the notes most related to the new \
        material, and NEW EVIDENCE: short summaries of items from the person's computer. Each \
        evidence item has a trust tag:
        - AUTHORED: the person's own writing. Reliable.
        - CORRESPONDENCE: email or chat. Reliable for what was agreed; be careful attributing \
        other people's statements to the person.
        - SCHEDULE: a calendar snapshot. Not proof of attendance; keep dates as stated.
        - SAVED: material the person kept but did not write. Often about other people, products \
        or topics. Never present it as the person's own life.

        Rules:
        - Record only what the evidence supports. When unsure, leave it out: a missing fact is \
        better than a wrong one.
        - Prefer extending an existing note over creating a new one. Create a note only for a \
        distinct person, project, place, topic or recurring commitment. Merge duplicates. Every \
        sentence must carry information.
        - Keep relative dates as written ("yesterday"); never compute calendar dates.
        - Account for EVERY evidence item: either cite it in an operation, or list its number under \
        "skipped" when it adds nothing durable (promotions, duplicates, trivia).
        - Note format: first line "# Title", then Markdown. Link related notes as [[Exact Title]], \
        only to notes that exist or that you create in this reply. No YAML front matter.
        - Paths look like "Folder/Note title.md" (one to three folder levels). Never use README.md.
        - Write each note in the language most of its evidence is written in.

        Reply with ONLY a JSON object:
        {"operations": [
          {"op": "create",  "path": "Work/Acme/Fundraising.md", "content": "# Fundraising\\n...", "evidence": [1, 3]},
          {"op": "append",  "path": "Home/Apartment.md", "content": "Markdown to add at the end", "evidence": [2]},
          {"op": "rewrite", "path": "People/Priya.md", "content": "complete new note text", "evidence": [4]}
        ], "skipped": [5]}
        "evidence" lists the evidence numbers you used; "skipped" lists numbers you deliberately did not use.
        Every evidence number must appear in "evidence" or in "skipped".
        """

    static func mergePrompt(batch: [ItemRecord], notes: [String: String], related: [String], limits: VaultLimits, budget: Int) -> String {
        var out = "The knowledge base has \(notes.count) notes (limit \(limits.maxNotes)).\n"

        // Paths first: names are the index, so the model can see the whole shape cheaply.
        let pathBudget = Int(Double(budget) * 0.12)
        var paths = ""
        for p in notes.keys.sorted() where p != "README.md" {
            if paths.count + p.count + 1 > pathBudget { paths += "... (\(notes.count) notes in total)\n"; break }
            paths += p + "\n"
        }
        out += "\n## Existing notes\n" + (paths.isEmpty ? "(none yet)\n" : paths)

        let relatedBudget = Int(Double(budget) * 0.22)
        if !related.isEmpty {
            out += "\n## Most related existing notes (text may be truncated)\n"
            var used = 0
            for p in related {
                guard let body = notes[p] else { continue }
                let share = max(300, (relatedBudget - used) / max(1, related.count))
                let clip = body.count > share ? String(body.prefix(share)) + "\n[...]" : body
                out += "\n### \(p)\n\(clip)\n"
                used += clip.count
                if used >= relatedBudget { break }
            }
        }

        out += "\n## NEW EVIDENCE\n"
        for (i, item) in batch.enumerated() { out += render(item, number: i + 1) }
        return out
    }

    static func render(_ item: ItemRecord, number: Int) -> String {
        let tag: String
        switch item.trust {
        case .authored: tag = "AUTHORED"
        case .correspondence: tag = "CORRESPONDENCE"
        case .schedule: tag = "SCHEDULE"
        case .saved: tag = "SAVED"
        }
        // A file's date is when it was last modified, not when anything in it happened; labelling
        // it keeps models from reading "2026-11-25" as an event date.
        var date = ""
        if let d = item.itemDate {
            let isFile = item.kind == .file || item.kind == .image || item.kind == .note
            date = " · " + (isFile ? "file modified " : "") + isoDay.string(from: d)
        }
        return "#\(number) [\(tag)] \(item.kind.rawValue) · \(item.title)\(date)\n\((item.summary ?? "").prefix(900))\n\n"
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// Groups items into prompts without splitting an item across two of them. Items keep their
    /// order (newest first), so a budget overrun in a later pass only delays the oldest material.
    static func slice(_ items: [ItemRecord], budget: Int, maxItems: Int = .max) -> [[ItemRecord]] {
        let budget = max(budget, 1_200)
        var batches: [[ItemRecord]] = []
        var current: [ItemRecord] = []
        var size = 0
        for item in items {
            let cost = render(item, number: current.count + 1).count
            if (size + cost > budget || current.count >= maxItems), !current.isEmpty { batches.append(current); current = []; size = 0 }
            current.append(item)
            size += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    static func refreshMap(of readme: String, notes: [String: String]) -> String {
        var portrait = readme
        if let r = readme.range(of: "\n## Map") { portrait = String(readme[..<r.lowerBound]) }
        if portrait.hasPrefix("# About") { portrait = String(portrait.dropFirst("# About".count)) }
        return VaultREADME.render(portrait: portrait, notes: notes)
    }
}
