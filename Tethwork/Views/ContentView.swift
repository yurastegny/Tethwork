import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var keyMonitor = BrowserKeyMonitor()

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .environmentObject(model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Group {
                if model.connectingConnectionID != nil && model.listing == nil {
                    ProgressView("Connecting…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.showingTrash {
                    TrashView()
                } else if model.activeConnection == nil {
                    WelcomeView()
                } else {
                    MainBrowserView()
                }
            }
            .allowsHitTesting(model.connectingConnectionID == nil && !model.isLoadingDirectory)
            .frame(minWidth: 760, minHeight: 580)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(navigationTitle)
            .navigationSubtitle(navigationSubtitle)
        }
        .sheet(isPresented: $model.showConnectSheet) {
            ConnectSheet()
                .environmentObject(model)
        }
        .sheet(item: $model.editingConnection) { conn in
            ConnectSheet(editing: conn)
                .environmentObject(model)
        }
        .onAppear {
            keyMonitor.start(actions: .init(
                selectAll: {
                    guard model.activeConnection != nil else { return }
                    model.selectAll()
                },
                preview: {
                    guard model.activeConnection != nil else { return }
                    model.previewSelected()
                },
                delete: {
                    guard model.activeConnection != nil else { return }
                    model.requestDeleteSelected()
                },
                arrow: { key, extend in
                    guard model.activeConnection != nil else { return }
                    model.handleArrowKey(key, extend: extend)
                },
                openSelection: {
                    guard model.activeConnection != nil else { return }
                    model.openKeyboardSelection()
                },
                isBrowserActive: {
                    model.activeConnection != nil && !model.showingTrash
                        && model.connectingConnectionID == nil
                        && !model.isLoadingDirectory
                        && !model.showConnectSheet && model.editingConnection == nil
                }
            ))
        }
        .onDisappear {
            keyMonitor.stop()
        }
    }

    private var navigationTitle: String {
        if let id = model.connectingConnectionID,
           let connection = model.connections.first(where: { $0.id == id }) { return connection.name }
        if model.showingTrash { return "Trash" }
        if model.activeConnection == nil { return "Tethwork" }
        return model.currentFolderTitle
    }

    private var navigationSubtitle: String {
        if let id = model.connectingConnectionID,
           let connection = model.connections.first(where: { $0.id == id }) { return connection.remotePath }
        if model.showingTrash { return "All servers · kept for \(TrashStore.retentionDays) days" }
        guard let connection = model.activeConnection else { return "" }
        return connection.remotePath
    }
}
