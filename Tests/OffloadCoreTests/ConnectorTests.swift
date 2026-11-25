import XCTest
@testable import OffloadCore

final class ConnectorTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("offload-conn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: Mail

    func emlx(_ message: String) -> Data {
        let body = message.replacingOccurrences(of: "\n", with: "\r\n")
        return Data("\(body.utf8.count)\n\(body)\n<?xml version=\"1.0\"?><plist></plist>".utf8)
    }

    func testEMLXMultipartQuotedPrintableAndEncodedHeaders() throws {
        let subject = "=?UTF-8?B?" + Data("租房合同的事".utf8).base64EncodedString() + "?="
        let qpBody = "=E6=88=91=E4=BB=8A=E5=A4=A9=E7=AD=BE=E4=BA=86=E5=90=88=E5=90=8C=EF=BC=8C=E6=8A=BC=E9=87=91=\n=E4=B8=A4=E4=B8=AA=E6=9C=88=E3=80=82"
        let msg = """
        From: =?UTF-8?Q?Wang_Lei?= <wang@example.com>
        To: me@example.com
        Subject: \(subject)
        Date: Tue, 3 Mar 2026 10:15:00 +0800
        Message-ID: <abc@example.com>
        Content-Type: multipart/alternative; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        \(qpBody)

        > quoted history that must be dropped
        --BOUND
        Content-Type: text/html; charset=utf-8

        <html><body><p>HTML version should be ignored when plain exists</p></body></html>
        --BOUND--
        """
        let mail = try XCTUnwrap(EMLXParser.parse(emlx(msg)))
        XCTAssertEqual(mail.subject, "租房合同的事")
        XCTAssertTrue(mail.from.contains("Wang Lei"))
        XCTAssertEqual(mail.body, "我今天签了合同，押金两个月。")
        XCTAssertFalse(mail.body.contains("quoted history"))
        XCTAssertFalse(mail.body.contains("HTML version"))
        XCTAssertNotNil(mail.date)
    }

    func testEMLXHtmlOnlyBase64AttachmentsAndReplyTrimming() throws {
        let html = Data("<html><style>x{}</style><body><p>Hello&nbsp;team, the invoice is attached.</p></body></html>".utf8).base64EncodedString()
        let msg = """
        From: a@example.com
        Subject: Invoice
        Content-Type: multipart/mixed; boundary="M"

        --M
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: base64

        \(html)
        --M
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="inv.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --M--
        """
        let mail = try XCTUnwrap(EMLXParser.parse(emlx(msg)))
        XCTAssertEqual(mail.body, "Hello team, the invoice is attached.")

        let reply = "Sounds good, see you Tuesday.\n\nOn Mon, Mar 2, 2026 at 9:00 AM Bob <bob@example.com> wrote:\n> earlier text\n> more"
        XCTAssertEqual(EMLXParser.stripQuotedReply(reply), "Sounds good, see you Tuesday.")
        XCTAssertEqual(EMLXParser.stripQuotedReply("好的,周二见。\n\n王磊 写道:\n> 之前的内容"), "好的,周二见。")
    }

    func testEMLXLegacyCharsetAndGarbageInput() throws {
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding("gbk" as CFString)))
        var raw = Data("From: a@x.com\nSubject: t\nContent-Type: text/plain; charset=gbk\n\n".utf8)
        raw.append("你好,世界".data(using: gbk)!)
        XCTAssertEqual(EMLXParser.parseRFC822(raw)?.body, "你好,世界")
        XCTAssertNil(EMLXParser.parse(Data("not an email at all".utf8)))
    }

    func testMailConnectorFiltersMailboxesPartialsAndLoadsText() async throws {
        func put(_ rel: String, subject: String) throws {
            let url = tmp.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try emlx("From: a@x.com\nSubject: \(subject)\nDate: Tue, 3 Mar 2026 10:15:00 +0000\nContent-Type: text/plain\n\nBody of \(subject)").write(to: url)
        }
        try put("V10/acct/INBOX.mbox/uuid/Data/Messages/1.emlx", subject: "Real mail")
        try put("V10/acct/Junk.mbox/uuid/Data/Messages/2.emlx", subject: "Junk mail")
        try put("V10/acct/Trash.mbox/uuid/Data/Messages/3.emlx", subject: "Trashed")
        try put("V10/acct/INBOX.mbox/uuid/Data/Messages/4.partial.emlx", subject: "Not downloaded")
        let c = MailConnector(root: tmp)
        let refs = try await c.list()
        XCTAssertEqual(refs.map(\.title), ["Real mail"])
        XCTAssertEqual(refs[0].trust, .correspondence)
        guard case .text(let t) = try await c.load(refs[0]) else { return XCTFail() }
        XCTAssertTrue(t.contains("Subject: Real mail"))
        XCTAssertTrue(t.contains("Body of Real mail"))
    }

    // MARK: Chat windows & typedstream

    func testChatWindowingSplitsOnSilenceAndSizeAndClipsLongMessages() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var lines: [ChatLine] = []
        for i in 0..<4 { lines.append(ChatLine(rowID: Int64(i), date: t0.addingTimeInterval(Double(i) * 60), sender: "Me", text: "msg \(i)")) }
        lines.append(ChatLine(rowID: 10, date: t0.addingTimeInterval(86_400), sender: "Them", text: String(repeating: "x", count: 5_000)))
        let w = ChatWindowing.windows(lines, maxChars: 4_000, gap: 8 * 3_600, maxMessageChars: 600)
        XCTAssertEqual(w.count, 2, "a day of silence starts a new window")
        XCTAssertLessThan(w[1][0].text.count, 700, "huge messages are clipped")
        let big = (0..<30).map { ChatLine(rowID: Int64($0), date: t0.addingTimeInterval(Double($0)), sender: "Me", text: String(repeating: "y", count: 300)) }
        XCTAssertGreaterThan(ChatWindowing.windows(big, maxChars: 2_000).count, 3)
        XCTAssertEqual(ChatWindowing.render([lines[0]]), ["Me: msg 0"])
    }

    func typedStream(_ text: String) -> Data {
        var d = Data("streamtyped".utf8) + Data([0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]) + Data("NSMutableAttributedString".utf8)
        d += Data([0x00, 0x84, 0x84]) + Data("NSString".utf8) + Data([0x01, 0x94, 0x84, 0x01, 0x2B])
        let n = text.utf8.count
        if n < 0x80 { d.append(UInt8(n)) } else { d += Data([0x81, UInt8(n & 0xFF), UInt8(n >> 8)]) }
        return d + Data(text.utf8) + Data([0x86, 0x84, 0x02])
    }

    func testTypedStreamExtraction() {
        XCTAssertEqual(TypedStream.extractText(from: typedStream("hello there")), "hello there")
        XCTAssertEqual(TypedStream.extractText(from: typedStream("你好,明天见")), "你好,明天见")
        let long = String(repeating: "abcdefghij", count: 40)
        XCTAssertEqual(TypedStream.extractText(from: typedStream(long)), long, "two-byte lengths")
        XCTAssertNil(TypedStream.extractText(from: Data()))
        XCTAssertNil(TypedStream.extractText(from: Data("garbage".utf8)))
    }

    // MARK: iMessage

    func makeIMessageDB() throws -> URL {
        let url = tmp.appendingPathComponent("chat.db")
        let db = try Database(path: url.path)
        try db.exec("""
        CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, chat_identifier TEXT, style INTEGER);
        CREATE TABLE message(ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, is_from_me INTEGER, date INTEGER, handle_id INTEGER, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0);
        CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
        INSERT INTO handle VALUES (1, '+15551230001'), (2, '+15551230002');
        INSERT INTO chat VALUES (1, 'iMessage;-;+15551230001', '', '+15551230001', 45), (2, 'iMessage;+;chat999', 'Secret Club', 'chat999', 43);
        """)
        let base = Int64(Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate * 1_000_000_000)
        func msg(_ id: Int, _ text: String?, body: Data? = nil, me: Int, chat: Int, minute: Int, assoc: Int = 0) throws {
            try db.run("INSERT INTO message(ROWID,text,attributedBody,is_from_me,date,handle_id,associated_message_type) VALUES(?,?,?,?,?,?,?)",
                [.int(id), text.map { .text($0) } ?? .null, body.map { .blob($0) } ?? .null, .int(me), .int64(base + Int64(minute) * 60_000_000_000), .int(1), .int(assoc)])
            try db.run("INSERT INTO chat_message_join VALUES(?,?)", [.int(chat), .int(id)])
        }
        try msg(1, "Lunch tomorrow at noon?", me: 0, chat: 1, minute: 0)
        try msg(2, nil, body: typedStream("Sure, the usual place"), me: 1, chat: 1, minute: 1)
        try msg(3, "Loved “Sure, the usual place”", me: 0, chat: 1, minute: 2, assoc: 2000)  // tapback
        try msg(4, "\u{FFFC}", me: 0, chat: 1, minute: 3)  // attachment placeholder only
        try msg(5, "this group chat was never selected", me: 0, chat: 2, minute: 4)
        return url
    }

    func testIMessageListsChatsWithoutTextAndReadsOnlySelected() async throws {
        let url = try makeIMessageDB()
        let chats = try IMessageConnector.listChats(databaseURL: url)
        XCTAssertEqual(Set(chats.map(\.name)), ["+15551230001", "Secret Club"])
        XCTAssertEqual(chats.first { $0.name == "Secret Club" }?.isGroup, true)
        XCTAssertEqual(chats.first { $0.name == "+15551230001" }?.messageCount, 3, "tapbacks are not messages (attachment placeholder still counts here)")

        let c = IMessageConnector(databaseURL: url, selectedChatIDs: ["iMessage;-;+15551230001"])
        let refs = try await c.list()
        XCTAssertEqual(refs.count, 1)
        XCTAssertFalse(refs.contains { $0.uri.contains("chat999") }, "unselected chats must never be read")
        guard case .conversation(let lines, let info) = try await c.load(refs[0]) else { return XCTFail() }
        XCTAssertEqual(lines, ["+15551230001: Lunch tomorrow at noon?", "Me: Sure, the usual place"])
        XCTAssertFalse(info.isGroup)
        // New messages change the fingerprint so the window is re-analyzed.
        let before = refs[0].fingerprint
        let db = try Database(path: url.path)
        try db.run("INSERT INTO message(ROWID,text,is_from_me,date,handle_id) VALUES(9,'one more',0,?,1)", [.int64(Int64(Date(timeIntervalSince1970: 1_700_000_900).timeIntervalSinceReferenceDate * 1_000_000_000))])
        try db.run("INSERT INTO chat_message_join VALUES(1,9)")
        let after = try await c.list()
        XCTAssertNotEqual(before, after[0].fingerprint)
    }

    /// Regression: every `load` used to copy the whole database again (chat.db can be gigabytes).
    func testAChatRunCopiesTheDatabaseOnceNotOncePerWindow() async throws {
        let url = try makeIMessageDB()
        let c = IMessageConnector(databaseURL: url, selectedChatIDs: ["iMessage;-;+15551230001", "iMessage;+;chat999"])
        let before = DatabaseSnapshot.openCount
        let refs = try await c.list()
        for r in refs { _ = try await c.load(r) }
        XCTAssertGreaterThanOrEqual(refs.count, 2)
        XCTAssertEqual(DatabaseSnapshot.openCount - before, 1, "one copy for \(refs.count) windows")
        _ = try await c.list()
        XCTAssertEqual(DatabaseSnapshot.openCount - before, 2, "the next run takes a fresh copy, so new messages are seen")
    }

    func testAppleDateHandlesNanosecondsAndSeconds() {
        let ref = Date(timeIntervalSinceReferenceDate: 700_000_000)
        XCTAssertEqual(IMessageConnector.appleDate(700_000_000 * 1_000_000_000).timeIntervalSince(ref), 0, accuracy: 1)
        XCTAssertEqual(IMessageConnector.appleDate(700_000_000).timeIntervalSince(ref), 0, accuracy: 1)
    }

    func testSnapshotNeverModifiesTheOriginalDatabase() throws {
        let url = try makeIMessageDB()
        let before = try Data(contentsOf: url)
        _ = try IMessageConnector.listChats(databaseURL: url)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertThrowsError(try IMessageConnector.listChats(databaseURL: tmp.appendingPathComponent("missing.db"))) { error in
            XCTAssertTrue("\(error)".contains("Full Disk Access"))
        }
    }

    // MARK: WhatsApp (fixture follows the documented Core Data schema)

    func testWhatsAppReadsSelectedChatWithGroupSenders() async throws {
        let url = tmp.appendingPathComponent("ChatStorage.sqlite")
        let db = try Database(path: url.path)
        try db.exec("""
        CREATE TABLE ZWACHATSESSION(Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZSESSIONTYPE INTEGER);
        CREATE TABLE ZWAGROUPMEMBER(Z_PK INTEGER PRIMARY KEY, ZMEMBERJID TEXT);
        CREATE TABLE ZWAMESSAGE(Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZTEXT TEXT, ZMESSAGEDATE REAL, ZGROUPMEMBER INTEGER);
        INSERT INTO ZWACHATSESSION VALUES (1,'g1@g.us','Book club',1),(2,'p1@s.whatsapp.net','Dana',0);
        INSERT INTO ZWAGROUPMEMBER VALUES (1,'alex@s.whatsapp.net');
        INSERT INTO ZWAMESSAGE VALUES (1,1,0,'Next meeting is at 7',700000000,1),(2,1,1,'I will bring snacks',700000060,NULL),(3,2,0,'private chat not selected',700000100,NULL),(4,1,0,'',700000120,1);
        """)
        let chats = try WhatsAppConnector.listChats(databaseURL: url)
        XCTAssertEqual(chats.first { $0.name == "Book club" }?.messageCount, 2)
        let c = WhatsAppConnector(databaseURL: url, selectedChatIDs: ["g1@g.us"])
        let refs = try await c.list()
        XCTAssertEqual(refs.count, 1)
        guard case .conversation(let lines, let info) = try await c.load(refs[0]) else { return XCTFail() }
        XCTAssertEqual(lines, ["alex@s.whatsapp.net: Next meeting is at 7", "Me: I will bring snacks"])
        XCTAssertTrue(info.isGroup)
    }

    // MARK: Calendar

    final class FixtureCalendar: CalendarEventSource, @unchecked Sendable {
        var events: [CalendarEventData]
        private(set) var fetches = 0
        init(events: [CalendarEventData]) { self.events = events }
        func events(from: Date, to: Date) async throws -> [CalendarEventData] { fetches += 1; return events.filter { $0.start >= from && $0.start <= to } }
    }

    func testCalendarFetchesOncePerRunNotOncePerEvent() async throws {
        let now = Date()
        let fixture = FixtureCalendar(events: (0..<25).map { CalendarEventData(id: "e\($0)", title: "Event \($0)", start: now.addingTimeInterval(Double($0 + 1) * 3_600), end: now.addingTimeInterval(Double($0 + 2) * 3_600)) })
        var c = CalendarConnector(source: fixture); c.now = { now }
        let refs = try await c.list()
        for r in refs { _ = try await c.load(r) }
        XCTAssertEqual(fixture.fetches, 1, "25 events, one round trip")
    }

    func testCalendarFingerprintsTrackReschedulesAndEndToEndDeletesRemovedEvents() async throws {
        let now = Date()
        var event = CalendarEventData(id: "e1", title: "Dentist", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000), location: "Main St Clinic", notes: "bring forms")
        let gone = CalendarEventData(id: "e2", title: "Team offsite", start: now.addingTimeInterval(2 * 86_400), end: now.addingTimeInterval(3 * 86_400), attendees: ["Priya", "Sam"])
        let far = CalendarEventData(id: "e3", title: "Way out", start: now.addingTimeInterval(400 * 86_400), end: now.addingTimeInterval(401 * 86_400))
        var c = CalendarConnector(source: FixtureCalendar(events: [event, gone, far]))
        c.now = { now }
        let refs = try await c.list()
        XCTAssertEqual(Set(refs.map(\.key)), ["e1", "e2"], "outside the window is not read")
        XCTAssertTrue(refs.allSatisfy { $0.trust == .schedule })
        guard case .text(let t) = try await c.load(refs.first { $0.key == "e2" }!) else { return XCTFail() }
        XCTAssertTrue(t.contains("With: Priya, Sam"))
        XCTAssertTrue(t.contains("not proof that it happened"))

        // Through the pipeline: summarized once, then reconciled when events move or vanish.
        let store = try T.store()
        let model = MockModel { _ in #"{"summary":"The user has a scheduled appointment.","title":"Appointment","junk":false,"sensitive":false}"# }
        let pipeline = IngestPipeline(store: store, triager: Triager(model: model), indexer: Indexer(store: store, embedder: HashingEmbedder()))
        let first = try await pipeline.run(connectors: [c])
        XCTAssertEqual(first.survivors, 2)
        event.start = event.start.addingTimeInterval(7_200)   // rescheduled
        var c2 = CalendarConnector(source: FixtureCalendar(events: [event]))   // and "gone" was cancelled
        c2.now = { now }
        let second = try await pipeline.run(connectors: [c2])
        XCTAssertEqual(second.deleted, 1)
        XCTAssertEqual(second.survivors, 1, "only the rescheduled event is re-analyzed")
        XCTAssertEqual(try store.items(bucket: "calendar:apple").count, 1)
    }
}

extension SQLValue {
    static func int64(_ v: Int64) -> SQLValue { .int(v) }
}
