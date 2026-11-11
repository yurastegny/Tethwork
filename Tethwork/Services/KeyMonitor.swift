import AppKit
import SwiftUI

/// Layout-independent shortcuts: ⌘A/⌃A, Space (Quick Look), Delete, arrows.
@MainActor
final class BrowserKeyMonitor: ObservableObject {
    private var monitor: Any?

    struct Actions {
        var selectAll: () -> Void
        var preview: () -> Void
        var delete: () -> Void
        var arrow: (AppModel.ArrowKey, Bool) -> Void
        var openSelection: () -> Void
        /// False while another surface (e.g. Trash) should keep native key handling.
        var isBrowserActive: () -> Bool = { true }
    }

    func start(actions: Actions) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, window === NSApp.keyWindow,
                  window.identifier?.rawValue == "main", !(window is NSPanel),
                  NSApp.modalWindow == nil, window.attachedSheet == nil else { return event }
            // Ignore when a modal sheet / alert / text field is editing.
            if let first = NSApp.keyWindow?.firstResponder,
               first is NSTextView || first is NSTextField {
                return event
            }

            // Let the Trash table use native arrow / space / ⌘A handling.
            guard actions.isBrowserActive() else { return event }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasCmd = mods.contains(.command)
            let hasCtrl = mods.contains(.control)
            let hasShift = mods.contains(.shift)
            let hasOption = mods.contains(.option)
            let noMods = !hasCmd && !hasCtrl && !hasShift && !hasOption

            // kVK_ANSI_A == 0 — physical A key
            if event.keyCode == 0, (hasCmd || hasCtrl), !hasShift, !hasOption {
                actions.selectAll()
                return nil
            }

            // Space — Quick Look
            if event.keyCode == 49, noMods {
                actions.preview()
                return nil
            }

            // Delete (51) / Forward Delete (117)
            if (event.keyCode == 51 || event.keyCode == 117), noMods {
                actions.delete()
                return nil
            }

            // Return / keypad Enter — open selection
            if (event.keyCode == 36 || event.keyCode == 76), noMods {
                actions.openSelection()
                return nil
            }

            // Arrows: Left 123, Right 124, Down 125, Up 126
            if let arrow = AppModel.ArrowKey(keyCode: event.keyCode),
               !hasCmd, !hasCtrl, !hasOption {
                actions.arrow(arrow, hasShift)
                return nil
            }

            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

enum AppWindowFocus {
    /// After a modal alert, the first click is often eaten by window activation.
    static func reclaim() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "main" && $0.attachedSheet == nil && !($0 is NSPanel)
        }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
