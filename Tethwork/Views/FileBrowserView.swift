import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let netSyncDragPrefix = "tethwork-path:"

enum TethworkDrag {
    static func encode(_ relativePath: String) -> String {
        netSyncDragPrefix + relativePath
    }

    static func decode(_ value: String) -> String? {
        guard value.hasPrefix(netSyncDragPrefix) else { return nil }
        return String(value.dropFirst(netSyncDragPrefix.count))
    }

    static func decodeAll(_ values: [String]) -> [String] {
        values.compactMap(decode)
    }

    @MainActor
    static func loadAll(from providers: [NSItemProvider]) async -> [String] {
        var results: [String] = []
        for provider in providers {
            if let path = await loadInternalPath(from: provider) {
                results.append(path)
            }
        }
        return results
    }

    @MainActor
    static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var results: [URL] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                results.append(url)
            }
        }
        return results
    }

    @MainActor
    private static func loadInternalPath(from provider: NSItemProvider) async -> String? {
        if provider.canLoadObject(ofClass: NSString.self) {
            let raw: String? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    continuation.resume(returning: object as? String)
                }
            }
            if let raw, let path = decode(raw) {
                return path
            }
        }
        return nil
    }

    @MainActor
    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        // Prefer fileURL providers from Finder.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else if let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else if let string = item as? String {
                        continuation.resume(returning: URL(fileURLWithPath: string))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let url, url.isFileURL { return url.standardizedFileURL }
        }

        if provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    continuation.resume(returning: object)
                }
            }
            if let url, url.isFileURL { return url.standardizedFileURL }
        }
        return nil
    }
}

