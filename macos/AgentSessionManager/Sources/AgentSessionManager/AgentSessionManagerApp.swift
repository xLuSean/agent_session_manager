import Foundation
import SwiftUI

@main
struct AgentSessionManagerApp: App {
    @StateObject private var model: SessionManagerModel

    init() {
        _model = StateObject(wrappedValue: SessionManagerModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(
                    minWidth: MainWindowLayout.minimumWidth,
                    maxWidth: .infinity,
                    minHeight: MainWindowLayout.minimumHeight,
                    maxHeight: .infinity
                )
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Sessions") {
                    Task { await model.reload() }
                }
                .keyboardShortcut("r")
            }
        }

        Settings {
            AgentSessionManagerSettingsView()
                .environmentObject(model)
        }
    }
}
