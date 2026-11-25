import Foundation

/// Google Calendar through the REST API (read-only scope), as a drop-in event source for
/// `CalendarConnector`. Reads every calendar the user has except holiday calendars.
public struct GoogleCalendarSource: CalendarEventSource {
    let api: GoogleAPI

    public init(auth: GoogleAuth, transport: HTTPTransport = URLSessionTransport()) { self.api = GoogleAPI(auth: auth, transport: transport) }

    public func events(from: Date, to: Date) async throws -> [CalendarEventData] {
        guard await api.auth.hasScope(GoogleAuth.calendarScope) else { throw GoogleError.missingScope("Google Calendar") }
        let list = try await api.get("https://www.googleapis.com/calendar/v3/users/me/calendarList")
        let calendars = (list["items"] as? [[String: Any]] ?? []).compactMap { c -> (String, String)? in
            guard let id = c["id"] as? String, !id.contains("#holiday@") else { return nil }
            return (id, c["summary"] as? String ?? "")
        }
        let iso = ISO8601DateFormatter()
        var out: [CalendarEventData] = []
        for (calendarID, calendarName) in calendars {
            var pageToken: String?
            repeat {
                var q: [URLQueryItem] = [
                    .init(name: "timeMin", value: iso.string(from: from)), .init(name: "timeMax", value: iso.string(from: to)),
                    .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"), .init(name: "maxResults", value: "250"),
                ]
                if let pageToken { q.append(.init(name: "pageToken", value: pageToken)) }
                let encoded = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/#@"))) ?? calendarID
                let page = try await api.get("https://www.googleapis.com/calendar/v3/calendars/\(encoded)/events", query: q)
                for e in page["items"] as? [[String: Any]] ?? [] { if let ev = Self.event(e, calendarID: calendarID, calendarName: calendarName) { out.append(ev) } }
                pageToken = page["nextPageToken"] as? String
            } while pageToken != nil
        }
        return out
    }

    static func event(_ e: [String: Any], calendarID: String, calendarName: String) -> CalendarEventData? {
        guard (e["status"] as? String) != "cancelled", let id = e["id"] as? String,
            let start = e["start"] as? [String: Any], let end = e["end"] as? [String: Any],
            let s = date(start), let en = date(end)
        else { return nil }
        // Attendee names only: e-mail addresses are not needed to understand the schedule.
        let names = (e["attendees"] as? [[String: Any]] ?? []).compactMap { $0["displayName"] as? String }
        return CalendarEventData(
            id: "\(calendarID)|\(id)", title: e["summary"] as? String ?? "(untitled)", start: s, end: en,
            isAllDay: start["date"] != nil, location: e["location"] as? String ?? "", notes: e["description"] as? String ?? "",
            calendarName: calendarName, attendees: names)
    }

    static func date(_ obj: [String: Any]) -> Date? {
        if let dt = obj["dateTime"] as? String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: dt) ?? ISO8601DateFormatter().date(from: dt)
        }
        if let d = obj["date"] as? String {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
            return f.date(from: d)
        }
        return nil
    }
}