struct FileBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var dropTargetID: String?
    /// Icons currently realized by LazyVGrid — used to remember top-of-viewport.
    @State private var visibleIconPositions: [String: Int] = [:]

    /// Mac convention: tinted status indicators desaturate to a single gray when the window isn't key.
    private var isKeyWindow: Bool { controlActiveState == .key }

    var body: some View {
        let allEntries = model.listing?.entries ?? []
        let entries = model.displayedEntries(from: allEntries)
        let isSearching = !model.normalizedSearchQuery.isEmpty

        Group {
            if isSearching {
                if model.isSearchRunning && entries.isEmpty {
                    ProgressView("Searching…")
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty && !model.isSearchRunning {
                    ContentUnavailableView(
                        "No results",
                        systemImage: "magnifyingglass",
                        description: Text("No items matching “\(model.normalizedSearchQuery)” in this folder or its subfolders.")
                    )
                } else if model.viewMode == .icons {
                    iconsGrid(entries)
                } else {
                    listView(entries)
                }
            } else if model.viewMode == .columns {
                ColumnsBrowserView()
            } else if allEntries.isEmpty && !model.isLoadingDirectory {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("Open another folder using the path above. ⌘-click and ⇧-click for multiple selection. Space for Quick Look.")
                )
            } else if model.viewMode == .icons {
                iconsGrid(entries)
            } else {
                listView(entries)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if dropTargetID == "browser-current" {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .modifier(TethworkFolderDropModifier(
            targetID: "browser-current",
            isDirectory: true,
            dropTargetID: $dropTargetID,
            onDrop: { internalPaths, externalURLs in
                Task {
                    await model.handleBrowserDrop(
                        internalPaths: internalPaths,
                        externalURLs: externalURLs,
                        toDirectory: model.currentPath
                    )
                }
            }
        ))
        .contextMenu {
            Button("Refresh") {
                Task { await model.refresh() }
            }
        }
        .overlay {
            if model.isLoadingDirectory && entries.isEmpty {
                ZStack {
                    Color.primary.opacity(0.06)
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text(model.loadingFolderName.map { "Opening “\($0)”…" } ?? "Opening…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .allowsHitTesting(model.isLoadingDirectory)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func listView(_ entries: [FileEntry]) -> some View {
        outlineTable(rows: model.listOutlineRows())
            .onAppear { _ = entries }
    }

    private func outlineTable(rows: [OutlineRow]) -> some View {
        Table(of: OutlineRow.self, selection: $model.selectedIDs) {
            TableColumn("Name") { row in
                outlineNameCell(row)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Size") { row in
                let selected = model.selectedIDs.contains(row.id)
                Text(row.entry.isDirectory ? "—" : FileFormatting.formatSize(row.entry.size))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
            }
            .width(80)

            TableColumn("Status") { row in
                let selected = model.selectedIDs.contains(row.id)
                let status = model.displaySyncStatus(for: row.entry)
                Label(LocalizedStringKey(status.title), systemImage: status.systemImage)
                    .foregroundStyle(status.foregroundColor(isSelected: selected, isKeyWindow: isKeyWindow))
            }
            .width(130)

            TableColumn("Date Modified") { row in
                let selected = model.selectedIDs.contains(row.id)
                Text(FileFormatting.formatDate(row.entry.modified))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
            }
            .width(150)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .itemProvider {
                        NSItemProvider(object: TethworkDrag.encode(row.entry.relativePath) as NSString)
                    }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            multiSelectContextMenu(ids: ids, entries: rows.map(\.entry))
        } primaryAction: { ids in
            if ids.count == 1,
               let id = ids.first,
               let entry = rows.first(where: { $0.id == id })?.entry {
                Task { await model.openEntry(entry) }
            } else if !ids.isEmpty {
                model.previewSelected()
            }
        }
        .onChange(of: model.selectedIDs) { _, newValue in
            if model.lastClickedID.map({ newValue.contains($0) }) != true {
                model.lastClickedID = rows.first(where: { newValue.contains($0.id) })?.id
            }
            if model.viewMode == .list, model.renamingID == nil {
                BrowserScrollSupport.focusBrowserTable()
            }
        }
        .onChange(of: model.scrollToVisibleTick) { _, _ in
            guard let id = model.scrollToVisibleID,
                  let index = rows.firstIndex(where: { $0.id == id })
            else { return }
            let shouldFocus = model.renamingID == nil
            DispatchQueue.main.async {
                BrowserScrollSupport.scrollTableRowVisible(index, focus: shouldFocus)
            }
        }
        .onChange(of: model.scrollRestoreTick) { _, _ in
            restoreListScroll(rows: rows)
            DispatchQueue.main.async {
                BrowserScrollSupport.applyListRowHeight(32)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                BrowserScrollSupport.applyListRowHeight(32)
                guard model.renamingID == nil else { return }
                BrowserScrollSupport.focusBrowserTable()
            }
        }
    }

    @ViewBuilder
    private func outlineNameCell(_ row: OutlineRow) -> some View {
        let entry = row.entry
        HStack(spacing: 4) {
            Color.clear
                .frame(width: CGFloat(row.depth) * 14)

            if entry.isDirectory {
                Button {
                    Task { await model.toggleFolderExpanded(entry) }
                } label: {
                    Group {
                        if model.isFolderExpanding(entry.relativePath) {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: model.isFolderExpanded(entry.relativePath)
                                  ? "chevron.down"
                                  : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(
                                    model.selectedIDs.contains(entry.id)
                                        ? Color.white.opacity(0.9)
                                        : Color.secondary
                                )
                        }
                    }
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(model.isFolderExpanded(entry.relativePath) ? "Collapse" : "Expand")
            } else {
                Color.clear.frame(width: 12, height: 12)
            }

            FileThumbnailView(
                url: model.previewURL(for: entry),
                isDirectory: entry.isDirectory,
                // Keep the icon column and the start of every filename aligned.
                size: 28,
                isSelected: model.selectedIDs.contains(entry.id),
                modified: entry.modified
            )
            if model.renamingID == entry.id {
                InlineRenameField(
                    text: $model.renameDraft,
                    isDirectory: entry.isDirectory,
                    onSubmit: { model.submitRename() },
                    onCancel: { model.cancelRename() }
                )
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                .id("rename-list-\(entry.id)")
            } else {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(
                        model.selectedIDs.contains(entry.id)
                            ? Color.white
                            : (isKeyWindow ? Color.primary : Color.secondary)
                    )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(dropTargetID == entry.id ? Color.accentColor.opacity(0.18) : .clear)
        )
        .onDrag {
            NSItemProvider(object: TethworkDrag.encode(entry.relativePath) as NSString)
        }
        .modifier(TethworkFolderDropModifier(
            targetID: entry.id,
            isDirectory: entry.isDirectory,
            dropTargetID: $dropTargetID,
            onDrop: { internalPaths, externalURLs in
                Task {
                    await model.handleBrowserDrop(
                        internalPaths: internalPaths,
                        externalURLs: externalURLs,
                        toDirectory: entry.relativePath
                    )
                }
            }
        ))
    }

    private func restoreListScroll(rows: [OutlineRow]) {
        guard let anchor = model.scrollRestoreAnchorID,
              let index = rows.firstIndex(where: { $0.id == anchor })
        else { return }
        guard index > 0 else { return }
        for delayMs in [0, 16, 50] as [Int] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                BrowserScrollSupport.scrollTableRowToTop(index)
            }
        }
    }

    private func iconsGrid(_ entries: [FileEntry]) -> some View {
        GeometryReader { viewport in
            let columnsPerRow = max(1, Int((viewport.size.width - 20) / 132))
            ScrollViewReader { proxy in
                ScrollView {
                    MarqueeSelectable(
                        spaceName: "icons-marquee",
                        currentSelection: model.selectedIDs,
                        onSelect: { ids in
                            model.applyMarqueeSelection(ids)
                        },
                        onEmptyClick: {
                            model.clearSelection()
                        }
                    ) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 120, maximum: 128), spacing: 8)],
                            spacing: 10
                        ) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                iconCell(entry, entries: entries)
                                    .id(entry.id)
                                    .marqueeFrame(id: entry.id, in: "icons-marquee")
                                    .onAppear {
                                        visibleIconPositions[entry.id] = index
                                        syncIconsScrollAnchor(entries: entries)
                                    }
                                    .onDisappear {
                                        visibleIconPositions.removeValue(forKey: entry.id)
                                        syncIconsScrollAnchor(entries: entries)
                                    }
                            }
                        }
                        .padding(10)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: max(viewport.size.height, 1),
                            alignment: .topLeading
                        )
                    }
                }
                // Remount per folder so restore starts from a clean top, then scrolls to anchor.
                .id(model.currentPath)
                .onChange(of: model.scrollToVisibleTick) { _, _ in
                    guard let id = model.scrollToVisibleID else { return }
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: model.scrollRestoreTick) { _, _ in
                    restoreIconsScroll(proxy: proxy, entries: entries, columnsPerRow: columnsPerRow)
                }
                .onAppear {
                    restoreIconsScroll(proxy: proxy, entries: entries, columnsPerRow: columnsPerRow)
                }
            }
            .onAppear {
                model.iconsColumnsPerRow = columnsPerRow
            }
            .onChange(of: columnsPerRow) { _, value in
                model.iconsColumnsPerRow = value
            }
            .onChange(of: model.currentPath) { _, _ in
                visibleIconPositions = [:]
            }
        }
    }

    private func syncIconsScrollAnchor(entries: [FileEntry]) {
        guard model.viewMode == .icons else { return }
        let topID = visibleIconPositions.min(by: { $0.value < $1.value })?.key
        model.noteIconsScroll(topVisibleID: topID)
    }

    private func restoreIconsScroll(
        proxy: ScrollViewProxy,
        entries: [FileEntry],
        columnsPerRow: Int
    ) {
        guard model.viewMode == .icons else { return }
        guard let anchor = model.scrollRestoreAnchorID,
              let index = entries.firstIndex(where: { $0.id == anchor }),
              index > 0
        else { return }

        // LazyVGrid only realizes nearby cells — walk down in steps so the target exists.
        let step = max(columnsPerRow * 3, 6)
        var waypoints: [String] = []
        var cursor = 0
        while cursor < index {
            waypoints.append(entries[cursor].id)
            cursor += step
        }
        waypoints.append(anchor)

        Task { @MainActor in
            let path = model.currentPath
            for id in waypoints {
                guard model.currentPath == path else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(id, anchor: .top)
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            guard model.currentPath == path else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func iconCell(_ entry: FileEntry, entries: [FileEntry]) -> some View {
        let selected = model.selectedIDs.contains(entry.id)
        let renaming = model.renamingID == entry.id
        VStack(spacing: 4) {
            FileThumbnailView(
                url: model.previewURL(for: entry),
                isDirectory: entry.isDirectory,
                size: 96,
                isSelected: selected,
                modified: entry.modified
            )
            if renaming {
                InlineRenameField(
                    text: $model.renameDraft,
                    isDirectory: entry.isDirectory,
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    alignment: .center,
                    onSubmit: { model.submitRename() },
                    onCancel: { model.cancelRename() }
                )
                .frame(width: 110, height: 22)
                .id("rename-icon-\(entry.id)")
            } else {
                Text(FileFormatting.displayName(entry.name, isDirectory: entry.isDirectory))
                    .font(.system(size: 14))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                let status = model.displaySyncStatus(for: entry)
                Label(LocalizedStringKey(status.title), systemImage: status.systemImage)
                    .font(.caption2)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(status.foregroundColor(isSelected: selected, isKeyWindow: isKeyWindow))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 124)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBackground(for: entry))
        )
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: TethworkDrag.encode(entry.relativePath) as NSString)
        }
        .modifier(TethworkFolderDropModifier(
            targetID: entry.id,
            isDirectory: entry.isDirectory,
            dropTargetID: $dropTargetID,
            onDrop: { internalPaths, externalURLs in
                Task {
                    await model.handleBrowserDrop(
                        internalPaths: internalPaths,
                        externalURLs: externalURLs,
                        toDirectory: entry.relativePath
                    )
                }
            }
        ))
        .onTapGesture(count: 2) {
            guard model.renamingID == nil else { return }
            Task { await model.openEntry(entry) }
        }
        .onTapGesture(count: 1) {
            // Clicking another icon commits rename via selectOnly/endRenameIfNeeded.
            guard model.renamingID != entry.id else { return }
            if NSEvent.modifierFlags.contains(.shift) {
                model.selectRange(to: entry.id)
            } else if NSEvent.modifierFlags.contains(.command) {
                model.toggleSelection(entry.id)
            } else {
                model.selectOnly(entry.id)
            }
        }
        .contextMenu {
            multiSelectContextMenu(
                ids: model.selectedIDs.contains(entry.id) ? model.selectedIDs : [entry.id],
                entries: entries
            )
        }
        .accessibilityElement(children: renaming ? .contain : .combine)
        .accessibilityLabel(Text(entry.name))
        .accessibilityValue(Text(selected ? "Selected" : "Not selected"))
        .accessibilityAction(named: Text("Open")) { Task { await model.openEntry(entry) } }
        .accessibilityAction(named: Text("Select")) { model.selectOnly(entry.id) }
    }

    private func iconBackground(for entry: FileEntry) -> Color {
        if dropTargetID == entry.id {
            return BrowserSelectionStyle.dropTargetFill
        }
        if model.selectedIDs.contains(entry.id) {
            return BrowserSelectionStyle.fill
        }
        return .clear
    }

    private func dragPayload(for entry: FileEntry) -> String {
        if model.selectedIDs.contains(entry.id), model.selectedIDs.count > 1 {
            // Primary payload is the clicked item; moveEntries expands to full selection.
            return TethworkDrag.encode(entry.relativePath)
        }
        return TethworkDrag.encode(entry.relativePath)
    }

    @ViewBuilder
    private func multiSelectContextMenu(ids: Set<String>, entries: [FileEntry]) -> some View {
        let selected = entries.filter { ids.contains($0.id) }
        if selected.count == 1, let entry = selected.first {
            Button(LocalizedStringKey(entry.isDirectory ? "Open Folder" : "Open")) {
                Task { await model.openEntry(entry) }
            }
            Button("Rename") {
                model.requestRename(entry)
            }
            if entry.isDirectory {
                Button(LocalizedStringKey(model.isFavorite(entry.relativePath) ? "Remove from Favorites" : "Add to Favorites")) {
                    model.toggleFavorite(entry.relativePath)
                }
            }
            Button(LocalizedStringKey(entry.syncMode == .offline ? "Keep Online Only" : "Keep on This Mac")) {
                Task { await model.togglePin(entry) }
            }
            .disabled(model.isActivelySyncing(entry.relativePath))
        }
        Divider()
        Button("Refresh") {
            Task { await model.refresh() }
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            model.selectedIDs = ids
            model.requestDeleteSelected()
        }
    }
}

