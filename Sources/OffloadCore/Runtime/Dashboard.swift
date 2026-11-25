import Foundation

/// The wording and judgement behind the dashboard, kept out of the UI so it can be tested.
public enum Dashboard {
    /// Whether a source can work right now, and a short phrase for the reason.
    public static func sourceStatus(bucket: String, itemCount: Int, hasFullDiskAccess: Bool, hasCalendarAccess: Bool, isSignedInToGoogle: Bool) -> (status: HealthItem.Status, detail: String) {
        let needsFDA = bucket == "applenotes" || bucket == "imessage" || bucket == "whatsapp" || bucket.hasPrefix("mail:")
        if needsFDA, !hasFullDiskAccess { return (.needsAction, "Needs Full Disk Access") }
        if bucket == "calendar:apple", !hasCalendarAccess { return (.needsAction, "Needs Calendar access") }
        if bucket == "gmail" || bucket == "calendar:google", !isSignedInToGoogle { return (.needsAction, "Sign in to Google") }
        return (.ok, itemCount == 0 ? "Not read yet" : "Up to date")
    }

    /// An SF Symbol name for a source.
    public static func symbol(forBucket b: String) -> String {
        switch true {
        case b.hasPrefix("files:"): return "folder"
        case b == "imessage": return "message"
        case b == "whatsapp": return "bubble.left.and.bubble.right"
        case b.hasPrefix("mail:"): return "envelope"
        case b.hasPrefix("calendar:"): return "calendar"
        case b == "applenotes": return "note.text"
        case b.hasPrefix("siyuan:"): return "books.vertical"
        case b == "gmail": return "tray"
        default: return "doc"
        }
    }

    /// One line describing a finished run.
    public static func activityText(_ r: CycleRecord) -> String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var s: String
        if r.cancelled { s = "Stopped early after reading \(plural(r.kept, "item"))." }
        else if r.kept == 0 { s = "Checked for new items; nothing new." }
        else { s = "Read \(plural(r.kept, "new item"))" + (r.notesChanged > 0 ? " and updated \(plural(r.notesChanged, "note"))." : ".") }
        if let w = r.warnings.first { s += " " + String(w.prefix(90)) }
        return s
    }

    /// What an agent step looks like to a person.
    public static func stepDescription(_ a: AgentAction) -> String {
        func arg(_ k: String) -> String { a.args[k] ?? "" }
        switch a.tool {
        case "search_memory": return "Searching your memory for “\(arg("query"))”"
        case "read_note": return "Reading \(arg("path"))"
        case "read_item", "open_source": return "Looking at the original"
        case "screenshot", "screen_text": return "Looking at the screen"
        case "click": return "Clicking"
        case "type": return "Typing"
        case "key": return "Pressing \(arg("combo"))"
        case "scroll": return "Scrolling"
        case "open_app": return "Opening \(arg("name"))"
        case "open_url": return "Opening a web page"
        case "ask_user": return "Asking you a question"
        default: return a.thought.isEmpty ? a.tool : String(a.thought.prefix(60))
        }
    }
}

public enum ErrorText {
    /// An error in words a person can act on.
    public static func friendly(_ error: Error) -> String {
        let text = "\(error)"
        let lower = text.lowercased()
        if lower.contains("usage limit") { return "Your usage limit was reached. Try again later." }
        if lower.contains("not logged in") || lower.contains("auth login") || lower.contains("codex login") { return text }
        if lower.contains("command was not found") || (lower.contains("not found") && lower.contains("claude")) { return "The model's command-line tool isn't installed. Choose another model in Settings." }
        if lower.contains("could not connect") || lower.contains("offline") || lower.contains("network") || lower.contains("timed out") { return "Couldn't reach the model. Check your connection and try again." }
        if lower.contains("unavailable") && lower.contains("apple") { return "The built-in model isn't available. Turn on Apple Intelligence in System Settings, or choose another model." }
        return String(text.prefix(220))
    }
}
