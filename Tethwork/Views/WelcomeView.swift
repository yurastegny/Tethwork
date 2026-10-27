import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Tethwork", systemImage: "externaldrive.badge.icloud")
        } description: {
            Text("Connect a mounted network volume and choose which files to keep on this Mac. Changes sync in both directions.")
        } actions: {
            Button("Connect Volume…") {
                model.showConnectSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
