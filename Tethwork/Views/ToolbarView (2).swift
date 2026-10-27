import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pathDropTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            FileBrowserView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBarView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    Task { await model.goUp() }
                } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .disabled(!model.canGoUp)
                .help("Go to enclosing folder")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.revealLocal()
                } label: {
                    Label("Local Folder", systemImage: "folder")
                }
                .help("Reveal local sync folder in Finder")

                Button {
                    model.revealRemote()
                } label: {
                    Label("Network Volume", systemImage: "externaldrive")
                }
                .help("Reveal network volume in Finder")

                Button {
                    Task { await model.fullSync() }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.syncProgress != nil)
                .help(model.syncProgress == nil
                      ? "Sync local copies in the background"
                      : "Sync already in progress")

                Picker("View", selection: $model.viewMode) {
                    Image(systemName: "list.bullet").tag(AppModel.ViewMode.list)
                    Image(systemName: "square.grid.2x2").tag(AppModel.ViewMode.icons)
                    Image(systemName: "rectangle.split.3x1").tag(AppModel.ViewMode.columns)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .labelsHidden()
                .help("View: list, icons, or columns")
                .onChange(of: model.viewMode) { previous, mode in
                    if mode == .columns, previous != .columns {
                        Task { await model.ensureColumns(to: model.currentPath) }
                    } else if mode != .columns, previous == .columns {
                        Task { try? await model.loadDirectory(model.currentPath) }
                    }
                }
            }
        }
        .searchable(text: $model.searchQuery, placement: .toolbar, prompt: Text("Search"))
        .onDeleteCommand {
            model.requestDeleteSelected()
        }
        .onKeyPress(.space) {
            model.previewSelected()
            return .handled
        }
    }

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let crumbs = model.listing?.breadcrumbs ?? []
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        Task { await model.navigateTo(crumb.path, displayName: crumb.name) }
                    } label: {
                        HStack(spacing: 4) {
                            if index == 0 {
                                Image(systemName: "externaldrive")
                            }
                            Text(crumb.name)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    pathDropTarget == (crumb.path.isEmpty ? "__root__" : crumb.path)
                                        ? Color.accentColor.opacity(0.18)
                                        : .clear
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                    .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                    .help(index == 0 ? "Network volume root" : "Open “\(crumb.name)”")
                    .modifier(TethworkFolderDropModifier(
                        targetID: crumb.path.isEmpty ? "__root__" : crumb.path,
                        isDirectory: true,
                        dropTargetID: $pathDropTarget,
                        onDrop: { internalPaths, externalURLs in
                            Task {
                                await model.handleBrowserDrop(
                                    internalPaths: internalPaths,
                                    externalURLs: externalURLs,
                                    toDirectory: crumb.path
                                )
                            }
                        }
                    ))

                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.background)
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let sync = model.syncProgress {
                ProgressView(value: sync.fraction)
                    .controlSize(.small)
                    .frame(width: 88)
                Text("\(sync.done) of \(sync.total)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 56, alignment: .trailing)
                Text("\(sync.percent)%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            } else if let progress = model.importProgress {
                ProgressView(value: progress.fraction)
                    .controlSize(.small)
                    .frame(width: 88)
                Text("\(progress.done) of \(progress.total)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 56, alignment: .trailing)
                Text("\(progress.percent)%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
                Button("Cancel") {
                    model.cancelBackgroundImport()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Cancel background upload")
            }

            Text(objectCountLabel)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 88, alignment: .trailing)

            if let active = model.activeConnection {
                Text(active.localPath)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Local sync path")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var objectCountLabel: String {
        if !model.normalizedSearchQuery.isEmpty {
            let count = model.searchResults.count
            return model.isSearchRunning ? "Searching…" : "\(count) found"
        }
        if model.viewMode == .columns {
            let count = model.columns.last?.entries.count ?? 0
            return "\(count) items"
        }
        let count = model.listing?.entries.count ?? 0
        return "\(count) items"
    }
}
