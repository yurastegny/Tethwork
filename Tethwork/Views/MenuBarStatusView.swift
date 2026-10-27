import SwiftUI

struct MenuBarStatusView: View {
    @EnvironmentObject var appModel: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("Open Tethwork") {
            NSApp.setActivationPolicy(.regular)
            let existing = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.level == .normal }
            if let existing {
                existing.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(statusText) {}
            .disabled(true)

        if let percent = activePercent {
            Button("Completed: \(percent)%") {}
                .disabled(true)
            Button("↑ \(formattedSpeed(appModel.uploadBytesPerSecond))   ↓ \(formattedSpeed(appModel.downloadBytesPerSecond))") {}
                .disabled(true)
        }

        Button("Resume Sync") {
            appModel.resumeSync()
        }
        .disabled(!appModel.isSyncPaused)

        Menu("Pause Sync") {
            Button("For 2 Hours") { appModel.pauseSync(hours: 2) }
            Button("For 8 Hours") { appModel.pauseSync(hours: 8) }
            Button("For 24 Hours") { appModel.pauseSync(hours: 24) }
        }
        .disabled(appModel.activeConnection == nil)

        Button("Quit Tethwork") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        if let desc = appModel.syncPauseDescription {
            return desc
        }
        if let p = appModel.syncProgress {
            if p.phase != .transferring { return appModel.statusMessage }
            if p.isIndeterminate { return "Transferred \(p.done) files" }
            return "Syncing \(p.done) of \(p.total) · \(p.percent)%"
        }
        if let p = appModel.importProgress {
            return "Uploading \(p.done) of \(p.total) · \(p.percent)%"
        }
        if appModel.activeConnection != nil {
            return appModel.statusMessage
        }
        return "Not connected"
    }

    private var activePercent: Int? {
        if let progress = appModel.syncProgress { return progress.isIndeterminate ? nil : progress.percent }
        if let progress = appModel.importProgress { return progress.percent }
        return nil
    }

    private func formattedSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 KB/s" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(bytesPerSecond),
            countStyle: .file
        ) + "/s"
    }
}
