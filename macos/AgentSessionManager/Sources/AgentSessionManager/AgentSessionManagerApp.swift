import AppKit
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
            CommandGroup(replacing: .appInfo) {
                Button("About Agent Session Manager") {
                    let info = Bundle.main.infoDictionary ?? [:]
                    let marketing = info["CFBundleShortVersionString"] as? String ?? "Development"
                    let suffix = info["ASMReleaseSuffix"] as? String ?? ""
                    let release = marketing + (suffix.isEmpty ? "" : "-" + suffix)
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: release,
                        .version: info["CFBundleVersion"] as? String ?? ""
                    ])
                }
            }
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
