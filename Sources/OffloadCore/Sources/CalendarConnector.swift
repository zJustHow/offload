import EventKit
import Foundation

public struct CalendarEventData: Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String
    public var notes: String
    public var calendarName: String
    public var attendees: [String]

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, location: String = "", notes: String = "", calendarName: String = "", attendees: [String] = []) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.location = location; self.notes = notes; self.calendarName = calendarName; self.attendees = attendees
    }
}

/// Where events come from. EventKit in the app; a fixture in tests.
public protocol CalendarEventSource: Sendable {
    func events(from: Date, to: Date) async throws -> [CalendarEventData]
}

public struct EventKitSource: CalendarEventSource {
    public init() {}

    public func events(from: Date, to: Date) async throws -> [CalendarEventData] {
        let store = EKEventStore()
        let granted: Bool
        do { granted = try await store.requestFullAccessToEvents() } catch { throw ConnectorError.permissionDenied("calendar access: \(error.localizedDescription)") }
        guard granted else { throw ConnectorError.permissionDenied("calendar access was not granted") }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map { e in
            CalendarEventData(
                id: "\(e.eventIdentifier ?? UUID().uuidString)@\(Int(e.startDate.timeIntervalSince1970))",
                title: e.title ?? "(untitled)", start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                location: e.location ?? "", notes: e.notes ?? "", calendarName: e.calendar?.title ?? "",
                attendees: (e.attendees ?? []).compactMap { $0.name })
        }
    }
}

/// One item per event in a window around today. Calendars change in ways a "newest item" pointer
/// cannot track (reschedules, deletions), so the whole window is re-listed every time and the
/// pipeline reconciles it by fingerprint; events that drop out of the window leave the raw index
/// (their durable facts live on in the knowledge base).
public struct CalendarConnector: Connector {
    public let source: CalendarEventSource
    public let kind: SourceKind = .calendar
    /// Distinct per source: two calendars must never share a bucket, or each would delete the
    /// other's items when it reconciles.
    public let bucket: String
    public let listsAllItems = true
    public var daysBack = 30
    public var daysAhead = 120
    public var now: @Sendable () -> Date = { Date() }
    private let cache = EventCache()

    public init(source: CalendarEventSource = EventKitSource(), bucket: String = "calendar:apple") { self.source = source; self.bucket = bucket }

    /// The events fetched by the last `list()`, so `load()` is a dictionary lookup rather than a
    /// second (and per-event) round trip to EventKit or Google.
    final class EventCache: @unchecked Sendable {
        private let lock = NSLock(); private var events: [String: CalendarEventData] = [:]
        func replace(_ list: [CalendarEventData]) { lock.lock(); events = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }); lock.unlock() }
        subscript(id: String) -> CalendarEventData? { lock.lock(); defer { lock.unlock() }; return events[id] }
    }

    public func list() async throws -> [WorkItemRef] {
        let t = now()
        let events = try await source.events(from: t.addingTimeInterval(-Double(daysBack) * 86_400), to: t.addingTimeInterval(Double(daysAhead) * 86_400))
        cache.replace(events)
        return events.map { e in
            WorkItemRef(
                key: e.id, fingerprint: Hashing.sha256Hex(Self.render(e)), date: e.start, title: e.title,
                uri: "calendar://\(e.id)", trust: .schedule)
        }
    }

    public func load(_ ref: WorkItemRef) async throws -> ItemContent {
        guard let e = cache[ref.key] else { throw ConnectorError.unreadable("event no longer exists") }
        return .text(Self.render(e))
    }

    static func render(_ e: CalendarEventData) -> String {
        let f = ISO8601DateFormatter()
        var s = "Event: \(e.title)\n"
        s += e.isAllDay ? "When: all day, \(f.string(from: e.start).prefix(10))\n" : "When: \(f.string(from: e.start)) to \(f.string(from: e.end))\n"
        if !e.location.isEmpty { s += "Where: \(e.location)\n" }
        if !e.calendarName.isEmpty { s += "Calendar: \(e.calendarName)\n" }
        if !e.attendees.isEmpty { s += "With: \(e.attendees.prefix(12).joined(separator: ", "))\n" }
        if !e.notes.isEmpty { s += "Notes: \(e.notes.prefix(1_500))\n" }
        s += "(Calendar snapshot: a scheduled entry, not proof that it happened or that the user attended.)"
        return s
    }
}
