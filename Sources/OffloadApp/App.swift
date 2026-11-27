import OffloadCore
import SwiftUI

@main
struct OffloadApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: "sparkles").symbolEffect(.variableColor.iterative, isActive: model.cycleRunning)
                .accessibilityLabel("Offload")
        }
        // Settings is a window of our own (so it can look like the rest of the app); this keeps ⌘, working.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.openSettings() }.keyboardShortcut(",")
            }
        }
    }
}