private struct FolderDropModifier: ViewModifier {
    let entry: FileEntry
    @Binding var dropTargetID: String?
    let onDrop: (_ internalPaths: [String], _ externalURLs: [URL]) -> Void

    func body(content: Content) -> some View {
        content.modifier(TethworkFolderDropModifier(
            targetID: entry.id,
            isDirectory: entry.isDirectory,
            dropTargetID: $dropTargetID,
            onDrop: onDrop
        ))
    }
}

enum FileFormatting {
    /// Keeps the extension visible when the name is long (Finder-style middle ellipsis).
    static func displayName(_ name: String, isDirectory: Bool) -> String {
        if isDirectory { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        guard !ext.isEmpty, !base.isEmpty else { return name }
        // Soft limit for icon captions; truncationMode(.middle) still applies visually.
        if name.count <= 40 { return name }
        let keep = 18
        if base.count <= keep { return name }
        let prefix = String(base.prefix(keep))
        return "\(prefix)….\(ext)"
    }

    static func formatSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 {
            return "\(Int(value)) \(units[idx])"
        }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[idx])
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }
}

/// Matches `Table` / AppKit selected-row fill (accent strip).
enum BrowserSelectionStyle {
    static var fill: Color {
        Color(nsColor: .selectedContentBackgroundColor)
    }

    static var dropTargetFill: Color {
        Color(nsColor: .selectedContentBackgroundColor).opacity(0.55)
    }

    static var revealedFill: Color {
        Color.primary.opacity(0.06)
    }
}
