import Foundation
import Darwin

/// Reading the web is the one thing here that sends text out of the Mac *because a model asked*, and
/// a page it reads is a way for a stranger to talk to it. So the tools are off unless the user turns
/// them on, ask before every use (the user sees the exact address or query), refuse identifiers in
/// what they send, refuse addresses that lead into the local network, and label everything they return
/// as data.
public struct WebPolicy: Sendable, Equatable {
    /// When non-empty, only these sites (and their subdomains) may be read.
    public var allowedDomains: [String]
    public var blockedDomains: [String]
    public init(allowedDomains: [String] = [], blockedDomains: [String] = []) {
        self.allowedDomains = allowedDomains; self.blockedDomains = blockedDomains
    }
}

public struct WebResponse: Sendable {
    public var url: URL
    public var status: Int
    public var contentType: String
    public var data: Data
}

public protocol WebTransport: Sendable {
    func get(_ url: URL) async throws -> WebResponse
}

public struct WebSearchHit: Sendable, Equatable {
    public var title: String
    public var url: String
    public var snippet: String
}

public protocol WebSearchProvider: Sendable {
    func search(_ query: String) async throws -> [WebSearchHit]
}

public enum WebGuard {
    public typealias Resolver = @Sendable (String) -> [String]

    /// Why this address may not be fetched, or nil when it may.
    public static func rejection(for url: URL, policy: WebPolicy, resolve: Resolver = WebGuard.resolve) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return "only http and https addresses can be read" }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return "the address has no host" }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if url.user != nil || url.password != nil { return "addresses with a login in them are not allowed" }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan") || !host.contains(".") && !host.contains(":") {
            return "that address is on this computer or its local network"
        }
        if let blocked = policy.blockedDomains.first(where: { matches(host, domain: $0) }) { return "\(blocked) is on the blocked list" }
        if !policy.allowedDomains.isEmpty, !policy.allowedDomains.contains(where: { matches(host, domain: $0) }) { return "\(host) is not on the allowed list" }
        // A name can point at a private address; look at what it resolves to.
        let addresses = isLiteralAddress(host) ? [host] : resolve(host)
        if addresses.isEmpty { return "\(host) could not be found" }
        if addresses.contains(where: isPrivate) { return "that address leads into this computer or its local network" }
        return nil
    }

    public static func matches(_ host: String, domain: String) -> Bool {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return !d.isEmpty && (host == d || host.hasSuffix("." + d))
    }

    static func isLiteralAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_aton(host, &v4) != 0 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// Loopback, private, link-local, carrier-grade NAT, multicast and reserved ranges, in any spelling
    /// (`127.1`, `2130706433`, `0x7f000001` all parse as IPv4 here, as they do in a browser).
    public static func isPrivate(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_aton(address, &v4) != 0 { return isPrivateV4(UInt32(bigEndian: v4.s_addr)) }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b.dropLast().allSatisfy({ $0 == 0 }) && (b[15] == 0 || b[15] == 1) { return true }          // :: and ::1
            if b[0] & 0xFE == 0xFC { return true }                                                            // fc00::/7
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }                                           // fe80::/10
            if b[0] == 0xFF { return true }                                                                    // multicast
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {                         // ::ffff:a.b.c.d
                return isPrivateV4(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
            }
            return false
        }
        return true   // not an address at all: refuse rather than guess
    }

    private static func isPrivateV4(_ a: UInt32) -> Bool {
        let first = a >> 24, second = (a >> 16) & 0xFF
        switch first {
        case 0, 10, 127: return true
        case 100: return (64...127).contains(second)
        case 169: return second == 254
        case 172: return (16...31).contains(second)
        case 192: return second == 168 || (second == 0 && (a >> 8) & 0xFF == 0)
        case 198: return second == 18 || second == 19
        case 224...255: return true
        default: return false
        }
    }

    public static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }
        var out: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let n = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(n.pointee.ai_addr, n.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 { out.append(String(cString: buffer)) }
            node = n.pointee.ai_next
        }
        return out
    }
}

