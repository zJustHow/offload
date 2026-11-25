import Foundation

public struct IngestProgress: Sendable {
    public var bucket: String
    public var done: Int
    public var total: Int
    public var lastTitle: String
    public var lastVerdict: Verdict
}

public struct IngestReport: Sendable, Equatable {
    public var listed = 0
    public var skippedUpToDate = 0
    public var survivors = 0
    public var junk = 0
    public var sensitive = 0
    public var failed = 0
    public var deleted = 0
    public var chunks = 0
    public var timedOutSources: [String] = []
    public var sourceErrors: [String: String] = [:]

    /// Adds another report's counts into this one.
    public mutating func absorb(_ other: IngestReport) {
        listed += other.listed; skippedUpToDate += other.skippedUpToDate; survivors += other.survivors
        junk += other.junk; sensitive += other.sensitive; failed += other.failed; deleted += other.deleted
        chunks += other.chunks
        timedOutSources += other.timedOutSources
        sourceErrors.merge(other.sourceErrors) { $1 }
    }
}

/// Connector -> triage -> (survivors only) redact -> chunk -> index.
///
/// Incremental by construction: every item is identified by `(bucket, key)` and carries a content
/// fingerprint, so a rerun only processes what is new or changed — including *edited* files, which
/// a plain "newest item seen" pointer would miss. Items are handled one at a time because the
/// on-device model is the bottleneck, and each one is committed atomically so an interruption
/// (sleep, quit, crash) loses at most the item in flight.
public final class IngestPipeline: @unchecked Sendable {
    private let store: KnowledgeStore
    private let triager: Triager
    private let indexer: Indexer

    public init(store: KnowledgeStore, triager: Triager, indexer: Indexer) {
        self.store = store; self.triager = triager; self.indexer = indexer
    }

    public func run(
        connectors: [Connector],
        perSourceBudget: TimeInterval = 3_600,
        loadTimeout: TimeInterval = 30,
        maxItemsPerSource: Int? = nil,
        progress: (@Sendable (IngestProgress) -> Void)? = nil
    ) async throws -> IngestReport {
        var report = IngestReport()
        for connector in connectors {
            if Task.isCancelled { break }
            try await runOne(connector, into: &report, budget: perSourceBudget, loadTimeout: loadTimeout, maxItems: maxItemsPerSource, progress: progress)
        }
        return report
    }

    private func runOne(
        _ connector: Connector, into report: inout IngestReport, budget: TimeInterval, loadTimeout: TimeInterval,
        maxItems: Int?, progress: (@Sendable (IngestProgress) -> Void)?
    ) async throws {
        let refs: [WorkItemRef]
        do { refs = try await connector.list() } catch {
            // An unreadable source (permission revoked, folder gone) must not look like "the
            // source is empty": that would delete everything previously learned from it.
            report.sourceErrors[connector.bucket] = "\(error)"
            return
        }
        report.listed += refs.count
        let existing = connector.listsAllItems ? try store.items(bucket: connector.bucket) : []
        let completed = try await reconcile(connector, refs: refs, existing: existing, into: &report, budget: budget, loadTimeout: loadTimeout, maxItems: maxItems, progress: progress)
        if completed { try store.markRead(bucket: connector.bucket) }
    }

    /// Applies file-system changes to just these paths, without listing the whole source: a path
    /// that is gone has its items (and their chunks and vectors) deleted, one that is new or
    /// changed is read, triaged and indexed like in a full run. Folders are reconciled as a whole,
    /// so a moved or deleted folder is handled by the one path the file system reports for it.
    public func sync(
        paths: [String], connector: PathScopedConnector, loadTimeout: TimeInterval = 30,
        progress: (@Sendable (IngestProgress) -> Void)? = nil
    ) async throws -> IngestReport {
        var report = IngestReport()
        var refs: [WorkItemRef] = [], existing: [ItemRecord] = []
        for scope in Self.outermost(paths.compactMap(connector.scopedPath(for:))) {
            do { refs += try connector.refs(under: scope) } catch {
                // Same rule as a full run: an unreadable source is an error, never "empty".
                report.sourceErrors[connector.bucket] = "\(error)"
                return report
            }
            existing += try store.items(bucket: connector.bucket, under: scope)
        }
        report.listed = refs.count
        _ = try await reconcile(connector, refs: refs, existing: existing, into: &report, budget: .infinity, loadTimeout: loadTimeout, maxItems: nil, progress: progress)
        return report
    }

