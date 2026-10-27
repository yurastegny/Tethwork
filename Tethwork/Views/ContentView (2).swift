import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var keyMonitor = BrowserKeyMonitor()

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            if model.activeConnection == nil {
                WelcomeView()
            } else {
                MainBrowserView()
            }
        }
        .navigationTitle(model.activeConnection == nil ? "Tethwork" : model.currentFolderTitle)
        .navigationSubtitle(model.activeConnection?.remotePath ?? "")
        .sheet(isPresented: $model.showConnectSheet) {
            ConnectSheet()
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
                }
            ))
        }
        .onDisappear {
            keyMonitor.stop()
        }
    }
}