/// Fetches over HTTPS or HTTP with a size cap, no cookies, no cache, and the same address checks
/// applied again to every redirect.
public final class URLSessionWebTransport: NSObject, WebTransport, URLSessionTaskDelegate, @unchecked Sendable {
    static let maxBytes = 2_000_000
    private let policy: WebPolicy
    private let session: URLSession

    public init(policy: WebPolicy) {
        self.policy = policy
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        session = URLSession(configuration: config)
    }

    public func get(_ url: URL) async throws -> WebResponse {
        if let why = WebGuard.rejection(for: url, policy: policy) { throw LLMError.unavailable(why) }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) Offload", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain,application/json,application/xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request, delegate: self)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= Self.maxBytes { break }
        }
        let http = response as? HTTPURLResponse
        return WebResponse(url: response.url ?? url, status: http?.statusCode ?? 0, contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "", data: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, WebGuard.rejection(for: next, policy: policy) == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}

public enum WebTools {
    public static func make(policy: WebPolicy, transport: WebTransport? = nil, search: WebSearchProvider? = nil, resolve: @escaping WebGuard.Resolver = WebGuard.resolve) -> [Tool] {
        let transport = transport ?? URLSessionWebTransport(policy: policy)
        let search = search ?? DuckDuckGoSearch(transport: transport)

        @Sendable func addressProblem(_ s: String?) -> (URL?, String?) {
            guard let s, let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return (nil, "that is not a valid web address") }
            // A card number can hide as `4111%201111%201111%201111`: look at the decoded address too.
            let spellings = [s, s.removingPercentEncoding ?? s, (s.removingPercentEncoding ?? s).replacingOccurrences(of: "+", with: " ")]
            if spellings.contains(where: { !PIIScan.findings(in: $0).isEmpty }) { return (nil, "the address contains something that looks like a personal identifier, so it will not be sent") }
            return (url, WebGuard.rejection(for: url, policy: policy, resolve: resolve))
        }

        let fetch = FunctionTool(ToolSpec(
            name: "web_fetch", description: "read a web page and return its text (http or https only)",
            inputSchema: JSONSchema.object(["url": JSONSchema.string("the page address"), "max_chars": JSONSchema.integer("how much text to return, 500 to 30000", minimum: 500, maximum: 30_000)], required: ["url"]),
            tier: .act, approval: .always, untrusted: true, promptExample: #"{"url": "https://..."}"#
        ), describe: { "Read the web page \($0.string("url") ?? "?")" }, preflight: { a in
            addressProblem(a.string("url")).1.map { "cannot read that page: \($0)" }
        }) { a in
            guard let url = addressProblem(a.string("url")).0 else { return .error("that is not a valid web address") }
            let r = try await transport.get(url)
            guard (200..<300).contains(r.status) else { return .error("the site answered HTTP \(r.status)") }
            return .ok(render(r, limit: a.int("max_chars") ?? 12_000))
        }

