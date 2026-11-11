import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ColumnsBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargetID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(Array(model.columns.enumerated()), id: \.element.id) { index, column in
                        ColumnPaneView(
                            columnIndex: index,
                            column: column,
                            dropTargetID: $dropTargetID
                        )
                        .frame(width: 220)
                        .frame(maxHeight: .infinity)
                        .id(column.id)

                        Divider()
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .onChange(of: model.columns.map(\.id)) { oldIDs, ids in
                // Scroll only when a column is appended; skip shrink/replace jitter.
                guard ids.count > oldIDs.count, let last = ids.last else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(last, anchor: .trailing)
                }
            }
            .onChange(of: model.scrollToVisibleTick) { _, _ in
                guard let id = model.scrollToVisibleID,
                      let column = model.columns.first(where: { col in
                          col.entries.contains(where: { $0.id == id })
                      })
                else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(column.id, anchor: .trailing)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ColumnPaneView: View {
    @EnvironmentObject private var model: AppModel
    let columnIndex: Int
    let column: AppModel.ColumnState
    @Binding var dropTargetID: String?

    private var columnDropID: String { "column:\(column.path)" }
    private var spaceName: String { "column-marquee-\(columnIndex)-\(column.id)" }

    var body: some View {
        let entries = column.entries

        GeometryReader { viewport in
            Group {
                if column.isLoading && column.entries.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: viewport.size.width, height: viewport.size.height)
                } else if column.entries.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text("Empty Folder")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.clearSelection()
                    }
                    .contextMenu {
                        Button("Refresh") {
                            Task { await model.refresh() }
                        }
                    }
                } else {
                    ZStack(alignment: .top) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                MarqueeSelectable(
                                    spaceName: spaceName,
                                    currentSelection: model.selectedIDs,
                                    onSelect: { ids in
                                        model.applyMarqueeSelection(ids, columnIndex: columnIndex)
                                    },
                                    onEmptyClick: {
                                        model.clearSelection()
                                        model.collapseColumns(to: columnIndex)
                                    }
                                ) {
                                    LazyVStack(spacing: 1) {
                                        ForEach(entries) { entry in
                                            ColumnRowView(
                                                entry: entry,
                                                isSelected: model.selectedIDs.contains(entry.id),
                                                isRevealed: column.revealedChildID == entry.relativePath,
                                                isDropTarget: dropTargetID == entry.id
                                            )
                                            .id(entry.id)
                                            .contentShape(Rectangle())
                                            .marqueeFrame(id: entry.id, in: spaceName)
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
                                                guard model.renamingID != entry.id else { return }
                                                handleTap(entry)
                                            }
                                            .contextMenu {
                                                columnContextMenu(for: entry)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 4)
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: max(viewport.size.height, 1),
                                        alignment: .topLeading
                                    )
                                }
                            }
                            .onChange(of: model.scrollToVisibleTick) { _, _ in
                                guard let id = model.scrollToVisibleID,
                                      column.entries.contains(where: { $0.id == id })
                                else { return }
                                var transaction = Transaction()
                                transaction.animation = nil
                                withTransaction(transaction) {
                                    proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.35))
                                }
                            }
                        }

                        if column.isLoading && column.entries.isEmpty {
                            VStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Updating…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: viewport.size.width, height: viewport.size.height)
                }
            }
            .background(dropTargetID == columnDropID ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            .modifier(TethworkFolderDropModifier(
                targetID: columnDropID,
                isDirectory: true,
                dropTargetID: $dropTargetID,
                onDrop: { internalPaths, externalURLs in
                    Task {
                        await model.handleBrowserDrop(
                            internalPaths: internalPaths,
                            externalURLs: externalURLs,
                            toDirectory: column.path
                        )
                    }
                }
            ))
        }
    }

    private func handleTap(_ entry: FileEntry) {
        if NSEvent.modifierFlags.contains(.shift) {
            model.selectRangeInColumn(columnIndex: columnIndex, to: entry.id)
        } else if NSEvent.modifierFlags.contains(.command) {
            model.toggleInColumn(columnIndex: columnIndex, entry: entry)
        } else {
            model.selectInColumn(columnIndex: columnIndex, entry: entry)
        }
    }

    @ViewBuilder
    private func columnContextMenu(for entry: FileEntry) -> some View {
        let ids: Set<String> = model.selectedIDs.contains(entry.id)
            ? model.selectedIDs
            : [entry.id]
        let selected = model.columns.flatMap(\.entries).filter { ids.contains($0.id) }

        if selected.count == 1, let item = selected.first {
            Button(item.isDirectory ? "Open Folder" : "Open") {
                Task { await model.openEntry(item) }
            }
            Button("Rename") {
                model.requestRename(item)
            }
            if item.isDirectory {
                Button(model.isFavorite(item.relativePath) ? "Remove from Favorites" : "Add to Favorites") {
                    model.toggleFavorite(item.relativePath)
                }
            }
            Button(item.syncMode == .offline ? "Keep Online Only" : "Keep on This Mac") {
                Task { await model.togglePin(item) }
            }
            .disabled(model.isActivelySyncing(item.relativePath))
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

private struct ColumnRowView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.controlActiveState) private var controlActiveState
    let entry: FileEntry
    let isSelected: Bool
    let isRevealed: Bool
    let isDropTarget: Bool

    /// Mac convention: tinted status indicators desaturate to a single gray when the window isn't key.
    private var isKeyWindow: Bool { controlActiveState == .key }

    var body: some View {
        HStack(spacing: 6) {
            FileThumbnailView(
                url: model.previewURL(for: entry),
                isDirectory: entry.isDirectory,
                size: 18,
                isSelected: isSelected,
                modified: entry.modified
            )
            .frame(width: 18, height: 18)
            if model.renamingID == entry.id {
                InlineRenameField(
                    text: $model.renameDraft,
                    isDirectory: entry.isDirectory,
                    font: .systemFont(ofSize: NSFont.systemFontSize),
                    onSubmit: { model.submitRename() },
                    onCancel: { model.cancelRename() }
                )
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            } else {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
            if model.renamingID != entry.id {
                let status = model.displaySyncStatus(for: entry)
                if status.isSyncing {
                    Image(systemName: status.systemImage)
                        .font(.caption2)
                        .foregroundStyle(status.foregroundColor(isSelected: isSelected, isKeyWindow: isKeyWindow))
                        .help(LocalizedStringKey(status.title))
                } else if entry.syncMode == .offline || entry.hasPinnedDescendants ||
                            (entry.folderStorageState != nil && entry.folderStorageState != .onlineOnly) {
                    Image(systemName: status.systemImage)
                        .font(.caption2)
                        .foregroundStyle(status.foregroundColor(isSelected: isSelected, isKeyWindow: isKeyWindow))
                        .help(LocalizedStringKey(status.title))
                }
            }
            if entry.isDirectory, model.renamingID != entry.id {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: model.renamingID == entry.id ? .contain : .combine)
        .accessibilityLabel(Text(entry.name))
        .accessibilityValue(Text(isSelected ? "Selected" : "Not selected"))
        .accessibilityAction(named: Text("Open")) { Task { await model.openEntry(entry) } }
        .accessibilityAction(named: Text("Select")) { model.selectOnly(entry.id) }
    }

    private var rowBackground: Color {
        if isDropTarget {
            return BrowserSelectionStyle.dropTargetFill
        }
        if isSelected {
            return BrowserSelectionStyle.fill
        }
        if isRevealed {
            return BrowserSelectionStyle.revealedFill
        }
        return .clear
    }
}

/// Accepts Tethwork internal moves and Finder file/folder drops.
struct TethworkFolderDropModifier: ViewModifier {
    let targetID: String
    let isDirectory: Bool
    @Binding var dropTargetID: String?
    var onDrop: (_ internalPaths: [String], _ externalURLs: [URL]) -> Void

    @State private var isTargeted = false

    private static let acceptedTypes: [UTType] = [
        .fileURL,
        .plainText,
        .utf8PlainText,
        .text
    ]

    func body(content: Content) -> some View {
        if isDirectory {
            content
                .onDrop(of: Self.acceptedTypes, isTargeted: $isTargeted) { providers in
                    Task { @MainActor in
                        let internalPaths = await TethworkDrag.loadAll(from: providers)
                        let externalURLs = internalPaths.isEmpty
                            ? await TethworkDrag.loadFileURLs(from: providers)
                            : []
                        guard !internalPaths.isEmpty || !externalURLs.isEmpty else { return }
                        dropTargetID = nil
                        onDrop(internalPaths, externalURLs)
                    }
                    return true
                }
                .onChange(of: isTargeted) { _, targeted in
                    if targeted {
                        dropTargetID = targetID
                    } else if dropTargetID == targetID {
                        dropTargetID = nil
                    }
                }
        } else {
            content
        }
    }
}