    /// Drops duplicates and any path that lies inside another path of the set.
    static func outermost(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths)).sorted()
        return unique.filter { p in !unique.contains { $0 != p && p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
    }

    /// `existing` is what the store holds for the part of the source that `refs` covers: anything in
    /// it that `refs` no longer lists is deleted; whatever in `refs` is new or changed is processed.
    /// Returns false when it stopped early (cancelled, out of time, or capped by `maxItems`).
    private func reconcile(
        _ connector: Connector, refs: [WorkItemRef], existing: [ItemRecord], into report: inout IngestReport,
        budget: TimeInterval, loadTimeout: TimeInterval, maxItems: Int?, progress: (@Sendable (IngestProgress) -> Void)?
    ) async throws -> Bool {
        if !existing.isEmpty {
            let present = Set(refs.map { Hashing.stableID(connector.bucket, $0.key) })
            for old in existing where !present.contains(old.id) {
                try store.deleteItem(id: old.id)
                report.deleted += 1
            }
        }

        // Newest first: if the time budget runs out, what is left is the oldest material.
        var pending: [(WorkItemRef, String)] = []
        // Stable by construction: equal (or missing) dates keep the connector's own order, which
        // for sources like Gmail is already newest-first.
        let ordered = refs.enumerated().sorted {
            let a = $0.element.date ?? .distantPast, b = $1.element.date ?? .distantPast
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        for ref in ordered {
            let id = Hashing.stableID(connector.bucket, ref.key)
            if try store.isUpToDate(id: id, fingerprint: ref.fingerprint) { report.skippedUpToDate += 1 } else { pending.append((ref, id)) }
        }
        let capped = maxItems.map { pending.count > $0 } ?? false
        if let maxItems { pending = Array(pending.prefix(maxItems)) }

        let started = Date()
        for (index, (ref, id)) in pending.enumerated() {
            if Task.isCancelled { return false }
            if Date().timeIntervalSince(started) > budget { report.timedOutSources.append(connector.bucket); return false }
            let verdict = try await process(ref, id: id, connector: connector, loadTimeout: loadTimeout, report: &report)
            progress?(IngestProgress(bucket: connector.bucket, done: index + 1, total: pending.count, lastTitle: ref.title, lastVerdict: verdict))
        }
        return !capped
    }

    private func process(
        _ ref: WorkItemRef, id: String, connector: Connector, loadTimeout: TimeInterval, report: inout IngestReport
    ) async throws -> Verdict {
        func record(_ verdict: Verdict, title: String? = nil, summary: String? = nil, reason: String?) -> ItemRecord {
            ItemRecord(
                id: id, bucket: connector.bucket, kind: connector.kind, uri: ref.uri, title: title ?? ref.title,
                itemDate: ref.date, fingerprint: ref.fingerprint, summary: summary, verdict: verdict, reason: reason, trust: ref.trust)
        }

        let content: ItemContent
        do {
            content = try await withTimeout(seconds: loadTimeout) { try await connector.load(ref) }
        } catch {
            // Retryable: the next run will try this item again.
            try store.commitItem(record(.failed, reason: "load: \(error)"), chunkTexts: [])
            report.failed += 1
            return .failed
        }

        let text: String, info: ConversationInfo?
        switch content {
        case .text(let t): text = t; info = nil
        case .conversation(let lines, let i): text = lines.joined(separator: "\n"); info = i
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 12 {
            try store.commitItem(record(.junk, reason: "empty"), chunkTexts: [])
            report.junk += 1
            return .junk
        }

        let outcome = await triager.triage(TriageInput(
            kind: connector.kind, trust: ref.trust, title: ref.title, location: ref.uri, date: ref.date, text: text, conversation: info))

        switch outcome.verdict {
        case .survivor:
            let texts: [String]
            switch content {
            case .text(let t): texts = indexer.chunker.chunk(document: PIIScan.redact(t).text).map(\.text)
            case .conversation(let lines, _): texts = indexer.chunker.chunk(conversation: lines.map { PIIScan.redact($0).text }).map(\.text)
            }
            let ids = try store.commitItem(record(.survivor, title: outcome.title, summary: outcome.summary, reason: outcome.reason.rawValue), chunkTexts: texts)
            // Vectors are best-effort; anything that fails is picked up later by `embedPending`.
            _ = try? await indexer.embed(ids: ids, texts: texts)
            report.survivors += 1
            report.chunks += ids.count
        case .junk:
            try store.commitItem(record(.junk, reason: outcome.reason.rawValue), chunkTexts: [])
            report.junk += 1
        case .sensitive:
            try store.commitItem(record(.sensitive, reason: outcome.reason.rawValue), chunkTexts: [])
            report.sensitive += 1
        case .failed:
            try store.commitItem(record(.failed, reason: outcome.detail ?? "model error"), chunkTexts: [])
            report.failed += 1
        }
        return outcome.verdict
    }
}

/// Runs `operation`, throwing if it does not finish in time. (The operation is cancelled, but a
/// blocking call inside it cannot be interrupted — hence the per-item timeout on top of a budget.)
func withTimeout<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ConnectorError.unreadable("timed out after \(Int(seconds))s")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
