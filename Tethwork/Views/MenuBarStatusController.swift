import AppKit
import Combine
import SwiftUI

/// Keep native menu items alive while progress updates. Rebuilding a SwiftUI
/// Menu every 200 ms closes its tracked submenu before a user can select it.
@MainActor
final class MenuBarStatusController: NSObject, ObservableObject, NSMenuDelegate {
    static let menuWidth: CGFloat = 240
    // Leave room for native gutters, submenu arrows and keyboard shortcuts.
    static let titleWidth: CGFloat = menuWidth - 80
    let menu = NSMenu()
    var openMainWindow: (() -> Void)?
    private let model: AppModel
    private let statusItem: NSStatusItem?
    private var subscription: AnyCancellable?
    private var updateSubscription: AnyCancellable?
    private var updateAction: (() -> Void)?
    private var refreshScheduled = false
    private var tracking = false
    private var trackingPauseOptions = false
    private var iconName: String?
    private let status = NSMenuItem()
    private let volume = NSMenuItem()
    private let remaining = NSMenuItem()
    private let speed = NSMenuItem()
    private let resume = NSMenuItem()
    private let pause = NSMenuItem()

    init(model: AppModel, installsStatusItem: Bool = true,
         checkForUpdates: (() -> Void)? = nil, updateAvailability: AnyPublisher<Bool, Never>? = nil) {
        self.model = model
        statusItem = installsStatusItem ? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) : nil
        super.init()
        menu.autoenablesItems = false
        menu.minimumWidth = Self.menuWidth
        menu.font = NSFont.menuFont(ofSize: 0)
        menu.delegate = self
        add(String(localized: "Open Tethwork"), action: #selector(showMainWindow))
        for (id, item) in [("status", status), ("volume", volume), ("remaining", remaining), ("speed", speed)] {
            item.identifier = NSUserInterfaceItemIdentifier(id)
            item.isEnabled = false
            menu.addItem(item)
        }
        resume.title = Self.compactStatus(String(localized: "Resume Sync"))
        resume.target = self
        resume.action = #selector(resumeSync)
        menu.addItem(resume)
        pause.title = Self.compactStatus(String(localized: "Pause Sync"))
        pause.identifier = NSUserInterfaceItemIdentifier("pause")
        let options = NSMenu()
        options.autoenablesItems = false
        options.delegate = self
        for (title, hours) in [("For 2 Hours", 2), ("For 8 Hours", 8), ("For 24 Hours", 24)] {
            let item = NSMenuItem(title: NSLocalizedString(title, comment: "Sync pause duration"), action: #selector(pauseSync(_:)), keyEquivalent: "")
            item.tag = hours
            item.target = self
            options.addItem(item)
        }
        pause.submenu = options
        menu.addItem(pause)
        if let checkForUpdates {
            updateAction = checkForUpdates
            let update = add(String(localized: "Check for Updates…"), action: #selector(checkUpdates))
            update.identifier = NSUserInterfaceItemIdentifier("updates")
            update.isEnabled = false
            updateSubscription = updateAvailability?.receive(on: DispatchQueue.main).sink { [weak update] in
                update?.isEnabled = $0
            }
        }
        let quit = add(String(localized: "Quit Tethwork"), action: #selector(Self.quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        statusItem?.menu = menu
        subscription = model.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
        refresh()
    }

    @discardableResult
    private func add(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: Self.compactStatus(title), action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        // Even in-place text changes may resize a native menu. Freeze those
        // while the pause submenu is tracked, then flush the newest snapshot.
        guard !trackingPauseOptions else { return }
        refresh(allowVisibilityChanges: !tracking)
    }

    private func refresh(allowVisibilityChanges: Bool) {
        status.title = Self.compactStatus(statusText)
        var volumeText: String?
        if let progress = model.syncProgress, let summary = progress.byteSummary {
            volumeText = summary + (progress.isIndeterminate ? "" : " · \(progress.percent)%")
        } else if let progress = model.syncProgress, !progress.isIndeterminate {
            volumeText = String(format: String(localized: "Completed: %lld%%"), Int64(progress.percent))
        } else if let progress = model.importProgress {
            volumeText = String(format: String(localized: "Completed: %lld%%"), Int64(progress.percent))
        }
        update(volume, text: volumeText, allowVisibilityChanges: allowVisibilityChanges)
        update(remaining, text: model.syncProgress?.remainingTimeText, allowVisibilityChanges: allowVisibilityChanges)
        let isTransferring = model.syncProgress?.phase == .transferring || model.importProgress != nil
        update(speed, text: isTransferring ? "↑ \(formattedSpeed(model.uploadBytesPerSecond))   ↓ \(formattedSpeed(model.downloadBytesPerSecond))" : nil,
               allowVisibilityChanges: allowVisibilityChanges)
        resume.isEnabled = model.isSyncPaused
        pause.isEnabled = !model.connections.isEmpty
        if iconName != model.menuBarIconName {
            iconName = model.menuBarIconName
            statusItem?.button?.image = Self.menuIcon(named: model.menuBarIconName)
        }
    }

    private func update(_ item: NSMenuItem, text: String?, allowVisibilityChanges: Bool) {
        item.title = text.map(Self.compactStatus) ?? "—"
        // Keep row geometry stable while the pointer moves into a submenu.
        if allowVisibilityChanges { item.isHidden = text == nil }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === pause.submenu { trackingPauseOptions = true; return }
        guard menu === self.menu else { return }
        refresh(allowVisibilityChanges: true)
        tracking = true
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === pause.submenu {
            trackingPauseOptions = false
            refresh()
            return
        }
        guard menu === self.menu else { return }
        tracking = false
        trackingPauseOptions = false
        refresh()
    }

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let openMainWindow { openMainWindow() }
        else {
            NSApp.windows.first(where: { !($0 is NSPanel) && $0.level == .normal })?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func resumeSync() { model.resumeSync() }
    @objc private func checkUpdates() { updateAction?() }
    @objc private func pauseSync(_ sender: NSMenuItem) { model.pauseSync(hours: Double(sender.tag)) }
    @objc private func quit() { NSApp.terminate(nil) }

    private var statusText: String {
        if let description = model.syncPauseDescription { return description }
        if model.isRemoteUnavailable { return String(localized: "Network volume unavailable") }
        if model.connectionSyncStates.values.contains(where: { $0.error != nil }) || model.errorMessage != nil {
            return String(localized: "Synchronization error")
        }
        if let progress = model.syncProgress {
            if progress.initialUpload != nil {
                if progress.phase == .preparing { return String(localized: "Counting files…") }
                if progress.phase == .finishing { return String(localized: "Final checks…") }
                if progress.phase == .checking { return String(localized: "Checking local copies…") }
                return String(format: String(localized: "%lld of %lld files"), Int64(progress.done), Int64(progress.total))
            }
            switch progress.phase {
            case .preparing: return String(localized: "Preparing files…")
            case .checking: return String(localized: "Checking files…")
            case .finishing: return String(localized: "Syncing…")
            case .transferring:
                return progress.isIndeterminate ? "Transferred \(progress.done) files" : "Syncing \(progress.done) of \(progress.total) · \(progress.percent)%"
            }
        }
        if let progress = model.importProgress { return "Uploading \(progress.done) of \(progress.total) · \(progress.percent)%" }
        return model.activeConnection == nil ? String(localized: "Not connected") : model.statusMessage
    }

    static func compactStatus(_ message: String) -> String {
        let singleLine = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        let candidate = singleLine.count > 48 ? String(singleLine.prefix(47)) + "…" : singleLine
        guard (candidate as NSString).size(withAttributes: attributes).width > titleWidth else { return candidate }
        var prefix = String(singleLine.prefix(47))
        while !prefix.isEmpty, ((prefix + "…") as NSString).size(withAttributes: attributes).width > titleWidth {
            prefix.removeLast()
        }
        return prefix + "…"
    }

    static func menuIcon(named name: String) -> NSImage? {
        // Preserve the original asset's dimensions, aspect ratio and rendering
        // mode. The dropdown's width must not change the menu-bar icon.
        NSImage(named: name)
    }

    private func formattedSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

/// Preserve SwiftUI's scene-opening action even after the main window closes.
struct MenuBarWindowActionBridge: View {
    let controller: MenuBarStatusController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { controller.openMainWindow = { openWindow(id: "main") } }
    }
}
