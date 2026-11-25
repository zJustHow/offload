import CryptoKit
import Foundation
import Network

// MARK: - Plumbing (injectable so everything below is testable without the network)

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.badResponse("not an HTTP response") }
        return (data, http)
    }
}

public protocol SecretStore: Sendable {
    func get(_ account: String) -> String?
    func set(_ value: String, account: String) throws
    func delete(_ account: String)
}

public struct KeychainSecretStore: SecretStore {
    public init() {}
    public func get(_ account: String) -> String? { Keychain.get(account: account) }
    public func set(_ value: String, account: String) throws { try Keychain.set(value, account: account) }
    public func delete(_ account: String) { Keychain.delete(account: account) }
}

public enum GoogleError: Error, CustomStringConvertible {
    case notSignedIn, denied(String), stateMismatch, timedOut, http(Int, String), missingScope(String)
    public var description: String {
        switch self {
        case .notSignedIn: return "not signed in to Google. Run `offload sources google login`."
        case .denied(let m): return "Google sign-in was not completed: \(m)"
        case .stateMismatch: return "Google sign-in response did not match the request (possible forgery); aborted."
        case .timedOut: return "Google sign-in timed out."
        case .http(let code, let m): return "Google API error \(code): \(m)"
        case .missingScope(let s): return "this Google sign-in does not include \(s); sign in again and allow it."
        }
    }
}

public struct GoogleCredentials: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String
    public var refreshToken: String
    public var scopes: [String]
}

/// Google sign-in for a *desktop application*: the system browser, a loopback redirect on
/// `127.0.0.1` and PKCE, with read-only scopes. The user supplies their own OAuth client (created
/// in their Google Cloud console) because an app cannot ship a shared one that Google would allow
/// to read arbitrary mailboxes without a security review. Only the refresh token and client
/// credentials are stored, in the Keychain.
public actor GoogleAuth {
    public static let gmailScope = "https://www.googleapis.com/auth/gmail.readonly"
    public static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"
    static let account = "google-oauth"
    static var authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static var tokenEndpoint = "https://oauth2.googleapis.com/token"

    private let transport: HTTPTransport
    private let secrets: SecretStore
    private var cached: (token: String, expires: Date)?

    public init(transport: HTTPTransport = URLSessionTransport(), secrets: SecretStore = KeychainSecretStore()) {
        self.transport = transport; self.secrets = secrets
    }

    public func credentials() -> GoogleCredentials? {
        secrets.get(Self.account).flatMap { try? JSONDecoder().decode(GoogleCredentials.self, from: Data($0.utf8)) }
    }

    public func hasScope(_ scope: String) -> Bool { credentials()?.scopes.contains(scope) ?? false }

    public func signOut() { secrets.delete(Self.account); cached = nil }

    /// A valid access token, refreshing it (once per hour or so) from the stored refresh token.
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let c = cached, c.expires > Date().addingTimeInterval(60) { return c.token }
        guard let creds = credentials() else { throw GoogleError.notSignedIn }
        let json = try await tokenRequest([
            "client_id": creds.clientID, "client_secret": creds.clientSecret,
            "refresh_token": creds.refreshToken, "grant_type": "refresh_token",
        ])
        guard let token = json["access_token"] as? String else { throw GoogleError.denied("no access token in the refresh response") }
        cached = (token, Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3_000)))
        return token
    }

    /// Opens Google's consent page via `openURL`, waits for the redirect, and stores the result.
    public func signIn(
        clientID: String, clientSecret: String, scopes: [String],
        openURL: @Sendable (URL) -> Void, timeout: TimeInterval = 180
    ) async throws {
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        let redirect = "http://127.0.0.1:\(receiver.port)"
        let verifier = Self.randomURLSafe(48)
        let state = Self.randomURLSafe(24)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var comps = URLComponents(string: Self.authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state), .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        openURL(comps.url!)
        let params = try await receiver.waitForCallback(timeout: timeout)

        if let error = params["error"] { throw GoogleError.denied(error) }
        guard params["state"] == state else { throw GoogleError.stateMismatch }
        guard let code = params["code"] else { throw GoogleError.denied("no authorization code") }
        let json = try await tokenRequest([
            "code": code, "client_id": clientID, "client_secret": clientSecret, "redirect_uri": redirect,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String else { throw GoogleError.denied("Google did not return a refresh token") }
        let granted = (json["scope"] as? String)?.split(separator: " ").map(String.init) ?? scopes
        let creds = GoogleCredentials(clientID: clientID, clientSecret: clientSecret, refreshToken: refresh, scopes: granted)
        try secrets.set(String(decoding: try JSONEncoder().encode(creds), as: UTF8.self), account: Self.account)
        if let token = json["access_token"] as? String { cached = (token, Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3_000))) }
    }

    // MARK: internals

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }.joined(separator: "&").utf8)
        let (data, resp) = try await transport.send(req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard resp.statusCode == 200 else {
            let msg = (obj["error_description"] as? String) ?? (obj["error"] as? String) ?? "HTTP \(resp.statusCode)"
            if (obj["error"] as? String) == "invalid_grant" { cached = nil; throw GoogleError.denied("the Google sign-in expired or was revoked; sign in again (\(msg))") }
            throw GoogleError.http(resp.statusCode, msg)
        }
        return obj
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    static func base64URL(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes, &b) == errSecSuccess, "no secure randomness available")
        return base64URL(Data(b))
    }
}

/// A one-shot HTTP listener bound to the loopback interface only. It answers the browser's redirect
/// with a small page and hands the query parameters back; anything else gets a 404.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> LoopbackReceiver {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let receiver = LoopbackReceiver(listener: listener)
        listener.newConnectionHandler = { receiver.handle($0) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceBox()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { receiver.port = listener.port?.rawValue ?? 0; cont.resume() }
                case .failed(let e): if once.take() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return receiver
    }

    func stop() { listener.cancel() }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await self.nextResult() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); throw GoogleError.timedOut }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Cancellation-aware: a child task parked on a plain continuation can never be cancelled, and a
    /// task group does not return until every child has finished, so a timeout would hang forever.
    private func nextResult() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let r = result { lock.unlock(); cont.resume(with: r) }
                else if Task.isCancelled { lock.unlock(); cont.resume(throwing: CancellationError()) }
                else { continuation = cont; lock.unlock() }
            }
        } onCancel: {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(throwing: CancellationError())
        }
    }

    private func deliver(_ params: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return }
        result = .success(params)
        continuation?.resume(returning: params); continuation = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first else { conn.cancel(); return }
            // "GET /?code=...&state=... HTTP/1.1"
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
            let params = Dictionary(items.compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
            let relevant = params["code"] != nil || params["error"] != nil
            let body = relevant ? "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>Connected</h2><p>You can close this tab and return to Offload.</p></body></html>" : "Not found"
            let response = "HTTP/1.1 \(relevant ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if relevant { self.deliver(params) }
        }
    }

    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock(); private var taken = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if taken { return false }; taken = true; return true }
    }
}
