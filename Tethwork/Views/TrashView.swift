import SwiftUI

/// Browser for the server-side trash across configured network volumes.
/// Items stay here for 15 days and can be restored or removed permanently.
struct TrashView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsErrorDetails = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                if model.isLoadingTrash && model.trashGroups.isEmpty {
                    ProgressView("Loading Trash…")
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.trashItems.isEmpty && model.trashGroups.allSatisfy(\.isAvailable) {
                    ContentUnavailableView(
                        "Trash is Empty",
                        systemImage: "trash",
                        description: Text("Files you delete here or in your local sync folder are kept on the network volume for \(TrashStore.retentionDays) days, then removed automatically.")
                    )
                } else {
                    trashList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsErrorDetails, let error = model.trashErrorMessage {
                ErrorDetailsPanel(title: "Trash operation failed", message: error) {
                    showsErrorDetails = false
                }
            }

            bottomBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: model.trashErrorMessage) { _, error in
            if error == nil { showsErrorDetails = false }
        }
        .toolbar {
            if model.isTrashBusy {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) {
                        trashActivityIndicator
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        trashActivityIndicator
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.restoreTrashSelection()
                } label: {
                    Text("Restore")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .disabled(model.trashSelection.isEmpty || model.isTrashBusy)
                .help("Put the selected items back where they were")

                Button {
                    model.requestDeleteTrashSelection()
                } label: {
                    Text(deleteButtonTitle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .disabled(model.trashSelection.isEmpty || model.isTrashBusy)
                .help("Remove the selected items permanently")

                Button {
                    model.requestEmptyTrash()
                } label: {
                    Text("Empty")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .disabled(model.trashItems.isEmpty || model.isTrashBusy)
                .help("Permanently delete everything in the Trash")

                Button {
                    Task { await model.loadTrash() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .disabled(model.isLoadingTrash || model.isTrashBusy)
                .help("Reload Trash contents")
            }
        }
        .onDeleteCommand {
            model.requestDeleteTrashSelection()
        }
    }

    private var trashActivityIndicator: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .fixedSize()
            .frame(width: 28, height: 28)
            .background(.regularMaterial, in: Circle())
            .clipShape(Circle())
    }

    private var deleteButtonTitle: String {
        let selected = model.selectedTrashItems
        if selected.count > 1 { return "Delete Items" }
        return selected.first?.item.isDirectory == true ? "Delete Folder" : "Delete Item"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text("Deleted files, including local Finder deletions, are kept for \(TrashStore.retentionDays) days.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !model.trashItems.isEmpty {
                Text("\(model.trashItems.count) item\(model.trashItems.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var trashList: some View {
        List(selection: $model.trashSelection) {
            ForEach(model.trashGroups) { group in
                Section {
                    if !group.isAvailable {
                        Label("Network volume unavailable", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    } else if group.visibleItems.isEmpty {
                        Text("No deleted files")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(group.visibleItems) { entry in
                            trashRow(entry)
                                .tag(entry.id)
                                .contextMenu {
                                    Button("Restore") {
                                        Task { await model.restoreTrashItems(ids: [entry.id]) }
                                    }
                                    .disabled(model.isTrashBusy)
                                    Button("Delete Immediately", role: .destructive) {
                                        model.trashSelection = [entry.id]
                                        model.requestDeleteTrashSelection()
                                    }
                                    .disabled(model.isTrashBusy)
                                }
                        }
                    }
                } header: {
                    Label("\(group.connection.name) · \(group.visibleItems.count)", systemImage: "externaldrive")
                        .help(group.connection.remotePath)
                }
            }
        }
        .listStyle(.inset)
    }

    private func trashRow(_ entry: AppModel.TrashEntry) -> some View {
        let item = entry.item
        return HStack(spacing: 6) {
            FileThumbnailView(
                url: model.trashURL(for: entry),
                isDirectory: item.isDirectory,
                size: 24,
                isSelected: model.trashSelection.contains(entry.id),
                // Do not open network Trash payloads merely to draw their icons:
                // Quick Look's server handles can prevent permanent deletion.
                allowsThumbnail: false
            )
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.wasDeletedLocally {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Deleted from the local sync folder on this Mac")
            }
            Spacer(minLength: 12)
            Text(item.originalFolder.isEmpty ? "Volume Root" : item.originalFolder)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)
                .foregroundStyle(.secondary)
                .help("/\(item.originalFolder)")
            Text(FileFormatting.formatDate(item.deletedAt))
                .frame(width: 140, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(item.isDirectory ? "—" : FileFormatting.formatSize(item.size))
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(item.daysRemaining() <= 1 ? "Today" : "In \(item.daysRemaining()) days")
                .frame(width: 95, alignment: .trailing)
                .foregroundStyle(item.daysRemaining() <= 2 ? .red : .secondary)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let error = model.trashErrorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .help(error)
                    .textSelection(.enabled)
                Button("Details…") {
                    showsErrorDetails.toggle()
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Show or hide the full error")
                .accessibilityLabel(Text("Show error details"))
            } else {
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("Total size: \(FileFormatting.formatSize(totalSize))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var totalSize: Int64 {
        model.trashGroups.flatMap(\.items).reduce(0) { $0 + $1.item.size }
    }
}
