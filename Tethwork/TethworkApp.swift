import SwiftUI

@main
struct TethworkApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appModel)
                // Min size lives on split columns (see ContentView) — minWidth on
                // NavigationSplitView itself makes the sidebar *show* animation hitch.
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                    guard note.object is NSWindow else { return }
                    DispatchQueue.main.async {
                        let hasVisible = NSApp.windows.contains {
                            $0.isVisible && !($0 is NSPanel) && $0.level == .normal
                        }
                        if !hasVisible {
                            NSApp.setActivationPolicy(.accessory)
                        }
                    }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") {
                    appModel.showConnectSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .pasteboard) {
                Button("Select All") {
                    if appModel.showingTrash {
                        appModel.trashSelection = Set(appModel.trashItems.map(\.id))
                    } else {
                        appModel.selectAll()
                    }
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(!appModel.showingTrash && appModel.activeConnection == nil)

                Button("Select All") {
                    if appModel.showingTrash {
                        appModel.trashSelection = Set(appModel.trashItems.map(\.id))
                    } else {
                        appModel.selectAll()
                    }
                }
                .keyboardShortcut("a", modifiers: [.control])
                .disabled(!appModel.showingTrash && appModel.activeConnection == nil)

                Button(appModel.showingTrash ? "Delete Immediately" : "Move to Trash") {
                    if appModel.showingTrash {
                        appModel.requestDeleteTrashSelection()
                    } else {
                        appModel.requestDeleteSelected()
                    }
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(
                    (!appModel.showingTrash && appModel.activeConnection == nil)
                        || (appModel.showingTrash
                            ? appModel.trashSelection.isEmpty
                            : appModel.selectedIDs.isEmpty)
                )
            }
            CommandMenu("Trash") {
                Button("Show Trash") {
                    Task { await appModel.openTrash() }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(appModel.connections.isEmpty)

                Button("Restore Selected") {
                    appModel.restoreTrashSelection()
                }
                .disabled(!appModel.showingTrash || appModel.trashSelection.isEmpty)

                Divider()

                Button("Empty Trash…") {
                    appModel.requestEmptyTrash()
                }
                .disabled(!appModel.showingTrash || appModel.trashItems.isEmpty)
            }
            CommandMenu("Sync") {
                Button("Sync Now") {
                    Task { await appModel.fullSync() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(appModel.activeConnection == nil)

                Button(appModel.isCurrentPinned ? "Keep Current Folder Online Only" : "Keep Current Folder on This Mac") {
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

        MenuBarExtra {
            MenuBarStatusView()
                .environmentObject(appModel)
        } label: {
            Image(appModel.menuBarIconName)
        }
    }
}
