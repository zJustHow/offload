import OffloadCore
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let error = model.startupError { Text(error).foregroundStyle(.primary); Divider() }
        Text(statusLine)
        Divider()
        Button("Ask or give a task…") { model.openAssistant() }.keyboardShortcut(" ", modifiers: [.command, .shift])
        Button("Home") { model.showHome() }
        Button("Knowledge") { model.showKnowledge() }
        Button("Suggestions" + (model.cards.isEmpty ? "" : " (\(model.cards.count))")) { model.showSuggestions() }
        Divider()
        Button(model.cycleRunning ? "Stop reading" : "Analyze now") { model.cycleRunning ? model.stopCycle() : model.startCycle() }.disabled(model.runtime == nil)
        Toggle("Draft replies with a double-tap of right ⌘", isOn: $model.doubleTapEnabled)
        Divider()
        Button("Settings…") { model.openSettings() }.keyboardShortcut(",")
        Button("Welcome guide…") { model.showOnboarding(restart: true) }
        Divider()
        Button("Quit Offload") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }

    private var statusLine: String {
        if model.cycleRunning { return model.home.data.analysis.source.map { "Reading \($0)…" } ?? "Working…" }
        let n = model.counts["survivor"] ?? 0
        return n == 0 ? "Nothing read yet" : "\(n.formatted()) items known"
    }
}
