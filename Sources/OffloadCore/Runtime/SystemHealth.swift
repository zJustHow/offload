import ApplicationServices
import EventKit
import Foundation

public struct HealthItem: Sendable, Identifiable, Equatable {
    public enum Status: String, Sendable { case ok, needsAction, optional, unavailable }
    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    /// A System Settings pane that fixes it, when there is one.
    public var settingsURL: URL?
}

/// What works on this Mac right now and what the user can do about what does not. Used by the
/// onboarding guide and the settings screen; every probe is read-only and prompts for nothing.
public enum SystemHealth {
    static func pane(_ anchor: String) -> URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")! }

    /// Full Disk Access cannot be queried directly. Safari's folder exists on every Mac and is
    /// protected by it, so being able to list it is the standard test.
    public static func hasFullDiskAccess(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let probe = home.appendingPathComponent("Library/Safari")
        guard FileManager.default.fileExists(atPath: probe.path) else { return true }   // nothing protected to test against
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }

    public static var calendarAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    public static func check(config: OffloadConfig) async -> [HealthItem] {
        var items: [HealthItem] = []
        let needsFDA = config.appleNotesEnabled || config.mailEnabled || !config.imessageChats.isEmpty || !config.whatsappChats.isEmpty
        let fda = hasFullDiskAccess()
        items.append(HealthItem(
            id: "fda", title: "Full Disk Access", status: fda ? .ok : (needsFDA ? .needsAction : .optional),
            detail: fda ? "Granted" : "Needed to read Apple Notes, Mail, Messages and WhatsApp",
            settingsURL: pane("Privacy_AllFiles")))
        items.append(HealthItem(
            id: "calendar", title: "Calendar", status: calendarAccess ? .ok : (config.calendarEnabled ? .needsAction : .optional),
            detail: calendarAccess ? "Granted" : "Needed to read Apple Calendar", settingsURL: pane("Privacy_Calendars")))
        items.append(HealthItem(
            id: "screen", title: "Screen Recording", status: ComputerPermissions.screenRecording ? .ok : .optional,
            detail: ComputerPermissions.screenRecording ? "Granted" : "Needed for “Do” tasks and drafting replies from the screen", settingsURL: pane("Privacy_ScreenCapture")))
        items.append(HealthItem(
            id: "accessibility", title: "Accessibility", status: ComputerPermissions.accessibility ? .ok : .optional,
            detail: ComputerPermissions.accessibility ? "Granted" : "Needed so the assistant can click and type, and for the double-⌘ shortcut", settingsURL: pane("Privacy_Accessibility")))

        let model = AppleOnDeviceModel.availability
        items.append(HealthItem(
            id: "builtin", title: "Built-in model", status: model.available ? .ok : .unavailable,
            detail: model.available ? "Ready (runs on this Mac)" : "Unavailable: \(model.reason). Turn on Apple Intelligence in System Settings, or use another model.", settingsURL: nil))
        let claude = await ClaudeCLIModel.authStatus()
        items.append(HealthItem(
            id: "claude", title: "Claude subscription", status: claude.loggedIn ? .ok : .optional,
            detail: claude.loggedIn ? "Logged in via \(claude.method ?? "claude")" : claude.detail, settingsURL: nil))
        let codex = await CodexCLIModel.loginStatus()
        items.append(HealthItem(
            id: "codex", title: "ChatGPT subscription", status: codex.loggedIn ? .ok : .optional, detail: codex.loggedIn ? "Logged in" : codex.detail, settingsURL: nil))
        let google = await GoogleAuth().credentials()
        items.append(HealthItem(
            id: "google", title: "Google", status: google != nil ? .ok : (config.gmailEnabled || config.googleCalendarEnabled ? .needsAction : .optional),
            detail: google != nil ? "Signed in" : "Not signed in", settingsURL: nil))
        return items
    }
}
