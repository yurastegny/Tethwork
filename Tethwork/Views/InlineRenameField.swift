import AppKit
import SwiftUI

/// Finder-style inline rename field: focuses immediately, selects basename,
/// Return commits, Escape cancels, resigning first responder commits.
struct InlineRenameField: NSViewRepresentable {
    @Binding var text: String
    var isDirectory: Bool
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var alignment: NSTextAlignment = .left
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> RenameNSTextField {
        let field = RenameNSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.focusRingType = .default
        field.font = font
        field.alignment = alignment
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.onCancel = { [weak coordinator = context.coordinator] in
            coordinator?.finish(submit: false)
        }
        context.coordinator.field = field
        context.coordinator.scheduleFocus()
        return field
    }

    func updateNSView(_ nsView: RenameNSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.font = font
        nsView.alignment = alignment
        if nsView.currentEditor() == nil, nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Table / LazyVGrid may steal first responder right after mount — reclaim it.
        context.coordinator.scheduleFocusIfNeeded()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameField
        weak var field: RenameNSTextField?
        private var didFinish = false
        private var isArmed = false
        private var focusWorkItem: DispatchWorkItem?
        private var outsideClickMonitor: Any?

        init(_ parent: InlineRenameField) {
            self.parent = parent
        }

        deinit {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
            }
        }

        func scheduleFocus() {
            focusWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.claimFocus(arm: true)
            }
            focusWorkItem = work
            // Wait for context-menu dismissal + SwiftUI layout to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func scheduleFocusIfNeeded() {
            guard !didFinish, !isArmed else { return }
            guard let field, field.currentEditor() == nil else { return }
            scheduleFocus()
        }

        private func claimFocus(arm: Bool) {
            guard !didFinish, let field else { return }
            guard let window = field.window else {
                scheduleFocus()
                return
            }
            window.makeFirstResponder(field)
            selectBasename(in: field)
            if arm {
                // Ignore end-editing storms from Table focus fights for a beat.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, !self.didFinish else { return }
                    self.isArmed = true
                    self.installOutsideClickMonitor()
                }
            }
        }

        private func installOutsideClickMonitor() {
            removeOutsideClickMonitor()
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self, !self.didFinish, let field = self.field else { return event }
                if Self.click(event, isInside: field) {
                    return event
                }
                // Commit rename first, then let the click select the other icon/folder.
                self.finish(submit: true)
                return event
            }
        }

        private func removeOutsideClickMonitor() {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
                self.outsideClickMonitor = nil
            }
        }

        private static func click(_ event: NSEvent, isInside field: NSView) -> Bool {
            guard let content = field.window?.contentView else { return false }
            var view: NSView? = content.hitTest(event.locationInWindow)
            while let current = view {
                if current === field { return true }
                view = current.superview
            }
            return false
        }

        func selectBasename(in field: NSTextField) {
            field.selectText(nil)
            guard !parent.isDirectory else { return }
            let name = field.stringValue as NSString
            let base = name.deletingPathExtension as NSString
            guard base.length > 0, base.length < name.length,
                  let editor = field.currentEditor()
            else { return }
            editor.selectedRange = NSRange(location: 0, length: base.length)
        }

        func finish(submit: Bool) {
            guard !didFinish else { return }
            didFinish = true
            focusWorkItem?.cancel()
            removeOutsideClickMonitor()
            if let field {
                parent.text = field.stringValue
            }
            if submit {
                parent.onSubmit()
            } else {
                parent.onCancel()
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !didFinish else { return }
            if !isArmed {
                // Spurious resign (table/scroll stole focus) — take it back.
                scheduleFocus()
                return
            }
            // Defer: SwiftUI Table/LazyVGrid often dismantles the field during a
            // refresh. If the view is gone, a new field will remount — don't commit.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didFinish else { return }
                guard let field = self.field, field.window != nil else { return }
                if field.currentEditor() != nil { return }
                self.finish(submit: true)
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(submit: false)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                finish(submit: true)
                return true
            }
            return false
        }
    }
}

final class RenameNSTextField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
