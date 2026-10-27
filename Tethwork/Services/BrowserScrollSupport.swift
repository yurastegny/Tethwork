import AppKit
import SwiftUI

enum BrowserScrollSupport {
    /// Scroll the file browser `Table` so `rowIndex` is visible.
    /// Set `focus` to false while inline-renaming so the table does not steal the text field.
    @MainActor
    static func scrollTableRowVisible(_ rowIndex: Int, focus: Bool = true) {
        guard rowIndex >= 0 else { return }
        guard let table = preferredBrowserTable() else { return }
        if focus {
            self.focus(table)
        }
        guard rowIndex < table.numberOfRows else { return }
        table.scrollRowToVisible(rowIndex)
    }

    /// Put `rowIndex` at the top of the file list without touching clip-view insets
    /// (raw `clip.scroll(to:)` pulls rows under the column header).
    @MainActor
    static func scrollTableRowToTop(_ rowIndex: Int) {
        guard rowIndex >= 0 else { return }
        guard let table = preferredBrowserTable() else { return }
        focus(table)
        guard rowIndex < table.numberOfRows else { return }
        if rowIndex == 0 {
            scrollTableToTop(table)
            return
        }
        let rowRect = table.rect(ofRow: rowIndex)
        table.scroll(NSPoint(x: 0, y: rowRect.minY))
    }

    @MainActor
    static func focusBrowserTable() {
        // Never yank focus away from an inline rename field.
        if let first = NSApp.keyWindow?.firstResponder,
           first is NSTextView || first is NSTextField {
            return
        }
        guard let table = preferredBrowserTable() else { return }
        focus(table)
    }

    /// Compact list-view rows (SwiftUI `Table` ignores SwiftUI spacing for NSTableView height).
    @MainActor
    static func applyListRowHeight(_ height: CGFloat) {
        guard let table = preferredBrowserTable() else { return }
        if abs(table.rowHeight - height) > 0.5 {
            table.rowHeight = height
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }
    }

    /// First fully/partially visible data row in the file list (not the sidebar).
    @MainActor
    static func firstVisibleRowIndex() -> Int? {
        guard let table = preferredBrowserTable(), table.numberOfRows > 0 else { return nil }
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return 0 }
        return rows.location
    }

    @MainActor
    private static func scrollTableToTop(_ table: NSTableView) {
        guard table.numberOfRows > 0 else { return }
        let rowRect = table.rect(ofRow: 0)
        table.scroll(NSPoint(x: 0, y: rowRect.minY))
    }

    @MainActor
    private static func focus(_ table: NSTableView) {
        // Keep system row highlight (full accent strip when first responder).
        if table.selectionHighlightStyle != .regular {
            table.selectionHighlightStyle = .regular
        }
        table.window?.makeFirstResponder(table)
    }

    /// File browser `Table` has several columns; sidebar `List` is typically 1-column.
    @MainActor
    private static func preferredBrowserTable() -> NSTableView? {
        let windows = NSApp.windows.filter(\.isVisible)
        var candidates: [NSTableView] = []
        for window in windows {
            collectTables(from: window.contentView, into: &candidates)
        }
        let browserTables = candidates.filter { $0.numberOfColumns >= 3 }
        let keyTables = browserTables.filter { $0.window?.isKeyWindow == true }
        let pool = keyTables.isEmpty ? browserTables : keyTables
        return pool.max { lhs, rhs in
            lhs.visibleRect.height * lhs.visibleRect.width
                < rhs.visibleRect.height * rhs.visibleRect.width
        }
    }

    /// Soft-reset sidebar `List` scroll if it was nudged by a mistaken browser restore.
    @MainActor
    static func resetSidebarListScroll() {
        let windows = NSApp.windows.filter(\.isVisible)
        var tables: [NSTableView] = []
        for window in windows {
            collectTables(from: window.contentView, into: &tables)
        }
        for table in tables where table.numberOfColumns <= 1 {
            guard table.numberOfRows > 0 else { continue }
            let rowRect = table.rect(ofRow: 0)
            table.scroll(NSPoint(x: 0, y: rowRect.minY))
        }
    }

    private static func collectTables(from view: NSView?, into result: inout [NSTableView]) {
        guard let view else { return }
        if let table = view as? NSTableView {
            result.append(table)
        }
        for sub in view.subviews {
            collectTables(from: sub, into: &result)
        }
    }
}
