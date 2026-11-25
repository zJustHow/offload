import CryptoKit
import XCTest
@testable import OffloadCore

/// Canned Google: routes by URL, records every request.
final class StubGoogle: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var routes: [(match: (URLRequest) -> Bool, respond: (URLRequest) -> (Int, Any))] = []
    func on(_ contains: String, _ respond: @escaping (URLRequest) -> (Int, Any)) { routes.append(({ $0.url!.absoluteString.contains(contains) }, respond)) }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        for r in routes where r.match(request) {
            let (code, body) = r.respond(request)
            let data = (body as? Data) ?? (try! JSONSerialization.data(withJSONObject: body))
            return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
    func count(_ contains: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.url!.absoluteString.contains(contains) }.count }
    func bodies(_ contains: String) -> [String] { requests.filter { $0.url!.absoluteString.contains(contains) }.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } }
}

func b64url(_ s: String) -> String { Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }

final class GoogleTests: XCTestCase {
    func signedIn(_ stub: StubGoogle, scopes: [String] = [GoogleAuth.gmailScope, GoogleAuth.calendarScope]) throws -> GoogleAuth {
        let secrets = MemorySecretStore()
        let creds = GoogleCredentials(clientID: "cid", clientSecret: "csecret", refreshToken: "rt", scopes: scopes)
        try secrets.set(String(decoding: try JSONEncoder().encode(creds), as: UTF8.self), account: "google-oauth")
        stub.on("oauth2.googleapis.com/token") { _ in (200, ["access_token": "AT-\(UUID().uuidString.prefix(6))", "expires_in": 3600]) }
        return GoogleAuth(transport: stub, secrets: secrets)
    }

    // MARK: OAuth

    func testLoopbackPKCEFlowEndToEnd() async throws {
        let stub = StubGoogle()
        let secrets = MemorySecretStore()
        stub.on("oauth2.googleapis.com/token") { _ in (200, ["access_token": "AT1", "refresh_token": "RT1", "expires_in": 3600, "scope": GoogleAuth.gmailScope]) }
        let auth = GoogleAuth(transport: stub, secrets: secrets)
        let authURL = Box<URL?>(nil)
        try await auth.signIn(clientID: "cid", clientSecret: "csecret", scopes: [GoogleAuth.gmailScope], openURL: { url in
            authURL.mutate { $0 = url }
            // Play the part of the browser: follow Google's redirect back to the loopback listener.
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = q.first { $0.name == "redirect_uri" }!.value!, state = q.first { $0.name == "state" }!.value!
            Task { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)/?code=THECODE&state=\(state)")!) }
        }, timeout: 20)

        let url = try XCTUnwrap(authURL.value)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["scope"], GoogleAuth.gmailScope, "read-only scope only")
        XCTAssertTrue(q["redirect_uri"]!.hasPrefix("http://127.0.0.1:"), "loopback redirect, never a public host")
        XCTAssertEqual(q["access_type"], "offline")

