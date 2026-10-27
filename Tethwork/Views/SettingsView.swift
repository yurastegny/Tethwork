import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionsSettingsTab()
                .tabItem { Label("Connections", systemImage: "externaldrive") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 460, minHeight: 320)
    }
}

private struct ConnectionsSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(model.connections) { conn in
                    HStack {
                        Label(conn.name, systemImage: "externaldrive")
                        Spacer()
                        if model.activeConnection?.id == conn.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                    }
                    .tag(conn.id)
                    .contextMenu {
                        Button("Connect") {
                            Task { await model.selectConnection(conn) }
                        }
                        Divider()
                        Button("Edit\u{2026}") {
                            model.editingConnection = conn
                        }
                        Button("Remove", role: .destructive) {
                            Task { await model.deleteConnection(conn.id) }
                        }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack(spacing: 8) {
                Button {
                    model.showConnectSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Connection")

                Button {
                    guard let id = selectedID else { return }
                    Task { await model.deleteConnection(id) }
                    selectedID = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedID == nil)
                .help("Remove Connection")

                Spacer()

                Button("Edit\u{2026}") {
                    guard let id = selectedID,
                          let conn = model.connections.first(where: { $0.id == id }) else { return }
                    model.editingConnection = conn
                }
                .disabled(selectedID == nil)

                Button("Connect") {
                    guard let id = selectedID,
                          let conn = model.connections.first(where: { $0.id == id }) else { return }
                    Task { await model.selectConnection(conn) }
                }
                .disabled({
                    guard let id = selectedID else { return true }
                    return model.activeConnection?.id == id
                }())
            }
            .padding(8)
            .background(.bar)
        }
    }
}

private struct AboutSettingsTab: View {
    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: "1.0")
                Text("Tethwork is a Finder-like browser for network volumes with selective two-way sync.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
