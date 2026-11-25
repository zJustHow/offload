import OffloadUI
import SwiftUI

/// Sample data for rendering screens without the rest of the app.
@MainActor
enum Fixtures {
    static func onboarding(_ step: OnboardingModel.Step, analysis: AnalysisState = AnalysisState()) -> OnboardingModel {
        let m = OnboardingModel(startAt: step)
        m.sources = [
            SourceOption(id: "folders", title: "Folders", subtitle: "Documents, notes and PDFs you keep in folders.", symbol: "folder", style: .folders, isOn: true, detail: "2 folders chosen"),
            SourceOption(id: "notes", title: "Apple Notes", subtitle: "Your notes in the Notes app.", symbol: "note.text", isOn: true, needsFullDiskAccess: true),
            SourceOption(id: "mail", title: "Apple Mail", subtitle: "Messages in your mailboxes, read here and never sent anywhere.", symbol: "envelope", needsFullDiskAccess: true),
            SourceOption(id: "calendar", title: "Calendar", subtitle: "Upcoming events and recent ones.", symbol: "calendar", isOn: true),
            SourceOption(id: "messages", title: "Messages", subtitle: "Only the conversations you pick, one by one.", symbol: "message", style: .chats, needsFullDiskAccess: true),
            SourceOption(id: "siyuan", title: "SiYuan", subtitle: "A SiYuan workspace on this Mac.", symbol: "books.vertical", style: .folders),
        ]
        m.permissions = [
            PermissionRow(id: "fda", title: "Full Disk Access", detail: "Lets me read Apple Notes and Mail. Add Offload under Privacy & Security.", status: .needsAction, symbol: "internaldrive", required: true, settingsURL: URL(string: "x-apple.systempreferences:")),
            PermissionRow(id: "calendar", title: "Calendar", detail: "Lets me read your events.", status: .ok, symbol: "calendar", required: true),
            PermissionRow(id: "screen", title: "Screen Recording", detail: "So I can see the screen when you ask me to do something.", status: .optional, symbol: "rectangle.dashed.badge.record", required: false, settingsURL: URL(string: "x-apple.systempreferences:")),
            PermissionRow(id: "accessibility", title: "Accessibility", detail: "So I can click and type, and for the double-⌘ shortcut.", status: .optional, symbol: "accessibility", required: false, settingsURL: URL(string: "x-apple.systempreferences:")),
        ]
        m.models = [
            ModelOption(id: "builtin", title: "Built in", subtitle: "Runs on this Mac and works offline. Good for reading and searching; its notes are less polished.", readiness: .ready, statusText: "Ready"),
            ModelOption(id: "claude", title: "My Claude subscription", subtitle: "Writes much better notes. Your notes (not your raw files) are sent to Anthropic.", badge: "Recommended", readiness: .ready, statusText: "Logged in via claude.ai"),
            ModelOption(id: "chatgpt", title: "My ChatGPT subscription", subtitle: "Uses the Codex command-line tool.", readiness: .needsSetup, statusText: "Not installed. Run `codex login` after installing it."),
            ModelOption(id: "local", title: "A model on this Mac (Ollama)", subtitle: "Private and strong, if you already run a large local model.", readiness: .needsSetup, statusText: "Not detected at localhost:11434"),
        ]
        m.selectedModel = "claude"
        m.analysis = analysis
        return m
    }

    static var running: AnalysisState {
        var a = AnalysisState(); a.phase = .running; a.stage = "Reading"; a.source = "Apple Notes"; a.done = 34; a.total = 120
        a.currentTitle = "Trip plan: Japan in April"; a.kept = 28; a.skipped = 5; a.sensitive = 1
        return a
    }
    static var finished: AnalysisState {
        var a = running; a.phase = .finished; a.done = 120; a.kept = 97; a.skipped = 21; a.sensitive = 2; a.notes = 18
        a.warnings = ["The knowledge base was written by the built-in model, which is less accurate."]
        return a
    }

    static var graphNotes: [(path: String, title: String, body: String)] {
        [("README.md", "About", "[[Apartment]] [[Acme]] [[Priya]] [[Japan trip]] [[Sourdough]] [[Fundraising]] [[Flights]] [[Taxes]]"),
         ("Home/Apartment.md", "Apartment", "Lease. See [[Taxes]] and [[Sourdough]]."),
         ("Home/Sourdough.md", "Sourdough", "Recipe notes."),
         ("Home/Taxes.md", "Taxes", "Quarterly. [[Acme]]"),
         ("Work/Acme.md", "Acme", "[[Fundraising]] [[Priya]] [[Flights]]"),
         ("Work/Fundraising.md", "Fundraising", "Series A. [[Acme]]"),
         ("Work/Priya.md", "Priya", "Weekly sync. [[Acme]]"),
         ("Travel/Japan trip.md", "Japan trip", "[[Flights]] [[Kyoto]]"),
         ("Travel/Flights.md", "Flights", "UA 837. [[Japan trip]]"),
         ("Travel/Kyoto.md", "Kyoto", "Ryokan. [[Japan trip]]"),
         ("People/Alvarez.md", "Alvarez", "Landlord. [[Apartment]]"),
         ("People/Wang.md", "Wang", "[[Apartment]]")]
    }
}

extension Fixtures {
    @MainActor static func home(running: Bool = false) -> HomeModel {
        let m = HomeModel()
        var d = HomeData()
        d.itemsRead = 1284; d.notes = 47; d.suggestions = 3
        d.lastRun = Date().addingTimeInterval(-3 * 3600)
        d.sources = [
            HomeSource(id: "files", title: "Folder “Notes”", symbol: "folder", itemCount: 312, status: .ok, detail: "Up to date"),
            HomeSource(id: "notes", title: "Apple Notes", symbol: "note.text", itemCount: 204, status: .ok, detail: "Up to date"),
            HomeSource(id: "mail", title: "Apple Mail", symbol: "envelope", itemCount: 640, status: .needsAction, detail: "Needs Full Disk Access"),
            HomeSource(id: "cal", title: "Apple Calendar", symbol: "calendar", itemCount: 128, status: .ok, detail: "Up to date"),
        ]
        d.attention = [
            HomeAttention(id: "fda", title: "Allow Full Disk Access", detail: "Mail can't be read until Offload is allowed in Privacy & Security.", actionTitle: "Open Settings", url: URL(string: "x-apple.systempreferences:")),
            HomeAttention(id: "model", title: "Notes are written by the built-in model", detail: "A stronger model makes noticeably better notes.", actionTitle: "Choose a model"),
        ]
        d.activity = [
            HomeActivity(id: "1", date: Date().addingTimeInterval(-3 * 3600), text: "Read 18 new items and updated 4 notes."),
            HomeActivity(id: "2", date: Date().addingTimeInterval(-27 * 3600), text: "Read 6 new items. Mail couldn't be read.", isWarning: true),
            HomeActivity(id: "3", date: Date().addingTimeInterval(-51 * 3600), text: "Read 212 items and wrote 31 notes."),
        ]
        if running { d.analysis = Fixtures.running }
        m.data = d
        return m
    }
}
