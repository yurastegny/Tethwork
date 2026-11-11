import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pathDropTarget: String?
    @State private var isSearchExpanded = false
    @State private var showsTransferDetails = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            FileBrowserView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsTransferDetails, let progress = model.syncProgress {
                Divider()
                TransferDetails(progress: progress)
                    .environmentObject(model)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            StatusBarView(showsCompactSyncProgress: !showsTransferDetails)
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
                    if model.syncProgress != nil {
                        showsTransferDetails.toggle()
                    } else {
                        Task { await model.fullSync() }
                    }
                } label: {
                    if model.syncProgress != nil {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                            .allowsHitTesting(false)
                            .accessibilityLabel("Background synchronization")
                    } else {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .help(model.syncProgress == nil
                      ? "Sync local copies in the background"
                      : "Background synchronization · Click for details")

                Picker("View", selection: Binding(get: { model.viewMode }, set: { model.setViewMode($0) })) {
                    Label("List", systemImage: "list.bullet").tag(AppModel.ViewMode.list)
                    Label("Icons", systemImage: "square.grid.2x2").tag(AppModel.ViewMode.icons)
                    Label("Columns", systemImage: "rectangle.split.3x1").tag(AppModel.ViewMode.columns)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .labelsHidden()
                .help("View: list, icons, or columns")

                if isSearchExpanded || !model.searchQuery.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search", text: $model.searchQuery)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .onExitCommand {
                                model.searchQuery = ""
                                isSearchExpanded = false
                            }
                        Button {
                            model.searchQuery = ""
                            isSearchExpanded = false
                        } label: {
                            Label("Close Search", systemImage: "xmark")
                        }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .help("Close search")
                    }
                    .font(.system(size: 13))
                    .frame(width: 250)
                    .padding(.horizontal, 12)
                    .onAppear { isSearchFocused = true }
                } else {
                    Button {
                        isSearchExpanded = true
                        isSearchFocused = true
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("f", modifiers: [.command])
                    .help("Search (⌘F)")
                }
            }
        }
        .onDeleteCommand {
            model.requestDeleteSelected()
        }
        .onChange(of: model.syncProgress == nil) { _, isFinished in
            if isFinished { showsTransferDetails = false }
        }
        .onChange(of: model.syncProgress?.initialUpload != nil, initial: true) { _, isInitialUpload in
            if isInitialUpload { showsTransferDetails = true }
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
                    .contextMenu {
                        Button(model.isFavorite(crumb.path) ? "Remove from Favorites" : "Add to Favorites") {
                            model.toggleFavorite(crumb.path)
                        }
                    }
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

private struct TransferDetails: View {
    @EnvironmentObject private var model: AppModel
    let progress: AppModel.SyncProgress

    var body: some View {
        HStack(spacing: 12) {
            if progress.isIndeterminate {
                ProgressView()
                    .controlSize(.regular)
                    .frame(width: 24)
            } else {
                Image(systemName: progress.direction == .download ? "arrow.down.circle" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 23))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .fontWeight(.semibold)
                    Spacer(minLength: 12)
                    if !progress.isIndeterminate {
                        if progress.initialUpload != nil {
                            Text("\(progress.percent)%")
                                .monospacedDigit()
                        } else {
                            Text("\(progress.done) of \(progress.total) files · \(progress.percent)%")
                                .monospacedDigit()
                        }
                    } else if progress.phase == .transferring {
                        Text("\(progress.done) files transferred")
                            .monospacedDigit()
                    }
                }
                if let summary = progress.byteSummary {
                    HStack {
                        Text(summary)
                        Spacer(minLength: 12)
                        if progress.phase == .checking || progress.phase == .finishing {
                            Text("\(progress.done) of \(progress.total) items")
                        } else {
                            Text("\(progress.done) of \(progress.total) files")
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
                if let remaining = progress.remainingTimeText {
                    Text(remaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let deferred = progress.initialUpload?.deferredFiles, deferred > 0 {
                    Text(String(format: String(localized: "Deferred changing files: %lld"), Int64(deferred)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail)
                if !progress.isIndeterminate {
                    ProgressView(value: progress.fraction)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var title: String {
        switch progress.phase {
        case .preparing:
            if progress.initialUpload != nil { return String(localized: "Counting files…") }
            return progress.direction == .download ? "Preparing download…" : "Preparing files…"
        case .checking:
            return "Checking local copies…"
        case .finishing:
            if progress.initialUpload != nil { return String(localized: "Final checks…") }
            return "Finishing download…"
        case .transferring:
            switch progress.direction {
            case .download: return "Downloading files…"
            case .upload: return "Uploading files…"
            case nil: return "Synchronizing files…"
            }
        }
    }

    private var detail: String {
        if let path = progress.activePath, !path.isEmpty { return path }
        return progress.currentName ?? model.statusMessage
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel
    var showsCompactSyncProgress = true
    @State private var showsErrorDetails = false

    private static func phaseLabel(_ phase: SyncPhase) -> String {
        switch phase {
        case .preparing: return String(localized: "Preparing files…")
        case .checking: return String(localized: "Checking files…")
        case .finishing: return String(localized: "Finishing synchronization…")
        case .transferring: return String(localized: "Synchronizing files…")
        }
    }

    static func activityStatusText(progress: AppModel.SyncProgress?, fallback: String) -> String {
        guard let progress else { return fallback }
        if progress.initialUpload != nil {
            switch progress.phase {
            case .preparing: return String(localized: "Counting files…")
            case .checking: return String(localized: "Checking local copies…")
            case .finishing: return String(localized: "Final checks…")
            case .transferring: return String(localized: "Uploading files…")
            }
        }
        return phaseLabel(progress.phase)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsErrorDetails, let error = model.errorMessage {
                ErrorDetailsPanel(title: "Synchronization error", message: error) {
                    showsErrorDetails = false
                }
            }
            statusBar
        }
        .onChange(of: model.errorMessage) { _, error in
            if error == nil { showsErrorDetails = false }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
                    .textSelection(.enabled)
                Button("Details…") { showsErrorDetails.toggle() }
                    .buttonStyle(.borderless)
                    .help("Show or hide the full error")
                    .accessibilityLabel(Text("Show error details"))
            } else if showsCompactSyncProgress || model.syncProgress == nil {
                Text(Self.activityStatusText(progress: model.syncProgress, fallback: model.statusMessage))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let sync = model.syncProgress, showsCompactSyncProgress {
                if sync.isIndeterminate {
                    ProgressView()
                        .controlSize(.small)
                    Text(sync.phase == .transferring ? "\(sync.done) files transferred" : Self.phaseLabel(sync.phase))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
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
                }
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
