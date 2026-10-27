import SwiftUI

@main
struct TethworkApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 960, minHeight: 580)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") {
                    appModel.showConnectSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .pasteboard) {
                Button("Select All") {
                    appModel.selectAll()
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(appModel.activeConnection == nil)

                Button("Select All") {
                    appModel.selectAll()
                }
                .keyboardShortcut("a", modifiers: [.control])
                .disabled(appModel.activeConnection == nil)

                Button("Delete") {
                    appModel.requestDeleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(appModel.selectedIDs.isEmpty || appModel.activeConnection == nil)
            }
            CommandMenu("Sync") {
                Button("Sync Now") {
                    Task { await appModel.fullSync() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(appModel.activeConnection == nil)

                Button(appModel.isCurrentPinned ? "Remove Current Folder from This Mac" : "Keep Current Folder on This Mac") {
                    Task { await appModel.togglePinCurrent() }
                }
                .disabled(appModel.activeConnection == nil)

                Divider()

                Button("Disconnect") {
                    Task { await appModel.disconnect() }
                }
                .disabled(appModel.activeConnection == nil)
            }
            CommandMenu("View") {
                Button("Quick Look") {
                    appModel.previewSelected()
                }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(appModel.selectedIDs.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .frame(width: 420, height: 240)
        }

        MenuBarExtra {
            MenuBarStatusView()
                .environmentObject(appModel)
        } label: {
            Image("Union")
        }
    }
}