        // The verifier sent to the token endpoint must hash to the challenge sent to the browser.
        let form = Dictionary(uniqueKeysWithValues: stub.bodies("token")[0].split(separator: "&").map { kv -> (String, String) in
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init); return (p[0], p[1].removingPercentEncoding ?? p[1]) })
        XCTAssertEqual(form["code"], "THECODE")
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(GoogleAuth.base64URL(Data(SHA256.hash(data: Data(form["code_verifier"]!.utf8)))), q["code_challenge"])

        let storedOpt = await auth.credentials()
        let stored = try XCTUnwrap(storedOpt)
        XCTAssertEqual(stored.refreshToken, "RT1")
        XCTAssertEqual(stored.clientID, "cid")
        let hasGmail = await auth.hasScope(GoogleAuth.gmailScope), hasCal = await auth.hasScope(GoogleAuth.calendarScope)
        XCTAssertTrue(hasGmail); XCTAssertFalse(hasCal)
        await auth.signOut()
        let after = await auth.credentials()
        XCTAssertNil(after)
    }

    func testForgedStateDeniedConsentAndTimeoutAreRejected() async throws {
        func attempt(_ callback: @escaping @Sendable (String, String) -> String, timeout: TimeInterval = 10) async -> Error? {
            let stub = StubGoogle()
            stub.on("token") { _ in (200, ["access_token": "x", "refresh_token": "r"]) }
            do {
                try await GoogleAuth(transport: stub, secrets: MemorySecretStore()).signIn(clientID: "c", clientSecret: "s", scopes: ["x"], openURL: { url in
                    let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                    let redirect = q.first { $0.name == "redirect_uri" }!.value!, state = q.first { $0.name == "state" }!.value!
                    let target = callback(redirect, state)
                    if !target.isEmpty { Task { _ = try? await URLSession.shared.data(from: URL(string: target)!) } }
                }, timeout: timeout)
                return nil
            } catch { return error }
        }
        let forged = await attempt { r, _ in "\(r)/?code=C&state=WRONG" }
        XCTAssertTrue("\(forged!)".contains("forgery") || "\(forged!)".contains("did not match"))
        let denied = await attempt { r, s in "\(r)/?error=access_denied&state=\(s)" }
        XCTAssertTrue("\(denied!)".contains("access_denied"))
        let silent = await attempt({ _, _ in "" }, timeout: 1)
        XCTAssertTrue("\(silent!)".contains("timed out"))
    }

    func testAccessTokenIsCachedRefreshedAndRevocationIsExplained() async throws {
        let stub = StubGoogle()
        let auth = try signedIn(stub)
        let t1 = try await auth.accessToken(), t2 = try await auth.accessToken()
        XCTAssertEqual(t1, t2)
        XCTAssertEqual(stub.count("token"), 1, "cached until shortly before expiry")
        let t3 = try await auth.accessToken(forceRefresh: true)
        XCTAssertNotEqual(t1, t3)
        XCTAssertEqual(stub.bodies("token")[0].contains("grant_type=refresh_token"), true)

        let revoked = StubGoogle()
        let a2 = try signedIn(revoked)
        revoked.routes.removeAll()
        revoked.on("token") { _ in (400, ["error": "invalid_grant", "error_description": "Token has been expired or revoked."]) }
        do { _ = try await a2.accessToken(); XCTFail() } catch { XCTAssertTrue("\(error)".contains("sign in again")) }
        let none = GoogleAuth(transport: stub, secrets: MemorySecretStore())
        do { _ = try await none.accessToken(); XCTFail() } catch { XCTAssertTrue("\(error)".contains("not signed in")) }
    }

    // MARK: Gmail

    func message(_ id: String, internalDate: Int, subject: String) -> [String: Any] {
        ["id": id, "internalDate": String(internalDate), "payload": ["headers": [["name": "Subject", "value": subject]]]]
    }

    func gmailStub(_ stub: StubGoogle, ids: [String]) {
        stub.on("/messages?") { req in
            let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if items.first(where: { $0.name == "pageToken" })?.value == "P2" { return (200, ["messages": ids.dropFirst(2).map { ["id": $0] }]) }
            return (200, ["messages": ids.prefix(2).map { ["id": $0] }, "nextPageToken": ids.count > 2 ? "P2" : nil as Any? ?? NSNull()])
        }
        stub.on("format=metadata") { req in
            let id = req.url!.pathComponents.last!
            return (200, self.message(id, internalDate: 1_700_000_000_000 + (Int(id.dropFirst(1)) ?? 0) * 1000, subject: "Subject \(id)"))
        }
    }

    func testGmailPaginationMetadataCacheAndStableIdentity() async throws {
        let stub = StubGoogle()
        let auth = try signedIn(stub)
        gmailStub(stub, ids: ["m1", "m2", "m3", "m4"])
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("gmail-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let c = GmailConnector(auth: auth, transport: stub, cacheURL: cache)

        let refs = try await c.list()
        XCTAssertEqual(refs.map(\.key), ["m1", "m2", "m3", "m4"], "both pages, in Gmail's own order")
        XCTAssertEqual(refs[0].title, "Subject m1")
        XCTAssertNotNil(refs[0].date)
        XCTAssertEqual(refs[0].fingerprint, "m1", "messages are immutable: the id is the fingerprint")
        XCTAssertEqual(stub.count("format=metadata"), 4)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int, 0o600, "the cache holds mail subjects: owner-only")
        XCTAssertTrue(stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer AT-") == true || $0.url!.host!.contains("oauth2") })

        _ = try await c.list()
        XCTAssertEqual(stub.count("format=metadata"), 4, "the second listing costs no per-message requests")
        let q = stub.requests.first { $0.url!.absoluteString.contains("/messages?") }!.url!.absoluteString.removingPercentEncoding!
        XCTAssertTrue(q.contains("-in:spam") && q.contains("-category:promotions") && q.contains("newer_than:90d"))
    }

    func testGmailRefreshesOnceOn401ButNotForever() async throws {
        let stub = StubGoogle()
        let auth = try signedIn(stub)
        let calls = Box<[String]>([])
        stub.on("/messages?") { req in
            calls.append(req.value(forHTTPHeaderField: "Authorization") ?? "")
            return calls.value.count == 1 ? (401, ["error": ["message": "Invalid Credentials"]]) : (200, ["messages": [] as [Any]])
        }
        let refs = try await GmailConnector(auth: auth, transport: stub).list()
        XCTAssertTrue(refs.isEmpty)
        XCTAssertEqual(calls.value.count, 2)
        XCTAssertNotEqual(calls.value[0], calls.value[1], "the retry used a fresh token")

        let always401 = StubGoogle()
        let a2 = try signedIn(always401)
        always401.on("/messages?") { _ in (401, ["error": ["message": "no"]]) }
        do { _ = try await GmailConnector(auth: a2, transport: always401).list(); XCTFail() } catch { XCTAssertEqual(always401.count("/messages?"), 2) }
    }

    func testGmailScopeAndApiErrorsAreActionable() async throws {
        let stub = StubGoogle()
        let calendarOnly = try signedIn(stub, scopes: [GoogleAuth.calendarScope])
        do { _ = try await GmailConnector(auth: calendarOnly, transport: stub).list(); XCTFail() } catch { XCTAssertTrue("\(error)".contains("does not include Gmail")) }
        let limited = StubGoogle()
        let auth = try signedIn(limited)
        limited.on("/messages?") { _ in (403, ["error": ["message": "Gmail API has not been used in project 1 before or it is disabled."]]) }
        do { _ = try await GmailConnector(auth: auth, transport: limited).list(); XCTFail() } catch { XCTAssertTrue("\(error)".contains("disabled")) }
    }

    func testGmailBodyParsingMultipartHtmlAttachmentsCharsetsAndQuotes() throws {
        let multipart: [String: Any] = ["payload": [
            "mimeType": "multipart/mixed",
            "headers": [["name": "From", "value": "=?UTF-8?Q?Wang_Lei?= <wang@example.com>"], ["name": "To", "value": "me@example.com"], ["name": "Subject", "value": "=?UTF-8?B?" + Data("合同".utf8).base64EncodedString() + "?="]],
            "parts": [
                ["mimeType": "multipart/alternative", "parts": [
                    ["mimeType": "text/plain", "headers": [["name": "Content-Type", "value": "text/plain; charset=\"UTF-8\""]], "body": ["data": b64url("我今天签了合同。\n\n> quoted history\nOn Mon, Mar 2, 2026 at 9:00 AM Bob <b@x.com> wrote:\n> more")]],
                    ["mimeType": "text/html", "body": ["data": b64url("<p>HTML twin must be ignored</p>")]]]],
                ["mimeType": "application/pdf", "filename": "contract.pdf", "body": ["data": b64url("%PDF binary")]],
            ]]]
        let p = try XCTUnwrap(GmailParser.parse(multipart))
        XCTAssertEqual(p.subject, "合同")
        XCTAssertTrue(p.from.contains("Wang Lei"))
        XCTAssertEqual(p.body, "我今天签了合同。")
        let htmlOnly: [String: Any] = ["payload": ["mimeType": "text/html", "headers": [], "body": ["data": b64url("<style>x{}</style><p>Invoice&nbsp;attached</p>")]]]
        XCTAssertEqual(GmailParser.parse(htmlOnly)?.body, "Invoice attached")
        XCTAssertNil(GmailParser.parse(["id": "x"]))
        XCTAssertEqual(GmailParser.decodeBase64URL(b64url("hi?>>"))?.count, 5, "url-safe alphabet and missing padding")
    }

    func testGmailThroughThePipelineDeletesMailThatLeftTheQueryAndKeepsEverythingOnErrors() async throws {
        let stub = StubGoogle()
        let auth = try signedIn(stub)
        let current = Box<[String]>(["m1", "m2"])
        let outage = Box<[String]>([])   // non-empty = Gmail is failing
        stub.on("/messages?") { _ in outage.value.isEmpty ? (200, ["messages": current.value.map { ["id": $0] }]) : (500, ["error": ["message": "backend error"]]) }
        stub.on("format=metadata") { req in (200, self.message(req.url!.pathComponents.last!, internalDate: 1_700_000_000_000, subject: "S")) }
        stub.on("format=full") { req in
            let id = req.url!.pathComponents.last!
            return (200, ["id": id, "payload": ["mimeType": "text/plain", "headers": [["name": "Subject", "value": "Trip \(id)"], ["name": "From", "value": "a@x.com"]], "body": ["data": b64url("Please confirm the hotel booking for Kyoto in April, thanks.")]]])
        }
        let store = try T.store()
        let model = MockModel { _ in ##"{"summary":"The user is arranging a hotel booking in Kyoto.","title":"Kyoto hotel","junk":false,"sensitive":false}"## }
        let pipeline = IngestPipeline(store: store, triager: Triager(model: model), indexer: Indexer(store: store, embedder: HashingEmbedder()))
        let c = GmailConnector(auth: auth, transport: stub)
        let first = try await pipeline.run(connectors: [c])
        XCTAssertEqual(first.survivors, 2)
        let items = try store.items(bucket: "gmail")
        XCTAssertTrue(items.allSatisfy { $0.kind == .mail && $0.trust == .correspondence && $0.itemDate != nil })

        let again = try await pipeline.run(connectors: [c])
        XCTAssertEqual(again.skippedUpToDate, 2)
        XCTAssertEqual(model.requests.count, 2, "mail already read is not sent to the model again")

        current.mutate { $0 = ["m1"] }   // m2 deleted in Gmail
        let removed = try await pipeline.run(connectors: [c])
        XCTAssertEqual(removed.deleted, 1)

        outage.append("down")
        let failed = try await pipeline.run(connectors: [c])
        XCTAssertNotNil(failed.sourceErrors["gmail"])
        XCTAssertEqual(failed.deleted, 0, "a failed listing must never delete what was learned")
        XCTAssertEqual(try store.items(bucket: "gmail").count, 1)
    }

    // MARK: Google Calendar

    func testGoogleCalendarMapsEventsAndSkipsCancelledAndHolidayCalendars() async throws {
        let stub = StubGoogle()
        let auth = try signedIn(stub)
        stub.on("calendarList") { _ in (200, ["items": [["id": "me@x.com", "summary": "Personal"], ["id": "en.usa#holiday@group.v.calendar.google.com", "summary": "US Holidays"]]]) }
        let seenCalendars = Box<[String]>([])
        stub.on("/events") { req in
            seenCalendars.append(req.url!.path)
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(q.first { $0.name == "singleEvents" }?.value, "true")
            if q.first(where: { $0.name == "pageToken" })?.value == "P2" {
                return (200, ["items": [["id": "e3", "summary": "Birthday", "start": ["date": "2026-05-01"], "end": ["date": "2026-05-02"]]]])
            }
            return (200, ["items": [
                ["id": "e1", "summary": "Dentist", "location": "Main St", "start": ["dateTime": "2026-03-04T09:00:00-08:00"], "end": ["dateTime": "2026-03-04T10:00:00-08:00"], "attendees": [["displayName": "Dr. Lee", "email": "lee@clinic.com"], ["email": "front@clinic.com"]]],
                ["id": "e2", "summary": "Cancelled", "status": "cancelled", "start": ["dateTime": "2026-03-05T09:00:00Z"], "end": ["dateTime": "2026-03-05T10:00:00Z"]],
            ], "nextPageToken": "P2"])
        }
        let events = try await GoogleCalendarSource(auth: auth, transport: stub).events(from: Date(timeIntervalSince1970: 0), to: Date())
        XCTAssertEqual(events.map(\.title), ["Dentist", "Birthday"])
        XCTAssertEqual(events[0].attendees, ["Dr. Lee"], "names only; no e-mail addresses reach the model")
        XCTAssertTrue(events[1].isAllDay)
        XCTAssertEqual(events[0].id, "me@x.com|e1")
        XCTAssertFalse(seenCalendars.value.contains { $0.contains("holiday") }, "holiday calendars are not read")
        // A source for each calendar gets its own bucket so they cannot delete each other's items.
        XCTAssertNotEqual(CalendarConnector(source: GoogleCalendarSource(auth: auth, transport: stub), bucket: "calendar:google").bucket, CalendarConnector().bucket)
    }
}
