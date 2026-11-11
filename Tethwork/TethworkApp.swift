import SwiftUI

final class TethworkApplicationDelegate: NSObject, NSApplicationDelegate {
    var updater: AppUpdater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Tethwork launched (pid %d)", ProcessInfo.processInfo.processIdentifier)
        updater?.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Closing the browser must never stop background synchronization.
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("Tethwork terminating normally (pid %d)", ProcessInfo.processInfo.processIdentifier)
    }
}

@main
struct TethworkApp: App {
    @NSApplicationDelegateAdaptor(TethworkApplicationDelegate.self) private var applicationDelegate
    @StateObject private var appModel: AppModel
    @StateObject private var menuBarController: MenuBarStatusController
    @StateObject private var updater: AppUpdater

    init() {
        let model = AppModel()
        let updater = AppUpdater(model: model)
        _appModel = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: updater)
        _menuBarController = StateObject(wrappedValue: MenuBarStatusController(
            model: model, installsStatusItem: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            checkForUpdates: updater.checkForUpdates, updateAvailability: updater.$canCheckForUpdates.eraseToAnyPublisher()))
        applicationDelegate.updater = updater
    }

    var body: some Scene {
        Window("Tethwork", id: "main") {
            ContentView()
                .environmentObject(appModel)
                .background(MenuBarWindowActionBridge(controller: menuBarController))
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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
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

                Button(LocalizedStringKey(appModel.showingTrash ? "Delete Immediately" : "Move to Trash")) {
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

                Button("Full Content Check") {
                    Task { await appModel.fullSync(recheckContents: true) }
                }
                .help("Read all pinned files again, ignoring the verification cache")
                .disabled(appModel.activeConnection == nil || appModel.syncProgress != nil || appModel.isMergingInitialFiles)

                Button(LocalizedStringKey(appModel.isCurrentPinned ? "Keep Current Folder Online Only" : "Keep Current Folder on This Mac")) {
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
                Toggle("Show Hidden Files", isOn: Binding(get: { appModel.showsHiddenFiles }, set: { appModel.setShowsHiddenFiles($0) }))
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(appModel.connectingConnectionID != nil || appModel.isLoadingDirectory)
                Divider()
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
        }

    }
}
