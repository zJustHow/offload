import Foundation

/// How a Google call reacts to a per-minute quota error: wait, then try again, up to `maxRetries`
/// times. This is Google's own advice (truncated exponential backoff). The wait is shared: while
/// one request is backing off, every other request on the same connector waits too, so six
/// concurrent workers do not all retry at the same instant.
public struct GoogleRetryPolicy: Sendable {
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitter: TimeInterval
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        maxRetries: Int = 6, baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 32, jitter: TimeInterval = 1,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.maxRetries = maxRetries; self.baseDelay = baseDelay; self.maxDelay = maxDelay; self.jitter = jitter; self.sleep = sleep
    }

    /// 2, 4, 8, 16, 32, 32 seconds by default (about a minute and a half in all), which outlasts
    /// the one-minute quota window. A `Retry-After` from Google wins when it asks for longer.
    func delay(retry n: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let backoff = min(baseDelay * pow(2, Double(n)), maxDelay) + Double.random(in: 0...max(0, jitter))
        return max(backoff, min(retryAfter ?? 0, 120))
    }

    public static let standard = GoogleRetryPolicy()
}

/// The time before which no request on this connector should start (set when Google says "slow down").
actor RateGate {
    private var resumeAt = Date.distantPast
    func pause(for seconds: TimeInterval) { resumeAt = max(resumeAt, Date().addingTimeInterval(seconds)) }
    func remaining() -> TimeInterval { max(0, resumeAt.timeIntervalSinceNow) }
}

/// Shared Google REST plumbing: bearer auth, one automatic refresh on 401, back-off on quota
/// errors, readable errors.
struct GoogleAPI {
    let auth: GoogleAuth
    let transport: HTTPTransport
    let retry: GoogleRetryPolicy
    private let gate = RateGate()

    init(auth: GoogleAuth, transport: HTTPTransport, retry: GoogleRetryPolicy = .standard) {
        self.auth = auth; self.transport = transport; self.retry = retry
    }

    func get(_ url: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var comps = URLComponents(string: url)!
        if !query.isEmpty { comps.queryItems = query }
        var forceRefresh = false, refreshedOnce = false   // one forced token refresh per call
        var retries = 0                                   // quota back-offs so far
        while true {
            let wait = await gate.remaining()
            if wait > 0 { try await retry.sleep(wait) }
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(try await auth.accessToken(forceRefresh: forceRefresh))", forHTTPHeaderField: "Authorization")
            forceRefresh = false
            let (data, resp) = try await transport.send(req)
            if resp.statusCode == 401, !refreshedOnce { refreshedOnce = true; forceRefresh = true; continue }   // expired token: refresh once and retry
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if resp.statusCode == 200 { return obj }
            let error = obj["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? "HTTP \(resp.statusCode)"
            if resp.statusCode == 404 { throw ConnectorError.unreadable("not found") }
            if Self.isRateLimited(status: resp.statusCode, error: error, message: message) {
                guard retries < retry.maxRetries else {
                    throw GoogleError.http(resp.statusCode, message + " (Google's per-minute quota; still limited after \(retries) retries. Try again in a minute.)")
                }
                let retryAfter = resp.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                await gate.pause(for: retry.delay(retry: retries, retryAfter: retryAfter))
                retries += 1
                continue
            }
            if resp.statusCode == 403 { throw GoogleError.http(403, message + " (a disabled API or a missing permission)") }
            throw GoogleError.http(resp.statusCode, message)
        }
    }

    /// A quota error that waiting fixes: HTTP 429, or a 403 that names a rate limit or a per-minute
    /// quota. A disabled API, a missing permission or a *daily* limit is a 403 too, and waiting a
    /// few seconds would not help, so those are reported at once.
    static func isRateLimited(status: Int, error: [String: Any]?, message: String) -> Bool {
        if status == 429 { return true }
        guard status == 403 else { return false }
        let reasons = ((error?["errors"] as? [[String: Any]]) ?? []).compactMap { ($0["reason"] as? String)?.lowercased() }
        if reasons.contains(where: { $0 == "ratelimitexceeded" || $0 == "userratelimitexceeded" }) { return true }
        let details = ((error?["details"] as? [[String: Any]]) ?? []).compactMap { ($0["reason"] as? String)?.lowercased() }
        if details.contains("rate_limit_exceeded") { return true }
        let m = message.lowercased()
        return m.contains("rate limit") || m.contains("per minute")
    }
}

/// Reads Gmail through the Gmail REST API with the read-only scope. Raw mail is fetched to this Mac
/// and triaged by the local model like any other source; nothing is sent to a third party.
///
/// `list()` is cheap after the first run: message ids come from one query, and a message's date and
/// subject (needed to order work newest-first) are fetched only for ids not seen before, then
/// cached on disk. A message never changes once delivered, so its id doubles as its fingerprint.
public struct GmailConnector: Connector {
    public let kind: SourceKind = .mail
    public let bucket = "gmail"
    public let listsAllItems = true
    public var query = "newer_than:90d -in:spam -in:trash -in:drafts -category:promotions -category:social -category:forums"
    public var maxMessages = 400
    public var maxBodyChars = 8_000
    public var metadataConcurrency = 6
    let api: GoogleAPI
    let cacheURL: URL?
    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    public init(auth: GoogleAuth, transport: HTTPTransport = URLSessionTransport(), cacheURL: URL? = nil, retry: GoogleRetryPolicy = .standard) {
        self.api = GoogleAPI(auth: auth, transport: transport, retry: retry); self.cacheURL = cacheURL
    }

