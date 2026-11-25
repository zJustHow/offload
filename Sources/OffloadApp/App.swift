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
        Settings { SettingsView(model: model) }
    }
}