        let searchTool = FunctionTool(ToolSpec(
            name: "web_search", description: "search the web and return titles, addresses and short excerpts",
            inputSchema: JSONSchema.object([
                "query": JSONSchema.string(), "allowed_domains": JSONSchema.array(of: JSONSchema.string()), "blocked_domains": JSONSchema.array(of: JSONSchema.string()),
            ], required: ["query"]),
            tier: .act, approval: .always, untrusted: true, promptExample: #"{"query": "..."}"#
        ), describe: { "Search the web for “\($0.string("query") ?? "?")”" }, preflight: { a in
            guard let q = a.string("query"), q.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return "the query is too short" }
            return PIIScan.findings(in: q).isEmpty ? nil : "the query contains something that looks like a personal identifier, so it will not be sent"
        }) { a in
            guard let q = a.string("query") else { return .error("query is required") }
            let extra = WebPolicy(allowedDomains: a.stringArray("allowed_domains") ?? [], blockedDomains: a.stringArray("blocked_domains") ?? [])
            let hits = try await search.search(q).filter { hit in
                guard let host = URL(string: hit.url)?.host?.lowercased() else { return false }
                if (policy.blockedDomains + extra.blockedDomains).contains(where: { WebGuard.matches(host, domain: $0) }) { return false }
                let allowed = policy.allowedDomains + extra.allowedDomains
                return allowed.isEmpty || allowed.contains { WebGuard.matches(host, domain: $0) }
            }
            guard !hits.isEmpty else { return .ok("No results.") }
            return .ok(hits.prefix(8).enumerated().map { "\($0.offset + 1). \($0.element.title)\n   \($0.element.url)\n   \($0.element.snippet)" }.joined(separator: "\n"))
        }
        return [fetch, searchTool]
    }

    static func render(_ r: WebResponse, limit: Int) -> String {
        let type = r.contentType.lowercased()
        let body = String(data: r.data, encoding: .utf8) ?? String(decoding: r.data, as: UTF8.self)
        var title = ""
        let text: String
        if type.contains("html") || (type.isEmpty && body.lowercased().contains("<html")) {
            if let range = body.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) {
                title = HTMLText.strip(String(body[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text = HTMLText.strip(body).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if type.contains("text") || type.contains("json") || type.contains("xml") || type.isEmpty {
            text = body
        } else {
            return "\(r.url.absoluteString)\n[\(r.contentType) content is not shown]"
        }
        let clipped = text.count > limit ? String(text.prefix(limit)) + "\n[text cut at \(limit) characters]" : text
        return (title.isEmpty ? "" : title + "\n") + r.url.absoluteString + "\n\n" + clipped
    }
}

/// Web search through DuckDuckGo's HTML endpoint, which needs no account or key. It is a scraper:
/// if the page layout changes the results come back empty, and it says so rather than guessing.
public struct DuckDuckGoSearch: WebSearchProvider {
    let transport: WebTransport
    public init(transport: WebTransport) { self.transport = transport }

    public func search(_ query: String) async throws -> [WebSearchHit] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let r = try await transport.get(components.url!)
        guard (200..<300).contains(r.status) else { throw LLMError.http(status: r.status, body: "search failed") }
        return Self.parse(String(decoding: r.data, as: UTF8.self))
    }

    static func parse(_ html: String) -> [WebSearchHit] {
        guard let titleRx = try? NSRegularExpression(pattern: #"<a\b[^>]*class="[^"]*result__a[^"]*"[^>]*>([\s\S]*?)</a>"#, options: [.caseInsensitive]),
            let hrefRx = try? NSRegularExpression(pattern: #"href="([^"]+)""#),
            let snippetRx = try? NSRegularExpression(pattern: #"class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)</(?:a|td|div)>"#, options: [.caseInsensitive])
        else { return [] }
        let ns = html as NSString
        let titles = titleRx.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var hits: [WebSearchHit] = []
        for (i, m) in titles.enumerated() {
            let tag = ns.substring(with: m.range)
            guard let h = hrefRx.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
                let url = target(of: (tag as NSString).substring(with: h.range(at: 1)))
            else { continue }
            let end = i + 1 < titles.count ? titles[i + 1].range.location : ns.length
            let window = NSRange(location: m.range.location + m.range.length, length: max(0, end - m.range.location - m.range.length))
            var snippet = ""
            if let s = snippetRx.firstMatch(in: html, range: window) { snippet = HTMLText.strip(ns.substring(with: s.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines) }
            let title = HTMLText.strip(ns.substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { hits.append(WebSearchHit(title: title, url: url, snippet: snippet)) }
        }
        return hits
    }

    /// DuckDuckGo wraps results in a redirect (`//duckduckgo.com/l/?uddg=<encoded address>`).
    static func target(of href: String) -> String? {
        let decoded = href.replacingOccurrences(of: "&amp;", with: "&")
        let absolute = decoded.hasPrefix("//") ? "https:" + decoded : decoded
        guard let components = URLComponents(string: absolute) else { return nil }
        if let wrapped = components.queryItems?.first(where: { $0.name == "uddg" })?.value { return wrapped }
        guard let scheme = components.scheme, scheme == "http" || scheme == "https", components.host?.hasSuffix("duckduckgo.com") == false else { return nil }
        return absolute
    }
}