    struct Meta: Codable { var date: Double; var subject: String }

    /// Collects metadata as it arrives, so a failure part-way keeps what was already fetched.
    actor MetadataCollector {
        private(set) var found: [String: Meta] = [:]
        private(set) var gone: Set<String> = []
        func add(_ id: String, _ meta: Meta) { found[id] = meta }
        func markGone(_ id: String) { gone.insert(id) }
    }

    public func list() async throws -> [WorkItemRef] {
        guard await api.auth.hasScope(GoogleAuth.gmailScope) else { throw GoogleError.missingScope("Gmail") }
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var q: [URLQueryItem] = [.init(name: "q", value: query), .init(name: "maxResults", value: "100")]
            if let pageToken { q.append(.init(name: "pageToken", value: pageToken)) }
            let page = try await api.get(Self.base + "/messages", query: q)
            ids += (page["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil && ids.count < maxMessages
        ids = Array(ids.prefix(maxMessages))

        var cache = loadCache()
        let missing = ids.filter { cache[$0] == nil }
        let collector = MetadataCollector()
        do {
            try await fetchMetadata(missing, into: collector)
        } catch {
            // Keep what did arrive: the next run only has to fetch the rest, so a quota error on a
            // large mailbox makes progress each time instead of starting over forever.
            for (id, meta) in await collector.found { cache[id] = meta }
            saveCache(cache.filter { ids.contains($0.key) })
            throw error
        }
        for (id, meta) in await collector.found { cache[id] = meta }
        let gone = await collector.gone                         // deleted between the listing and the fetch
        ids = ids.filter { !gone.contains($0) }
        saveCache(cache.filter { ids.contains($0.key) })   // pruned to what still matches the query

        return ids.map { id in
            let m = cache[id]
            return WorkItemRef(
                key: id, fingerprint: id, date: m.map { Date(timeIntervalSince1970: $0.date) },
                title: m?.subject.isEmpty == false ? m!.subject : "(no subject)",
                uri: "https://mail.google.com/mail/u/0/#all/\(id)", trust: .correspondence)
        }
    }

    public func load(_ ref: WorkItemRef) async throws -> ItemContent {
        let msg = try await api.get(Self.base + "/messages/\(ref.key)", query: [.init(name: "format", value: "full")])
        guard let parsed = GmailParser.parse(msg) else { throw ConnectorError.unreadable("could not read this message") }
        let body = String(parsed.body.prefix(maxBodyChars))
        return .text("From: \(parsed.from)\nTo: \(parsed.to)\nSubject: \(parsed.subject)\n\n\(body)")
    }

    // MARK: metadata with bounded concurrency

    private func fetchMetadata(_ ids: [String], into collector: MetadataCollector) async throws {
        var next = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            func launch() {
                guard next < ids.count else { return }
                let id = ids[next]; next += 1
                group.addTask {
                    let q: [URLQueryItem] = [.init(name: "format", value: "metadata"), .init(name: "metadataHeaders", value: "Subject")]
                    do {
                        let m = try await api.get(Self.base + "/messages/\(id)", query: q)
                        let millis = Double(m["internalDate"] as? String ?? "") ?? 0
                        let subject = ((m["payload"] as? [String: Any])?["headers"] as? [[String: Any]])?
                            .first { ($0["name"] as? String)?.lowercased() == "subject" }?["value"] as? String ?? ""
                        await collector.add(id, Meta(date: millis / 1000, subject: EMLXParser.decodeWords(subject)))
                    } catch ConnectorError.unreadable(let why) where why == "not found" {
                        await collector.markGone(id)   // deleted since it was listed: not an error for the rest
                    }
                }
            }
            for _ in 0..<min(metadataConcurrency, ids.count) { launch() }
            while try await group.next() != nil { launch() }
        }
    }

    private func loadCache() -> [String: Meta] {
        guard let url = cacheURL, let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Meta].self, from: d)) ?? [:]
    }
    private func saveCache(_ c: [String: Meta]) {
        guard let url = cacheURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Not `.completeFileProtection`: that class refuses writes while the screen is locked, which
        // is exactly when the nightly run happens, and `try?` would hide the failure. Owner-only
        // permissions plus FileVault protect the file at rest.
        guard let d = try? JSONEncoder().encode(c), (try? d.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

    }
}

/// Turns Gmail's already-structured message payload into text: plain parts preferred, HTML
/// stripped as a fallback, attachments ignored, quoted reply history removed.
enum GmailParser {
    struct Parsed { var from: String; var to: String; var subject: String; var body: String }

    static func parse(_ message: [String: Any]) -> Parsed? {
        guard let payload = message["payload"] as? [String: Any] else { return nil }
        let headers = payload["headers"] as? [[String: Any]] ?? []
        func header(_ n: String) -> String {
            EMLXParser.decodeWords(headers.first { ($0["name"] as? String)?.lowercased() == n }?["value"] as? String ?? "")
        }
        var plain: [String] = [], html: [String] = []
        collect(payload, plain: &plain, html: &html)
        let body = plain.isEmpty ? html.map(HTMLText.strip) : plain
        let text = EMLXParser.stripQuotedReply(body.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines))
        return Parsed(from: header("from"), to: header("to"), subject: header("subject"), body: text)
    }

    private static func collect(_ part: [String: Any], plain: inout [String], html: inout [String]) {
        if let name = part["filename"] as? String, !name.isEmpty { return }   // an attachment
        let mime = (part["mimeType"] as? String ?? "").lowercased()
        if let children = part["parts"] as? [[String: Any]] { for c in children { collect(c, plain: &plain, html: &html) }; return }
        guard let data = (part["body"] as? [String: Any])?["data"] as? String, let bytes = decodeBase64URL(data) else { return }
        let headers = part["headers"] as? [[String: Any]] ?? []
        let contentType = headers.first { ($0["name"] as? String)?.lowercased() == "content-type" }?["value"] as? String ?? ""
        let charset = contentType.range(of: #"charset="?([A-Za-z0-9_\-]+)"#, options: .regularExpression).map {
            String(contentType[$0]).replacingOccurrences(of: "charset=", with: "").replacingOccurrences(of: "\"", with: "")
        }
        let text = EMLXParser.decodeCharset(bytes, charset)
        if mime == "text/plain" { plain.append(text) } else if mime == "text/html" { html.append(text) }
    }

    static func decodeBase64URL(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}
