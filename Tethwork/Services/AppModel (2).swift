import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var connections: [SyncConnection] = []
    @Published var activeConnection: SyncConnection?
    @Published var pinnedPaths: [String] = []
    @Published var listing: DirectoryListing?
    @Published var currentPath: String = ""
    @Published var selectedIDs: Set<String> = []
    @Published var statusMessage: String = "Ready"
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var isLoadingDirectory = false
    @Published var loadingFolderName: String?
    /// Non-blocking transfer feedback (Finder drops, etc.).
    @Published var importProgress: ImportProgress?
    /// Active pin/full sync transfer (status bar + per-row “Syncing…”).
    @Published var syncProgress: SyncProgress?
    @Published var showConnectSheet = false
    /// Filters / recursive search under the current folder.
    @Published var searchQuery: String = ""
    @Published private(set) var searchResults: [FileEntry] = []
    @Published private(set) var isSearchRunning = false
    @Published var viewMode: ViewMode {
        didSet { store.viewMode = viewMode.rawValue }
    }
    @Published var pendingDeleteIDs: Set<String> = []
    @Published var syncPausedUntil: Date?
    /// Inline Finder-style rename target (entry id / relative path).
    @Published var renamingID: String?
    @Published var renameDraft: String = ""
    private var renameSourceEntry: FileEntry?

    enum ViewMode: String {
        case list
        case icons
        case columns
    }

    struct SyncProgress: Equatable {
        var done: Int
        var total: Int
        var activePath: String?
        var currentName: String?

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(done) / Double(total))
        }

        var percent: Int {
            Int((fraction * 100).rounded())
        }
    }

    struct ImportProgress: Equatable {
        var done: Int
        var total: Int
        var currentName: String
        /// Destination relative path for this transfer.
        var destination: String = ""
        /// Relative path of the file currently being copied (for row status).
        var currentPath: String = ""
        /// Queued batches waiting after the current one.
        var queuedBatches: Int = 0

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(done) / Double(total))
        }

        var percent: Int {
            Int((fraction * 100).rounded())
        }
    }

    private struct PendingImport {
        var urls: [URL]
        var destination: String
    }

    private var importTask: Task<Void, Never>?
    private var pendingImports: [PendingImport] = []
    private var importActivity: NSObjectProtocol?
    private var pauseTimer: Timer?

    struct ColumnState: Identifiable, Equatable {
        var id: String { path.isEmpty ? "__root__" : path }
        var path: String
        var entries: [FileEntry]
        /// Child folder that opened the next column (highlighted).
        var revealedChildID: String?
        var isLoading: Bool

        static func empty(path: String, loading: Bool = false) -> ColumnState {
            ColumnState(path: path, entries: [], revealedChildID: nil, isLoading: loading)
        }
    }

    @Published var columns: [ColumnState] = [.empty(path: "")]
    /// Approximate icon-grid width in cells — updated by Icons view for ↑↓←→.
    @Published var iconsColumnsPerRow: Int = 4

    private let engine = SyncEngine()
    private let store = ConfigStore.shared
    /// Bumped to cancel in-flight connect/restore so they cannot re-upsert a deleted disk.
    private var sessionGeneration = 0
    /// Coalesce overlapping column soft-refreshes.
    private var columnsRefreshGeneration = 0
    /// Cancels only in-flight column *navigation* loads (not soft refresh).
    private var columnsNavigationGeneration = 0
    /// IDs removed by the user; in-flight connect must never write these back.
    private var blockedConnectionIDs = Set<String>()
    /// Polls currently visible folders so SMB remote edits show up without manual refresh.
    private var visibleWatcher: DirectoryWatcher?
    private var visibleRefreshTask: Task<Void, Never>?
    private var isSoftRefreshing = false
    /// Cached listings so keyboard column nav can open folders without a full reload.
    private var columnListingCache: [String: [FileEntry]] = [:]
    /// Debounced preview load — avoids stale ensureColumns stealing selection.
    private var columnPreviewTask: Task<Void, Never>?
    private var columnPreviewGeneration = 0
    /// Ask views to scroll this entry into visible area (keyboard navigation).
    @Published private(set) var scrollToVisibleID: String?
    @Published private(set) var scrollToVisibleTick: UInt = 0
    /// Restore list/icons scroll after a directory swap.
    @Published private(set) var scrollRestoreTick: UInt = 0
    @Published private(set) var scrollRestoreAnchorID: String?
    /// Expanded folders in list outline (relative paths).
    @Published private(set) var expandedFolderPaths: Set<String> = []
    /// Folders currently loading children for outline expansion.
    @Published private(set) var expandingFolderPaths: Set<String> = []
    private var scrollAnchorByPath: [String: String] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var searchGeneration = 0

    var isCurrentPinned: Bool {
        pinnedPaths.contains(currentPath)
            || pinnedPaths.contains(where: { pin in
                if pin.isEmpty { return true }
                return currentPath == pin || currentPath.hasPrefix(pin + "/")
            })
    }

    init() {
        if let mode = ViewMode(rawValue: ConfigStore.shared.viewMode) {
            viewMode = mode
        } else {
            viewMode = .list
        }
        refreshFromStore()
        $selectedIDs
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshQuickLookIfNeeded()
            }
            .store(in: &cancellables)
        $searchQuery
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] query in
                Task { @MainActor in
                    await self?.runRecursiveSearch(query)
                }
            }
            .store(in: &cancellables)
        Task {
            await engine.setEventHandler { [weak self] event in
                Task { @MainActor in
                    self?.handle(event)
                }
            }
            await restoreSession()
        }
    }

    func refreshFromStore() {
        connections = store.connections
        if let id = store.activeConnectionId,
           let match = connections.first(where: { $0.id == id }) {
            activeConnection = match
        } else if store.activeConnectionId == nil {
            // Keep in-memory activeConnection only if still present in the list
            if let active = activeConnection,
               connections.contains(where: { $0.id == active.id }) {
                // still valid
            } else {
                activeConnection = nil
            }
        } else {
            // Stored id missing from list
            activeConnection = nil
            store.activeConnectionId = nil
        }
    }

    private func restoreSession() async {
        guard let id = store.activeConnectionId,
              let connection = store.connections.first(where: { $0.id == id })
        else { return }

        let generation = sessionGeneration
        isBusy = true
        defer { isBusy = false }
        do {
            let pinned = store.pinnedPaths(for: connection.id)
            try await engine.connect(connection: connection, pinned: pinned)
            guard generation == sessionGeneration,
                  store.connections.contains(where: { $0.id == connection.id })
            else { return }
            activeConnection = connection
            pinnedPaths = await engine.getPinnedPaths()
            if viewMode == .columns {
                await ensureColumns(to: "", clearSelection: true)
            } else {
                try await loadDirectory("")
            }
            startVisibleWatcher()
            statusMessage = "Session restored"
            startBackgroundSyncIfNeeded()
        } catch {
            guard generation == sessionGeneration else { return }
            errorMessage = error.localizedDescription
            statusMessage = "Could not restore session"
        }
    }

    private func handle(_ event: SyncEvent) {
        switch event.kind {
        case .progress:
            // Show “Syncing” only while fixing real mismatches.
            guard event.isTransfer else { return }
            statusMessage = event.message
            if importProgress != nil {
                if let path = event.path, var progress = importProgress {
                    progress.currentPath = path
                    if let done = event.progressDone { progress.done = done }
                    if let total = event.progressTotal { progress.total = total }
                    let name = (path as NSString).lastPathComponent
                    if !name.isEmpty { progress.currentName = name }
                    importProgress = progress
                }
            } else if let done = event.progressDone, let total = event.progressTotal {
                let name = event.path.map { ($0 as NSString).lastPathComponent }
                syncProgress = SyncProgress(
                    done: done,
                    total: max(total, 1),
                    activePath: event.path,
                    currentName: name
                )
            }
            return

        case .complete:
            syncProgress = nil
            statusMessage = event.message
            refreshListingsAfterTransfer()
            pinnedPathsRefresh()

        case .error:
            syncProgress = nil
            statusMessage = event.message
            errorMessage = event.message

        case .file:
            statusMessage = event.message
            if syncProgress == nil, importProgress == nil {
                refreshListingsAfterTransfer()
            }
            pinnedPathsRefresh()

        case .status:
            statusMessage = event.message
        }
    }

    private func refreshListingsAfterTransfer() {
        Task {
            guard !columns.contains(where: \.isLoading) else { return }
            if viewMode == .columns {
                await refreshVisibleColumns(clearSelection: false)
            } else {
                try? await loadDirectory(currentPath, clearSelection: false)
            }
        }
    }

    /// Status label for a browser row (list / icons / columns).
    func displaySyncStatus(for entry: FileEntry) -> (title: String, systemImage: String, isSyncing: Bool) {
        if isActivelySyncing(entry.relativePath) {
            return ("Syncing…", "arrow.triangle.2.circlepath", true)
        }
        switch entry.syncMode {
        case .offline:
            // Only when pinned copy is missing or differs from remote.
            if entry.syncStatus == .pending || entry.syncStatus == .syncing || !entry.isLocallyAvailable {
                return ("Syncing…", "arrow.triangle.2.circlepath", true)
            }
            return ("Local", "checkmark.circle", false)
        case .onlineOnly:
            return ("Online", "icloud", false)
        }
    }

    /// True when this entry or one of its descendants is mid-transfer.
    func isActivelySyncing(_ relativePath: String) -> Bool {
        if let sync = syncProgress, pathIsAncestorOrSelf(relativePath, of: sync.activePath) {
            return true
        }
        if let imp = importProgress {
            if pathIsAncestorOrSelf(relativePath, of: imp.currentPath) {
                return true
            }
            // Destination folder (and ancestors) while importing into it.
            if !imp.destination.isEmpty, pathIsAncestorOrSelf(relativePath, of: imp.destination)
                || imp.destination == relativePath
                || (!relativePath.isEmpty && imp.destination.hasPrefix(relativePath + "/")) {
                return true
            }
        }
        return false
    }

    /// `ancestor` is the entry path; `active` is the file currently transferring.
    private func pathIsAncestorOrSelf(_ ancestor: String, of active: String?) -> Bool {
        guard let active, !active.isEmpty else { return false }
        if active == ancestor { return true }
        if ancestor.isEmpty { return true }
        return active.hasPrefix(ancestor + "/")
    }

    private func pinnedPathsRefresh() {
        Task {
            pinnedPaths = await engine.getPinnedPaths()
            if let id = activeConnection?.id {
                store.setPinnedPaths(pinnedPaths, for: id)
            }
        }
    }

    func loadDirectory(_ relative: String, clearSelection: Bool = true) async throws {
        if renamingID != nil, relative != currentPath {
            cancelRename()
        }
        let pathChanged = relative != currentPath
        let manageScroll = viewMode == .list || viewMode == .icons
        if manageScroll {
            rememberBrowserScroll(for: currentPath)
            // Arm restore before path changes so remounted icons ScrollView sees the anchor.
            scrollRestoreAnchorID = scrollAnchorByPath[relative]
        }

        listing = try await engine.listDirectory(relativePath: relative)
        columnListingCache[relative] = listing?.entries ?? []
        currentPath = relative

        if pathChanged {
            searchQuery = ""
            searchResults = []
            isSearchRunning = false
            searchGeneration += 1
            expandedFolderPaths.removeAll()
            expandingFolderPaths.removeAll()
        } else if viewMode == .list {
            await refreshExpandedOutlineChildren()
        }

        if clearSelection, viewMode != .columns {
            selectedIDs = []
        } else {
            pruneSelectionToVisibleEntries()
        }
        errorMessage = nil
        rebuildColumns(to: relative, with: listing)
        updateVisibleWatcherPaths()

        if manageScroll {
            scrollRestoreTick &+= 1
        }
    }

    /// Navigate into a folder with visible loading feedback for slow network volumes.
    func navigateTo(_ relative: String, displayName: String? = nil) async {
        let name = displayName
            ?? (relative.isEmpty
                ? (activeConnection?.name ?? "Root")
                : (relative as NSString).lastPathComponent)

        isLoadingDirectory = viewMode != .columns
        loadingFolderName = name
        statusMessage = "Opening “\(name)”…"
        defer {
            isLoadingDirectory = false
            loadingFolderName = nil
        }

        do {
            if viewMode == .columns {
                await ensureColumns(to: relative, displayName: name)
            } else {
                try await loadDirectory(relative)
            }
            statusMessage = "Ready"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not open folder"
        }
    }

    func selectAll() {
        if !normalizedSearchQuery.isEmpty {
            selectedIDs = Set(searchResults.map(\.id))
            return
        }
        if viewMode == .columns, let last = columns.last {
            selectedIDs = Set(last.entries.map(\.id))
            return
        }
        if viewMode == .list {
            selectedIDs = Set(listOutlineRows().map(\.id))
            return
        }
        guard let listing else { return }
        selectedIDs = Set(listing.entries.map(\.id))
    }

    func setViewMode(_ mode: ViewMode) {
        let previous = viewMode
        viewMode = mode
        if mode == .columns, previous != .columns {
            Task {
                await ensureColumns(to: currentPath)
                updateVisibleWatcherPaths()
            }
        } else if mode != .columns, previous == .columns {
            Task {
                try? await loadDirectory(currentPath, clearSelection: false)
                updateVisibleWatcherPaths()
            }
        } else {
            updateVisibleWatcherPaths()
        }
    }

    /// Build Miller-column stack ending at `targetPath`.
    /// Shows a loading placeholder immediately so slow SMB listings don't look like empty folders.
    func ensureColumns(
        to targetPath: String,
        displayName: String? = nil,
        clearSelection: Bool = true
    ) async {
        columnsNavigationGeneration += 1
        let generation = columnsNavigationGeneration
        if renamingID != nil, targetPath != currentPath {
            cancelRename()
        }
        if targetPath != currentPath {
            searchQuery = ""
            searchResults = []
            isSearchRunning = false
            searchGeneration += 1
        }

        let paths = Self.pathChain(to: targetPath)
        let folderName = displayName
            ?? (targetPath.isEmpty
                ? (activeConnection?.name ?? "Root")
                : (targetPath as NSString).lastPathComponent)

        statusMessage = "Opening “\(folderName)”…"

        // Publish skeleton right away: cached ancestors + loading leaf.
        var skeleton: [ColumnState] = []
        for (index, path) in paths.enumerated() {
            let revealed = index + 1 < paths.count ? paths[index + 1] : nil
            let existing = columns.first(where: { $0.path == path })
            let cachedEntries = columnListingCache[path]

            if path != targetPath, let existing, Self.isReusableAncestor(existing, revealed: revealed) {
                var column = existing
                column.revealedChildID = revealed
                skeleton.append(column)
            } else if path != targetPath, let cachedEntries, Self.isReusableCache(cachedEntries, revealed: revealed) {
                skeleton.append(
                    ColumnState(
                        path: path,
                        entries: cachedEntries,
                        revealedChildID: revealed,
                        isLoading: false
                    )
                )
            } else if let existing, !existing.entries.isEmpty, path == targetPath {
                var column = existing
                column.revealedChildID = revealed
                column.isLoading = true
                skeleton.append(column)
            } else if let cachedEntries, !cachedEntries.isEmpty, path == targetPath {
                skeleton.append(
                    ColumnState(
                        path: path,
                        entries: cachedEntries,
                        revealedChildID: revealed,
                        isLoading: true
                    )
                )
            } else {
                skeleton.append(.empty(path: path, loading: true))
            }
        }
        columns = skeleton
        currentPath = targetPath
        if clearSelection {
            selectedIDs = []
        }

        var next: [ColumnState] = []
        for (index, path) in paths.enumerated() {
            guard generation == columnsNavigationGeneration else { return }
            let revealed = index + 1 < paths.count ? paths[index + 1] : nil
            let existing = columns.first(where: { $0.path == path })

            // Reuse filled ancestors only. An empty non-loading ancestor (initial
            // placeholder / stale cache / cancelled load) must be refetched —
            // otherwise the first column stays on “Empty Folder” forever.
            if path != targetPath, let existing, Self.isReusableAncestor(existing, revealed: revealed) {
                var column = existing
                column.revealedChildID = revealed
                next.append(column)
                continue
            }

            do {
                let listing = try await engine.listDirectory(relativePath: path)
                guard generation == columnsNavigationGeneration else { return }
                columnListingCache[path] = listing.entries
                next.append(
                    ColumnState(
                        path: path,
                        entries: listing.entries,
                        revealedChildID: revealed,
                        isLoading: false
                    )
                )
                // Progressive update: swap loading placeholders as each column arrives.
                var progressive = next
                if index + 1 < paths.count {
                    for deeperIndex in (index + 1)..<paths.count {
                        let deeper = paths[deeperIndex]
                        let deeperRevealed = deeperIndex + 1 < paths.count ? paths[deeperIndex + 1] : nil
                        if let cached = columnListingCache[deeper],
                           Self.isReusableCache(cached, revealed: deeperRevealed) {
                            progressive.append(
                                ColumnState(
                                    path: deeper,
                                    entries: cached,
                                    revealedChildID: deeperRevealed,
                                    isLoading: true
                                )
                            )
                        } else {
                            progressive.append(.empty(path: deeper, loading: true))
                        }
                    }
                }
                columns = progressive
            } catch {
                guard generation == columnsNavigationGeneration else { return }
                next.append(.empty(path: path, loading: false))
                columns = next
                errorMessage = error.localizedDescription
                statusMessage = "Could not open folder"
                return
            }
        }

        guard generation == columnsNavigationGeneration else { return }

        columns = next
        if let last = columns.last {
            listing = DirectoryListing(
                relativePath: last.path,
                entries: last.entries,
                breadcrumbs: breadcrumbs(for: last.path)
            )
            currentPath = last.path
        }
        if clearSelection {
            selectedIDs = []
        } else {
            pruneSelectionToVisibleEntries()
        }
        updateVisibleWatcherPaths()
        statusMessage = "Ready"
    }

    func selectInColumn(columnIndex: Int, entry: FileEntry) {
        guard columns.indices.contains(columnIndex) else { return }
        endRenameIfNeeded(keeping: entry.id)

        if entry.isDirectory {
            selectedIDs = [entry.id]
            lastClickedID = entry.id
            // Update reveal hint only — do not truncate here.
            // Truncating before ensureColumns causes a double layout/scroll jump.
            if columns[columnIndex].revealedChildID != entry.relativePath {
                columns[columnIndex].revealedChildID = entry.relativePath
            }
            Task {
                await ensureColumns(
                    to: entry.relativePath,
                    displayName: entry.name,
                    clearSelection: false
                )
            }
        } else {
            selectedIDs = [entry.id]
            lastClickedID = entry.id
            var next = Array(columns.prefix(columnIndex + 1))
            if next.indices.contains(columnIndex) {
                next[columnIndex].revealedChildID = nil
            }
            columns = next
            currentPath = next[columnIndex].path
            listing = DirectoryListing(
                relativePath: next[columnIndex].path,
                entries: next[columnIndex].entries,
                breadcrumbs: breadcrumbs(for: next[columnIndex].path)
            )
            updateVisibleWatcherPaths()
        }
    }

    func toggleInColumn(columnIndex: Int, entry: FileEntry) {
        guard !entry.isDirectory else {
            selectInColumn(columnIndex: columnIndex, entry: entry)
            return
        }
        toggleSelection(entry.id)
        columns[columnIndex].revealedChildID = nil
        columns = Array(columns.prefix(columnIndex + 1))
    }

    func selectRangeInColumn(columnIndex: Int, to id: String) {
        guard columns.indices.contains(columnIndex) else {
            selectOnly(id)
            return
        }
        let ids = columns[columnIndex].entries.map(\.id)
        guard let end = ids.firstIndex(of: id) else {
            selectOnly(id)
            return
        }
        let start: Int
        if let anchor = lastClickedID, let idx = ids.firstIndex(of: anchor) {
            start = idx
        } else {
            start = end
        }
        let range = ids[min(start, end)...max(start, end)]
        selectedIDs = Set(range)
        lastClickedID = id
        columns[columnIndex].revealedChildID = nil
        columns = Array(columns.prefix(columnIndex + 1))
    }

    private func rebuildColumns(to relative: String, with listing: DirectoryListing?) {
        guard viewMode == .columns else { return }
        Task { await refreshVisibleColumns(clearSelection: false) }
    }

    /// Soft-refresh the open Miller stack without collapsing / re-navigating.
    private func refreshVisibleColumns(clearSelection: Bool) async {
        // Never interrupt an in-progress folder open — that left columns stuck on “Loading…”.
        guard !columns.contains(where: \.isLoading) else { return }

        let stack = columns
        if stack.isEmpty {
            await ensureColumns(to: currentPath, clearSelection: clearSelection)
            return
        }

        columnsRefreshGeneration += 1
        let generation = columnsRefreshGeneration

        var refreshed: [ColumnState] = []

        for column in stack {
            guard generation == columnsRefreshGeneration else { return }
            guard !columns.contains(where: \.isLoading) else { return }
            do {
                let listing = try await engine.listDirectory(relativePath: column.path)
                var revealed = column.revealedChildID
                let hadRevealed = revealed != nil
                // Transient empty SMB replies must not wipe a parent that still
                // has an open child column — keep the previous entries instead.
                if listing.entries.isEmpty, hadRevealed, !column.entries.isEmpty {
                    refreshed.append(column)
                    continue
                }
                columnListingCache[column.path] = listing.entries
                if let child = revealed,
                   !listing.entries.contains(where: { $0.relativePath == child && $0.isDirectory }) {
                    revealed = nil
                }
                refreshed.append(
                    ColumnState(
                        path: column.path,
                        entries: listing.entries,
                        revealedChildID: revealed,
                        isLoading: false
                    )
                )
                // Open child folder was removed — drop deeper columns.
                if hadRevealed && revealed == nil {
                    break
                }
            } catch {
                // This column's directory no longer exists — keep parents only.
                break
            }
        }

        guard generation == columnsRefreshGeneration else { return }
        guard !columns.contains(where: \.isLoading) else { return }

        if refreshed.isEmpty {
            await ensureColumns(to: "", clearSelection: clearSelection)
            return
        }

        columns = refreshed
        if let last = refreshed.last {
            currentPath = last.path
            listing = DirectoryListing(
                relativePath: last.path,
                entries: last.entries,
                breadcrumbs: breadcrumbs(for: last.path)
            )
        }
        if clearSelection {
            selectedIDs = []
        } else {
            pruneSelectionToVisibleEntries()
        }
        updateVisibleWatcherPaths()
    }

    private func breadcrumbs(for relative: String) -> [Breadcrumb] {
        var crumbs = [Breadcrumb(name: "Root", path: "")]
        if relative.isEmpty { return crumbs }
        var acc = ""
        for part in relative.split(separator: "/") {
            acc = acc.isEmpty ? String(part) : "\(acc)/\(part)"
            crumbs.append(Breadcrumb(name: String(part), path: acc))
        }
        return crumbs
    }

    nonisolated private static func pathChain(to target: String) -> [String] {
        let normalized = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var paths = [""]
        if normalized.isEmpty { return paths }
        var acc = ""
        for part in normalized.split(separator: "/") {
            acc = acc.isEmpty ? String(part) : "\(acc)/\(part)"
            paths.append(acc)
        }
        return paths
    }

    /// Ancestor may be reused only when it still shows the revealed child folder.
    nonisolated private static func isReusableAncestor(_ column: ColumnState, revealed: String?) -> Bool {
        guard !column.isLoading else { return false }
        return isReusableCache(column.entries, revealed: revealed)
    }

    /// Empty listings are never reusable when a child column depends on them —
    /// that was leaving the first Miller column stuck on “Empty Folder”.
    nonisolated private static func isReusableCache(_ entries: [FileEntry], revealed: String?) -> Bool {
        if entries.isEmpty { return revealed == nil }
        guard let revealed else { return true }
        return entries.contains(where: { $0.relativePath == revealed && $0.isDirectory })
    }

    func connect(name: String, remotePath: String, localPath: String, connectionId: String? = nil) async {
        if let connectionId, blockedConnectionIDs.contains(connectionId) {
            return
        }

        sessionGeneration += 1
        let generation = sessionGeneration

        isBusy = true
        errorMessage = nil
        statusMessage = "Connecting…"
        defer { isBusy = false }

        let connection = SyncConnection(
            id: connectionId ?? UUID().uuidString,
            name: name.isEmpty ? URL(fileURLWithPath: remotePath).lastPathComponent : name,
            remotePath: remotePath,
            localPath: localPath
        )

        if blockedConnectionIDs.contains(connection.id) {
            return
        }

        // Fail fast if the volume is missing instead of hanging on I/O.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: remotePath, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = "Remote path unavailable: \(remotePath)"
            statusMessage = "Connection failed"
            return
        }

        do {
            try FileManager.default.createDirectory(atPath: localPath, withIntermediateDirectories: true)

            let pinned = store.pinnedPaths(for: connection.id)
            try await engine.connect(connection: connection, pinned: pinned)
            guard generation == sessionGeneration else {
                await engine.disconnect()
                return
            }
            guard !blockedConnectionIDs.contains(connection.id) else {
                await engine.disconnect()
                return
            }

            store.upsert(connection)
            connections = store.connections.filter { !blockedConnectionIDs.contains($0.id) }
            activeConnection = connection
            pinnedPaths = await engine.getPinnedPaths()
            guard generation == sessionGeneration, !blockedConnectionIDs.contains(connection.id) else {
                await engine.disconnect()
                activeConnection = nil
                listing = nil
                return
            }
            if viewMode == .columns {
                await ensureColumns(to: "", clearSelection: true)
            } else {
                try await loadDirectory("")
            }
            showConnectSheet = false
            startVisibleWatcher()
            statusMessage = "Connected"
            startBackgroundSyncIfNeeded()
        } catch {
            guard generation == sessionGeneration else { return }
            errorMessage = error.localizedDescription
            statusMessage = "Connection failed"
        }
    }

    func selectConnection(_ connection: SyncConnection) async {
        guard !blockedConnectionIDs.contains(connection.id) else { return }
        guard connections.contains(where: { $0.id == connection.id }) else { return }

        // Already connected to this disk — do not reconnect (avoids re-upsert races).
        if activeConnection?.id == connection.id,
           await engine.connection?.id == connection.id {
            return
        }
        await connect(
            name: connection.name,
            remotePath: connection.remotePath,
            localPath: connection.localPath,
            connectionId: connection.id
        )
    }

    func disconnect() async {
        sessionGeneration += 1
        stopVisibleWatcher()
        await engine.disconnect()
        store.activeConnectionId = nil
        activeConnection = nil
        listing = nil
        pinnedPaths = []
        selectedIDs = []
        columnListingCache.removeAll()
        scrollAnchorByPath.removeAll()
        liveIconsAnchorID = nil
        cancelRename()
        cancelBackgroundImport()
        syncProgress = nil
        expandedFolderPaths.removeAll()
        expandingFolderPaths.removeAll()
        statusMessage = "Disconnected"
        connections = store.connections.filter { !blockedConnectionIDs.contains($0.id) }
    }

    func deleteConnection(_ id: String) async {
        sessionGeneration += 1
        blockedConnectionIDs.insert(id)

        let removingActive = activeConnection?.id == id

        // Persist and update UI before any await — so a racing connect cannot win.
        if removingActive {
            stopVisibleWatcher()
            activeConnection = nil
            listing = nil
            pinnedPaths = []
            selectedIDs = []
            errorMessage = nil
            currentPath = ""
            store.activeConnectionId = nil
        }
        connections.removeAll { $0.id == id }
        connections = store.deleteConnection(id: id)

        if removingActive {
            await engine.disconnect()
        }

        // Final assert after await yields.
        if store.connections.contains(where: { $0.id == id }) {
            connections = store.deleteConnection(id: id)
        } else {
            connections = store.connections.filter { $0.id != id }
        }
        if activeConnection?.id == id {
            activeConnection = nil
            listing = nil
        }

        // Disk is already gone from the sidebar — drop the temporary block and
        // invalidate in-flight work so the next “New Connection” can use a fresh id now.
        sessionGeneration += 1
        blockedConnectionIDs.remove(id)
        statusMessage = "Connection removed"
    }

    /// Always mints a new connection id (used by “New Connection”).
    func connectNew(name: String, remotePath: String, localPath: String) async {
        await connect(
            name: name,
            remotePath: remotePath,
            localPath: localPath,
            connectionId: UUID().uuidString
        )
    }

    func openEntry(_ entry: FileEntry) async {
        endRenameIfNeeded(keeping: entry.isDirectory ? nil : entry.id)
        if entry.isDirectory {
            await navigateTo(entry.relativePath, displayName: entry.name)
            return
        }

        let url = openURL(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "File unavailable: \(entry.name)"
            return
        }
        let ok = NSWorkspace.shared.open(url)
        if !ok {
            statusMessage = "Could not open “\(entry.name)”"
        }
    }

    /// Local sync copy when present; otherwise the live path on the network volume.
    func openURL(for entry: FileEntry) -> URL {
        if entry.isLocallyAvailable, let activeConnection {
            let local = (activeConnection.localPath as NSString)
                .appendingPathComponent(entry.relativePath)
            if FileManager.default.fileExists(atPath: local) {
                return URL(fileURLWithPath: local)
            }
        }
        return URL(fileURLWithPath: entry.absolutePath)
    }

    func togglePin(_ entry: FileEntry) async {
        let next = entry.syncMode != .offline
        statusMessage = next ? "Downloading “\(entry.name)”…" : "Removing local copy of “\(entry.name)”…"
        do {
            let paths = try await engine.setPinned(relativePath: entry.relativePath, pinned: next)
            pinnedPaths = paths
            if let id = activeConnection?.id {
                store.setPinnedPaths(paths, for: id)
            }
            try await loadDirectory(currentPath, clearSelection: false)
            statusMessage = next ? "Local: \(entry.name)" : "Online only: \(entry.name)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not change local storage"
        }
    }

    func togglePinCurrent() async {
        let next = !isCurrentPinned
        let title = currentFolderTitle
        statusMessage = next ? "Downloading “\(title)”…" : "Removing local copy of “\(title)”…"
        do {
            let paths = try await engine.setPinned(relativePath: currentPath, pinned: next)
            pinnedPaths = paths
            if let id = activeConnection?.id {
                store.setPinnedPaths(paths, for: id)
            }
            try await loadDirectory(currentPath, clearSelection: false)
            statusMessage = next ? "Local: \(title)" : "Online only: \(title)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not change local storage"
        }
    }

    /// Unpin a saved sidebar folder without requiring it to be the current path.
    func unpinPath(_ relativePath: String) async {
        let title = relativePath.isEmpty
            ? (activeConnection?.name ?? "Disk")
            : (relativePath as NSString).lastPathComponent
        statusMessage = "Removing local copy of “\(title)”…"
        do {
            let paths = try await engine.setPinned(relativePath: relativePath, pinned: false)
            pinnedPaths = paths
            if let id = activeConnection?.id {
                store.setPinnedPaths(paths, for: id)
            }
            try await loadDirectory(currentPath, clearSelection: false)
            statusMessage = "Online only: \(title)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not change local storage"
        }
    }

    func fullSync() async {
        // Never set isBusy — sync must not freeze browsing.
        await engine.fullSync()
    }

    /// Kick off sync without blocking connect / restore.
    func startBackgroundSyncIfNeeded() {
        guard activeConnection != nil else { return }
        guard syncProgress == nil else { return }
        guard !pinnedPaths.isEmpty else { return }
        guard !isSyncPaused else { return }
        Task { await fullSync() }
    }

    func revealLocal() {
        guard let path = activeConnection?.localPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func revealRemote() {
        guard let path = activeConnection?.remotePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Visible directory polling (SMB-friendly)

    private func startVisibleWatcher() {
        stopVisibleWatcher()
        let watcher = DirectoryWatcher { [weak self] _ in
            Task { @MainActor in
                self?.handleVisibleDirectoryChange()
            }
        }
        visibleWatcher = watcher
        let urls = absoluteURLs(for: visibleRelativePaths())
        DispatchQueue.global(qos: .utility).async {
            watcher.start(watching: urls, interval: 1.0)
        }
    }

    private func stopVisibleWatcher() {
        visibleRefreshTask?.cancel()
        visibleRefreshTask = nil
        visibleWatcher?.stop()
        visibleWatcher = nil
        isSoftRefreshing = false
    }

    private func updateVisibleWatcherPaths() {
        guard activeConnection != nil, visibleWatcher != nil else { return }
        visibleWatcher?.setWatchedURLs(absoluteURLs(for: visibleRelativePaths()))
    }

    private func visibleRelativePaths() -> [String] {
        if viewMode == .columns {
            let paths = columns.map(\.path)
            return paths.isEmpty ? [currentPath] : paths
        }
        if viewMode == .list {
            var paths = [currentPath]
            paths.append(contentsOf: expandedFolderPaths)
            return paths
        }
        return [currentPath]
    }

    private func absoluteURLs(for relativePaths: [String]) -> [URL] {
        guard let root = activeConnection?.remotePath else { return [] }
        return relativePaths.map { relative in
            if relative.isEmpty {
                return URL(fileURLWithPath: root)
            }
            return URL(fileURLWithPath: (root as NSString).appendingPathComponent(relative))
        }
    }

    private func handleVisibleDirectoryChange() {
        guard activeConnection != nil else { return }
        guard renamingID == nil else { return }
        guard !isBusy, !isLoadingDirectory, !isSoftRefreshing else { return }

        visibleRefreshTask?.cancel()
        visibleRefreshTask = Task { [weak self] in
            // Brief coalesce so a burst of SMB attribute updates becomes one refresh.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.softRefreshVisibleListing()
        }
    }

    private func softRefreshVisibleListing() async {
        guard activeConnection != nil else { return }
        guard renamingID == nil else { return }
        guard !isBusy, !isLoadingDirectory else { return }
        // Don't fight an in-progress column open (would flash empty/loading).
        guard !columns.contains(where: \.isLoading) else { return }
        isSoftRefreshing = true
        defer { isSoftRefreshing = false }

        if viewMode == .columns {
            await refreshVisibleColumns(clearSelection: false)
        } else {
            try? await loadDirectory(currentPath, clearSelection: false)
        }
    }

    /// Keep selection that still exists in any visible column (or the list view).
    /// Important: in columns mode a selected folder lives in a parent column, while
    /// `columns.last` is that folder's contents — pruning against only the leaf
    /// would clear the folder selection and leave a gray "revealed" highlight.
    private func pruneSelectionToVisibleEntries() {
        guard !selectedIDs.isEmpty else { return }
        let valid: Set<String>
        if viewMode == .columns {
            valid = Set(columns.flatMap(\.entries).map(\.id))
        } else if !normalizedSearchQuery.isEmpty {
            valid = Set(searchResults.map(\.id))
        } else if viewMode == .list {
            valid = Set(listOutlineRows().map(\.id))
        } else {
            valid = Set(listing?.entries.map(\.id) ?? [])
        }
        selectedIDs = selectedIDs.intersection(valid)
    }

    func refresh() async {
        await navigateTo(currentPath, displayName: currentFolderTitle)
    }

    var canGoUp: Bool { !currentPath.isEmpty }

    var currentFolderTitle: String {
        if currentPath.isEmpty {
            return activeConnection?.name ?? "Disk"
        }
        return (currentPath as NSString).lastPathComponent
    }

    var parentPath: String {
        guard !currentPath.isEmpty else { return "" }
        let parent = (currentPath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    func goUp() async {
        guard canGoUp else { return }
        let name = parentPath.isEmpty
            ? (activeConnection?.name ?? "Root")
            : (parentPath as NSString).lastPathComponent
        await navigateTo(parentPath, displayName: name)
    }

    var selectedEntries: [FileEntry] {
        if !normalizedSearchQuery.isEmpty {
            return searchResults.filter { selectedIDs.contains($0.id) }
        }
        if viewMode == .columns {
            var seen = Set<String>()
            return columns.flatMap(\.entries).filter { entry in
                selectedIDs.contains(entry.id) && seen.insert(entry.id).inserted
            }
        }
        if viewMode == .list {
            return listOutlineRows().map(\.entry).filter { selectedIDs.contains($0.id) }
        }
        guard let listing else { return [] }
        return listing.entries.filter { selectedIDs.contains($0.id) }
    }

    /// Visible rows for list outline (top-level + expanded descendants).
    func listOutlineRows() -> [OutlineRow] {
        if !normalizedSearchQuery.isEmpty {
            return searchResults.map { OutlineRow(entry: $0, depth: 0) }
        }
        guard let roots = listing?.entries else { return [] }
        var rows: [OutlineRow] = []
        appendOutlineRows(roots, depth: 0, into: &rows)
        return rows
    }

    var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Entries shown in the browser (recursive search results when querying).
    func displayedEntries(from listingEntries: [FileEntry]) -> [FileEntry] {
        if !normalizedSearchQuery.isEmpty {
            return searchResults
        }
        return listingEntries
    }

    private func runRecursiveSearch(_ raw: String) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration

        guard activeConnection != nil else {
            searchResults = []
            isSearchRunning = false
            return
        }

        guard !query.isEmpty else {
            searchResults = []
            isSearchRunning = false
            return
        }

        isSearchRunning = true
        searchResults = []
        let root = currentPath
        do {
            let results = try await engine.search(query: query, under: root) { [weak self] partial in
                Task { @MainActor in
                    guard let self, generation == self.searchGeneration else { return }
                    self.searchResults = partial
                }
            }
            guard generation == searchGeneration, currentPath == root else { return }
            searchResults = results
            pruneSelectionToVisibleEntries()
            statusMessage = results.isEmpty
                ? "No results"
                : "Found: \(results.count)"
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
            errorMessage = error.localizedDescription
            statusMessage = "Search failed"
        }
        if generation == searchGeneration {
            isSearchRunning = false
        }
    }

    private func appendOutlineRows(_ entries: [FileEntry], depth: Int, into rows: inout [OutlineRow]) {
        for entry in entries {
            rows.append(OutlineRow(entry: entry, depth: depth))
            guard entry.isDirectory, expandedFolderPaths.contains(entry.relativePath) else { continue }
            let children = columnListingCache[entry.relativePath] ?? []
            appendOutlineRows(children, depth: depth + 1, into: &rows)
        }
    }

    func isFolderExpanded(_ path: String) -> Bool {
        expandedFolderPaths.contains(path)
    }

    func isFolderExpanding(_ path: String) -> Bool {
        expandingFolderPaths.contains(path)
    }

    func toggleFolderExpanded(_ entry: FileEntry) async {
        guard entry.isDirectory else { return }
        let path = entry.relativePath
        if expandedFolderPaths.contains(path) {
            collapseFolder(path)
            updateVisibleWatcherPaths()
            return
        }

        expandedFolderPaths.insert(path)
        expandingFolderPaths.insert(path)
        defer { expandingFolderPaths.remove(path) }

        do {
            let listing = try await engine.listDirectory(relativePath: path)
            columnListingCache[path] = listing.entries
            updateVisibleWatcherPaths()
        } catch {
            expandedFolderPaths.remove(path)
            errorMessage = error.localizedDescription
            statusMessage = "Could not expand folder"
        }
    }

    private func collapseFolder(_ path: String) {
        expandedFolderPaths.remove(path)
        if path.isEmpty {
            expandedFolderPaths.removeAll()
            return
        }
        let prefix = path + "/"
        expandedFolderPaths = expandedFolderPaths.filter { !$0.hasPrefix(prefix) }
    }

    private func refreshExpandedOutlineChildren() async {
        let paths = expandedFolderPaths.sorted()
        guard !paths.isEmpty else { return }
        var stillExpanded = Set<String>()
        for path in paths {
            do {
                let listing = try await engine.listDirectory(relativePath: path)
                columnListingCache[path] = listing.entries
                stillExpanded.insert(path)
            } catch {
                columnListingCache.removeValue(forKey: path)
            }
        }
        // Keep only folders that still exist in the visible outline tree.
        let visibleFolders = Set(listOutlineRows().compactMap { row in
            row.entry.isDirectory ? row.entry.relativePath : nil
        })
        expandedFolderPaths = stillExpanded.intersection(visibleFolders)
    }

    var lastClickedID: String?
    /// Anchor for ⇧-arrow range selection.
    private var keyboardAnchorID: String?

    enum ArrowKey: Equatable {
        case up, down, left, right

        init?(keyCode: UInt16) {
            switch keyCode {
            case 126: self = .up
            case 125: self = .down
            case 123: self = .left
            case 124: self = .right
            default: return nil
            }
        }
    }

    func handleArrowKey(_ key: ArrowKey, extend: Bool) {
        guard activeConnection != nil else { return }
        guard !isBusy, !isLoadingDirectory else { return }

        switch viewMode {
        case .list:
            handleListArrow(key, extend: extend)
        case .icons:
            handleIconsArrow(key, extend: extend)
        case .columns:
            handleColumnsArrow(key, extend: extend)
        }
    }

    func openKeyboardSelection() {
        guard activeConnection != nil else { return }
        if let entry = selectedEntries.first {
            Task { await openEntry(entry) }
            return
        }
        // Columns: open revealed folder in the focused column when nothing selected.
        if viewMode == .columns,
           let column = columns.last(where: { $0.revealedChildID != nil }),
           let child = column.revealedChildID,
           let entry = column.entries.first(where: { $0.relativePath == child }) {
            Task { await openEntry(entry) }
        }
    }

    private func handleListArrow(_ key: ArrowKey, extend: Bool) {
        let rows = listOutlineRows()
        let entries = rows.map(\.entry)
        guard !entries.isEmpty else {
            if key == .left { Task { await goUp() } }
            return
        }

        switch key {
        case .up, .down:
            moveLinearSelection(
                in: entries.map(\.id),
                delta: key == .up ? -1 : 1,
                extend: extend
            )
        case .left:
            if let entry = primarySelectedEntry(in: entries), entry.isDirectory,
               expandedFolderPaths.contains(entry.relativePath) {
                collapseFolder(entry.relativePath)
                updateVisibleWatcherPaths()
            } else {
                Task { await goUp() }
            }
        case .right:
            if let entry = primarySelectedEntry(in: entries), entry.isDirectory {
                if expandedFolderPaths.contains(entry.relativePath) {
                    let children = columnListingCache[entry.relativePath] ?? []
                    if let first = children.first {
                        selectOnly(first.id)
                        requestScrollToVisible(first.id)
                    }
                } else {
                    Task { await toggleFolderExpanded(entry) }
                }
            }
        }
    }

    private func handleIconsArrow(_ key: ArrowKey, extend: Bool) {
        let entries = listing?.entries ?? []
        guard !entries.isEmpty else {
            if key == .left { Task { await goUp() } }
            return
        }

        let cols = max(1, iconsColumnsPerRow)
        let ids = entries.map(\.id)
        let currentIndex = focusedIndex(in: ids)

        let delta: Int
        switch key {
        case .left: delta = -1
        case .right: delta = 1
        case .up: delta = -cols
        case .down: delta = cols
        }

        // Right on a selected folder opens it (Finder-like) when already at end of row intent —
        // prefer open when right and selection is a directory and next would wrap? Finder opens with Cmd+Down.
        // Keep arrows purely navigational; Return opens.
        if currentIndex == nil {
            selectOnly(ids[0])
            keyboardAnchorID = ids[0]
            requestScrollToVisible(ids[0])
            return
        }

        let next = currentIndex! + delta
        guard ids.indices.contains(next) else {
            if key == .left, currentIndex == 0 {
                Task { await goUp() }
            }
            return
        }

        applyKeyboardMove(to: ids[next], ids: ids, extend: extend)
    }

    private func handleColumnsArrow(_ key: ArrowKey, extend: Bool) {
        guard !columns.isEmpty else { return }

        let columnIndex = activeColumnIndexForKeyboard()
        guard columns.indices.contains(columnIndex) else { return }
        let entries = columns[columnIndex].entries

        switch key {
        case .up, .down:
            guard !entries.isEmpty else { return }
            let ids = entries.map(\.id)
            guard let current = focusedIndex(in: ids) else {
                selectOnly(ids[0])
                keyboardAnchorID = ids[0]
                requestScrollToVisible(ids[0])
                return
            }
            let next = min(max(current + (key == .up ? -1 : 1), 0), ids.count - 1)
            applyKeyboardMove(to: ids[next], ids: ids, extend: extend)
            guard !extend else { return }

            // Preview the folder in the next column; selection stays here until →.
            if let entry = entries.first(where: { $0.id == ids[next] }), entry.isDirectory {
                previewDirectoryInColumns(columnIndex: columnIndex, entry: entry)
            } else {
                collapseColumnsAfterSelection(columnIndex: columnIndex)
            }

        case .right:
            if let entry = primarySelectedEntry(in: entries), entry.isDirectory {
                enterDirectoryInColumns(columnIndex: columnIndex, entry: entry)
            } else if let revealed = columns[columnIndex].revealedChildID,
                      let entry = entries.first(where: { $0.relativePath == revealed }) {
                enterDirectoryInColumns(columnIndex: columnIndex, entry: entry)
            } else if columnIndex + 1 < columns.count {
                focusColumn(columnIndex + 1)
            }

        case .left:
            if columnIndex > 0 {
                let parentIndex = columnIndex - 1
                let childPath = columns[columnIndex].path
                let parent = columns[parentIndex]

                // Keep the child column as a preview; move selection to its folder in the parent.
                var next = Array(columns.prefix(columnIndex + 1))
                next[parentIndex].revealedChildID = childPath
                columns = next
                currentPath = parent.path
                listing = DirectoryListing(
                    relativePath: parent.path,
                    entries: parent.entries,
                    breadcrumbs: breadcrumbs(for: parent.path)
                )
                if let folder = parent.entries.first(where: { $0.relativePath == childPath }) {
                    selectOnly(folder.id)
                    keyboardAnchorID = folder.id
                    requestScrollToVisible(folder.id)
                } else {
                    clearSelection()
                }
                updateVisibleWatcherPaths()
            } else {
                Task { await goUp() }
            }
        }
    }

    /// Show folder contents in the next column without moving keyboard focus into it.
    private func previewDirectoryInColumns(columnIndex: Int, entry: FileEntry) {
        guard entry.isDirectory else { return }

        columnPreviewTask?.cancel()
        columnPreviewGeneration &+= 1
        let previewGeneration = columnPreviewGeneration
        let targetPath = entry.relativePath

        var next = Array(columns.prefix(columnIndex + 1))
        guard next.indices.contains(columnIndex) else { return }
        next[columnIndex].revealedChildID = targetPath

        if let live = columns.first(where: { $0.path == targetPath && !$0.isLoading && !$0.entries.isEmpty }) {
            next.append(
                ColumnState(
                    path: live.path,
                    entries: live.entries,
                    revealedChildID: nil,
                    isLoading: false
                )
            )
            columns = next
            updateVisibleWatcherPaths()
            return
        }

        if let cached = columnListingCache[targetPath], !cached.isEmpty {
            next.append(
                ColumnState(
                    path: targetPath,
                    entries: cached,
                    revealedChildID: nil,
                    isLoading: false
                )
            )
            columns = next
            updateVisibleWatcherPaths()
            columnPreviewTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self else { return }
                guard previewGeneration == self.columnPreviewGeneration else { return }
                guard self.isColumnPreviewStillCurrent(columnIndex: columnIndex, path: targetPath) else { return }
                await self.quietlyRefreshColumn(path: targetPath)
            }
            return
        }

        // Placeholder only — wait until the user pauses before hitting the network.
        next.append(.empty(path: targetPath, loading: true))
        columns = next

        columnPreviewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, let self else { return }
            guard previewGeneration == self.columnPreviewGeneration else { return }
            guard self.isColumnPreviewStillCurrent(columnIndex: columnIndex, path: targetPath) else { return }

            await self.ensureColumns(
                to: targetPath,
                displayName: entry.name,
                clearSelection: false
            )
            // Do not touch selection here — a late load used to jump highlight
            // back to an earlier folder after the user had already moved on.
        }
    }

    private func isColumnPreviewStillCurrent(columnIndex: Int, path: String) -> Bool {
        guard columns.indices.contains(columnIndex) else { return false }
        return columns[columnIndex].revealedChildID == path
    }

    /// Open folder preview (if needed) and move keyboard focus into that column.
    private func enterDirectoryInColumns(columnIndex: Int, entry: FileEntry) {
        guard entry.isDirectory else { return }

        columnPreviewTask?.cancel()
        columnPreviewGeneration &+= 1
        let previewGeneration = columnPreviewGeneration
        let targetPath = entry.relativePath

        let alreadyOpen = columns[columnIndex].revealedChildID == targetPath
            && columnIndex + 1 < columns.count
            && !columns[columnIndex + 1].entries.isEmpty
            && !columns[columnIndex + 1].isLoading

        if alreadyOpen {
            focusColumn(columnIndex + 1)
            return
        }

        var next = Array(columns.prefix(columnIndex + 1))
        guard next.indices.contains(columnIndex) else { return }
        next[columnIndex].revealedChildID = targetPath

        if let live = columns.first(where: { $0.path == targetPath && !$0.isLoading && !$0.entries.isEmpty }) {
            next.append(
                ColumnState(
                    path: live.path,
                    entries: live.entries,
                    revealedChildID: nil,
                    isLoading: false
                )
            )
            columns = next
            focusColumn(columnIndex + 1)
            updateVisibleWatcherPaths()
            return
        }

        if let cached = columnListingCache[targetPath], !cached.isEmpty {
            next.append(
                ColumnState(
                    path: targetPath,
                    entries: cached,
                    revealedChildID: nil,
                    isLoading: false
                )
            )
            columns = next
            focusColumn(columnIndex + 1)
            updateVisibleWatcherPaths()
            Task { await quietlyRefreshColumn(path: targetPath) }
            return
        }

        next.append(.empty(path: targetPath, loading: true))
        columns = next
        Task { [weak self] in
            guard let self else { return }
            await self.ensureColumns(
                to: targetPath,
                displayName: entry.name,
                clearSelection: false
            )
            guard previewGeneration == self.columnPreviewGeneration else { return }
            guard self.isColumnPreviewStillCurrent(columnIndex: columnIndex, path: targetPath) else { return }
            if let idx = self.columns.firstIndex(where: { $0.path == targetPath }),
               !self.columns[idx].entries.isEmpty {
                self.focusColumn(idx)
            }
        }
    }

    private func focusColumn(_ columnIndex: Int) {
        guard columns.indices.contains(columnIndex) else { return }
        let column = columns[columnIndex]
        currentPath = column.path
        listing = DirectoryListing(
            relativePath: column.path,
            entries: column.entries,
            breadcrumbs: breadcrumbs(for: column.path)
        )
        if let first = column.entries.first {
            // Prefer first item, or keep selection if it's already inside this column.
            if let current = lastClickedID,
               column.entries.contains(where: { $0.id == current }) {
                selectOnly(current)
                keyboardAnchorID = current
                requestScrollToVisible(current)
            } else {
                selectOnly(first.id)
                keyboardAnchorID = first.id
                requestScrollToVisible(first.id)
            }
        } else {
            clearSelection()
        }
        updateVisibleWatcherPaths()
    }

    private func quietlyRefreshColumn(path: String) async {
        guard !columns.contains(where: \.isLoading) else { return }
        guard columns.contains(where: { $0.path == path }) else { return }
        do {
            let listing = try await engine.listDirectory(relativePath: path)
            columnListingCache[path] = listing.entries
            guard let idx = columns.firstIndex(where: { $0.path == path }) else { return }
            guard !columns[idx].isLoading else { return }
            let selected = selectedIDs
            let anchor = lastClickedID
            let keyboardAnchor = keyboardAnchorID
            var updated = columns
            updated[idx].entries = listing.entries
            columns = updated
            if currentPath == path {
                self.listing = DirectoryListing(
                    relativePath: path,
                    entries: listing.entries,
                    breadcrumbs: breadcrumbs(for: path)
                )
            }
            selectedIDs = selected
            lastClickedID = anchor
            keyboardAnchorID = keyboardAnchor
            pruneSelectionToVisibleEntries()
        } catch {
            // Keep cached rows.
        }
    }

    private func activeColumnIndexForKeyboard() -> Int {
        // Prefer the column that contains the current selection.
        if let id = lastClickedID ?? selectedIDs.first {
            if let idx = columns.firstIndex(where: { col in col.entries.contains(where: { $0.id == id }) }) {
                return idx
            }
        }
        // Else the column that revealed a child, else the last column.
        if let idx = columns.lastIndex(where: { $0.revealedChildID != nil }) {
            return idx
        }
        return max(0, columns.count - 1)
    }

    private func primarySelectedEntry(in entries: [FileEntry]) -> FileEntry? {
        if let id = lastClickedID, let match = entries.first(where: { $0.id == id }) {
            return match
        }
        return entries.first(where: { selectedIDs.contains($0.id) })
    }

    private func focusedIndex(in ids: [String]) -> Int? {
        if let id = lastClickedID, let idx = ids.firstIndex(of: id) {
            return idx
        }
        if let id = selectedIDs.first, let idx = ids.firstIndex(of: id) {
            return idx
        }
        return nil
    }

    private func moveLinearSelection(
        in ids: [String],
        delta: Int,
        extend: Bool,
        columnIndex: Int? = nil
    ) {
        guard !ids.isEmpty else { return }

        guard let current = focusedIndex(in: ids) else {
            selectOnly(ids[0])
            keyboardAnchorID = ids[0]
            requestScrollToVisible(ids[0])
            return
        }

        let next = min(max(current + delta, 0), ids.count - 1)
        applyKeyboardMove(to: ids[next], ids: ids, extend: extend)
    }

    private func collapseColumnsAfterSelection(columnIndex: Int) {
        guard columns.indices.contains(columnIndex) else { return }
        columns[columnIndex].revealedChildID = nil
        columns = Array(columns.prefix(columnIndex + 1))
        currentPath = columns[columnIndex].path
        listing = DirectoryListing(
            relativePath: columns[columnIndex].path,
            entries: columns[columnIndex].entries,
            breadcrumbs: breadcrumbs(for: columns[columnIndex].path)
        )
        updateVisibleWatcherPaths()
    }

    private func applyKeyboardMove(to id: String, ids: [String], extend: Bool) {
        if extend {
            let anchor = keyboardAnchorID ?? lastClickedID ?? id
            if keyboardAnchorID == nil {
                keyboardAnchorID = anchor
            }
            guard let start = ids.firstIndex(of: anchor),
                  let end = ids.firstIndex(of: id) else {
                selectOnly(id)
                requestScrollToVisible(id)
                return
            }
            let range = ids[min(start, end)...max(start, end)]
            selectedIDs = Set(range)
            lastClickedID = id
        } else {
            keyboardAnchorID = id
            selectOnly(id)
        }
        requestScrollToVisible(id)
    }

    func requestScrollToVisible(_ id: String) {
        scrollToVisibleID = id
        scrollToVisibleTick &+= 1
    }

    private func rememberBrowserScroll(for path: String) {
        switch viewMode {
        case .icons:
            if let id = liveIconsAnchorID {
                scrollAnchorByPath[path] = id
            }
        case .list:
            if let row = BrowserScrollSupport.firstVisibleRowIndex(),
               let entries = listing?.entries,
               entries.indices.contains(row) {
                scrollAnchorByPath[path] = entries[row].id
            }
        case .columns:
            break
        }
    }

    /// Topmost visible icon id, kept live by `FileBrowserView`.
    private var liveIconsAnchorID: String?

    func noteIconsScroll(topVisibleID: String?) {
        guard viewMode == .icons else { return }
        liveIconsAnchorID = topVisibleID
    }

    func applyMarqueeSelection(_ ids: Set<String>, columnIndex: Int? = nil) {
        if let renamingID, !ids.contains(renamingID) {
            endRenameIfNeeded()
        }
        selectedIDs = ids
        lastClickedID = ids.first
        guard let columnIndex, columns.indices.contains(columnIndex) else { return }
        // Marquee never navigates into folders — only updates selection.
        columns[columnIndex].revealedChildID = nil
        columns = Array(columns.prefix(columnIndex + 1))
        let column = columns[columnIndex]
        currentPath = column.path
        listing = DirectoryListing(
            relativePath: column.path,
            entries: column.entries,
            breadcrumbs: breadcrumbs(for: column.path)
        )
    }

    func clearSelection() {
        endRenameIfNeeded()
        selectedIDs = []
        lastClickedID = nil
        keyboardAnchorID = nil
    }

    func selectOnly(_ id: String) {
        endRenameIfNeeded(keeping: id)
        selectedIDs = [id]
        lastClickedID = id
    }

    func toggleSelection(_ id: String) {
        endRenameIfNeeded(keeping: id)
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        lastClickedID = id
    }

    func selectRange(to id: String) {
        endRenameIfNeeded(keeping: id)
        let ids: [String]
        if viewMode == .list {
            ids = listOutlineRows().map(\.id)
        } else if let listing {
            ids = listing.entries.map(\.id)
        } else {
            selectOnly(id)
            return
        }
        guard let end = ids.firstIndex(of: id) else {
            selectOnly(id)
            return
        }
        let start: Int
        if let anchor = lastClickedID, let idx = ids.firstIndex(of: anchor) {
            start = idx
        } else {
            start = end
        }
        let range = ids[min(start, end)...max(start, end)]
        selectedIDs = Set(range)
        lastClickedID = id
    }

    /// Commit in-progress inline rename when the user clicks elsewhere (Finder-like).
    private func endRenameIfNeeded(keeping id: String? = nil) {
        guard let renamingID else { return }
        if let id, renamingID == id { return }
        submitRename()
    }

    /// Absolute URLs for Quick Look / thumbnails (local copy preferred).
    func previewURL(for entry: FileEntry) -> URL {
        openURL(for: entry)
    }

    func previewSelected() {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        let urls = entries.map(previewURL(for:))
        QuickLookController.shared.toggle(urls: urls, startingAt: 0)
    }

    /// Keep an open Quick Look panel in sync with the current selection (Finder-like).
    private func refreshQuickLookIfNeeded() {
        guard QuickLookController.shared.isVisible else { return }
        let entries = selectedEntries
        guard !entries.isEmpty else {
            QuickLookController.shared.close()
            return
        }
        // Prefer the keyboard/mouse anchor when present in the selection.
        let urls = entries.map(previewURL(for:))
        var start = 0
        if let anchor = lastClickedID,
           let idx = entries.firstIndex(where: { $0.id == anchor }) {
            start = idx
        }
        QuickLookController.shared.updateIfVisible(urls: urls, startingAt: start)
    }

    func requestRename(_ entry: FileEntry) {
        renameSourceEntry = entry
        renameDraft = entry.name
        // Avoid selection churn stealing focus from the rename field.
        if selectedIDs != [entry.id] {
            selectedIDs = [entry.id]
        }
        lastClickedID = entry.id
        renamingID = entry.id
    }

    func cancelRename() {
        renamingID = nil
        renameDraft = ""
        renameSourceEntry = nil
    }

    func submitRename() {
        guard let entry = renameSourceEntry else {
            cancelRename()
            return
        }
        let draft = renameDraft
        renamingID = nil
        renameDraft = ""
        renameSourceEntry = nil
        Task { await commitRename(entry, to: draft) }
    }

    private func commitRename(_ entry: FileEntry, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }

        isBusy = true
        defer { isBusy = false }
        do {
            let newPath = try await engine.renameItem(relativePath: entry.relativePath, newName: trimmed)
            pinnedPaths = await engine.getPinnedPaths()
            if let id = activeConnection?.id {
                store.setPinnedPaths(pinnedPaths, for: id)
            }
            columnListingCache.removeValue(forKey: entry.relativePath)
            let parent = (entry.relativePath as NSString).deletingLastPathComponent
            let parentNorm = parent == "." ? "" : parent
            columnListingCache.removeValue(forKey: parentNorm)

            if viewMode == .columns {
                await refreshVisibleColumns(clearSelection: false)
            } else {
                try await loadDirectory(currentPath, clearSelection: false)
            }
            selectedIDs = [newPath]
            lastClickedID = newPath
            requestScrollToVisible(newPath)
            statusMessage = "Renamed: \(trimmed)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestDeleteSelected() {
        guard !selectedIDs.isEmpty else { return }
        pendingDeleteIDs = selectedIDs
        presentDeleteConfirmationIfNeeded()
    }

    func requestDelete(entry: FileEntry) {
        if selectedIDs.contains(entry.id), selectedIDs.count > 1 {
            pendingDeleteIDs = selectedIDs
        } else {
            pendingDeleteIDs = [entry.id]
        }
        presentDeleteConfirmationIfNeeded()
    }

    private func presentDeleteConfirmationIfNeeded() {
        if store.skipDeleteConfirmation {
            Task {
                await confirmDelete()
                AppWindowFocus.reclaim()
            }
            return
        }

        let allEntries: [FileEntry] = {
            if viewMode == .columns {
                var seen = Set<String>()
                return columns.flatMap(\.entries).filter { seen.insert($0.id).inserted }
            }
            if viewMode == .list {
                return listOutlineRows().map(\.entry)
            }
            return listing?.entries ?? []
        }()
        let names = allEntries
            .filter { pendingDeleteIDs.contains($0.id) }
            .map(\.name)
        let title: String
        if names.count == 1 {
            title = "Delete “\(names[0])”?"
        } else {
            title = "Delete \(pendingDeleteIDs.count) selected items?"
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The item will be deleted from the network volume and from this Mac if a local copy exists."
        alert.alertStyle = .warning
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            store.skipDeleteConfirmation = true
        }

        // Reclaim key window so the next click is not swallowed by activation.
        DispatchQueue.main.async {
            AppWindowFocus.reclaim()
        }

        if response == .alertFirstButtonReturn {
            Task {
                await confirmDelete()
                await Task.yield()
                AppWindowFocus.reclaim()
            }
        } else {
            pendingDeleteIDs = []
        }
    }

    func confirmDelete() async {
        let ids = pendingDeleteIDs
        pendingDeleteIDs = []
        guard !ids.isEmpty else { return }

        isBusy = true
        defer {
            isBusy = false
            AppWindowFocus.reclaim()
        }
        do {
            try await engine.deleteItems(relativePaths: Array(ids))
            pinnedPaths = await engine.getPinnedPaths()
            if let id = activeConnection?.id {
                store.setPinnedPaths(pinnedPaths, for: id)
            }
            selectedIDs = []
            try await reloadAfterMutation()
            statusMessage = "Deleted"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveEntries(_ sources: [String], toDirectory destination: String) async {
        var uniqueSources = Array(Set(sources.filter { !$0.isEmpty }))
        // If dragging a selected item, move the whole selection.
        if uniqueSources.contains(where: { selectedIDs.contains($0) }) {
            uniqueSources = Array(selectedIDs)
        }
        guard !uniqueSources.isEmpty else { return }

        let filtered = uniqueSources.filter { source in
            let parent = (source as NSString).deletingLastPathComponent
            let parentNorm = parent == "." ? "" : parent
            return source != destination
                && parentNorm != destination
                && !destination.hasPrefix(source + "/")
        }
        guard !filtered.isEmpty else { return }

        isBusy = true
        defer { isBusy = false }
        do {
            try await engine.moveItems(relativePaths: filtered, toDirectory: destination)
            pinnedPaths = await engine.getPinnedPaths()
            if let id = activeConnection?.id {
                store.setPinnedPaths(pinnedPaths, for: id)
            }
            selectedIDs = []
            try await reloadAfterMutation()
            statusMessage = "Moved"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not move items"
        }
    }

    /// Import files/folders dropped from Finder (or other apps) into a directory.
    /// Runs in the background so browsing stays interactive.
    func importURLs(_ urls: [URL], toDirectory destination: String) async {
        let unique = Array(Set(urls.map { $0.standardizedFileURL }))
            .filter { !$0.path.isEmpty }
        guard !unique.isEmpty else { return }

        let filtered: [URL]
        if let active = activeConnection {
            let remote = (active.remotePath as NSString).standardizingPath
            let local = (active.localPath as NSString).standardizingPath
            filtered = unique.filter { url in
                let path = (url.path as NSString).standardizingPath
                return path != remote && path != local
                    && !path.hasPrefix(remote + "/")
                    && !path.hasPrefix(local + "/")
            }
            guard !filtered.isEmpty else {
                statusMessage = "These files are already on this volume — drag within Tethwork"
                return
            }
        } else {
            filtered = unique
        }

        enqueueImport(urls: filtered, destination: destination)
    }

    private func enqueueImport(urls: [URL], destination: String) {
        pendingImports.append(PendingImport(urls: urls, destination: destination))
        if let progress = importProgress {
            importProgress = ImportProgress(
                done: progress.done,
                total: progress.total,
                currentName: progress.currentName,
                destination: progress.destination,
                currentPath: progress.currentPath,
                queuedBatches: pendingImports.count
            )
            statusMessage = "\(pendingImports.count) more in queue…"
        }
        startNextImportIfNeeded()
    }

    private func startNextImportIfNeeded() {
        guard importTask == nil else { return }
        guard !pendingImports.isEmpty else { return }
        let next = pendingImports.removeFirst()
        importTask = Task { [weak self] in
            await self?.runImport(urls: next.urls, destination: next.destination)
            await MainActor.run {
                self?.importTask = nil
                self?.startNextImportIfNeeded()
            }
        }
    }

    func cancelBackgroundImport() {
        pendingImports.removeAll()
        importTask?.cancel()
        importTask = nil
        endImportActivity()
        importProgress = nil
        statusMessage = "Upload canceled"
    }

    private func beginImportActivity() {
        endImportActivity()
        importActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Tethwork is copying files to the network volume"
        )
    }

    private func endImportActivity() {
        if let importActivity {
            ProcessInfo.processInfo.endActivity(importActivity)
            self.importActivity = nil
        }
    }

    private func runImport(urls: [URL], destination: String) async {
        beginImportActivity()
        importProgress = ImportProgress(
            done: 0,
            total: max(urls.count, 1),
            currentName: urls.first?.lastPathComponent ?? "…",
            destination: destination,
            currentPath: destination,
            queuedBatches: pendingImports.count
        )
        statusMessage = urls.count == 1
            ? "Uploading “\(urls[0].lastPathComponent)” in background…"
            : "Uploading \(urls.count) items in background…"

        defer {
            endImportActivity()
            // Keep banner only if another batch will start immediately.
            if pendingImports.isEmpty {
                importProgress = nil
            }
        }

        do {
            try await engine.importItems(from: urls, toDirectory: destination) { [weak self] done, total, name in
                Task { @MainActor in
                    guard let self else { return }
                    self.importProgress = ImportProgress(
                        done: done,
                        total: total,
                        currentName: name,
                        destination: destination,
                        currentPath: self.importProgress?.currentPath ?? destination,
                        queuedBatches: self.pendingImports.count
                    )
                    self.statusMessage = "Uploading \(done) of \(total) · \(name)"
                }
            }
            try Task.checkCancellation()

            let total = importProgress?.total ?? urls.count
            if currentPath == destination {
                try await reloadAfterMutation()
            } else {
                // Drop stale cache so revisiting the folder shows new files.
                columnListingCache.removeValue(forKey: destination)
                let parent = (destination as NSString).deletingLastPathComponent
                let parentNorm = parent == "." ? "" : parent
                if currentPath == parentNorm {
                    try await reloadAfterMutation()
                } else {
                    columnListingCache.removeValue(forKey: parentNorm)
                }
            }

            statusMessage = total <= 1
                ? "Added: \(urls[0].lastPathComponent)"
                : "Added \(total) files"
        } catch is CancellationError {
            statusMessage = "Upload canceled"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not add files"
        }
    }

    /// Handle a browser drop: internal Tethwork move and/or Finder import.
    func handleBrowserDrop(internalPaths: [String], externalURLs: [URL], toDirectory destination: String) async {
        if !internalPaths.isEmpty {
            await moveEntries(internalPaths, toDirectory: destination)
        }
        if !externalURLs.isEmpty {
            await importURLs(externalURLs, toDirectory: destination)
        }
    }

    /// Force-refresh listing and column cache after delete/move.
    private func reloadAfterMutation() async throws {
        if viewMode == .columns {
            await refreshVisibleColumns(clearSelection: true)
        } else {
            try await loadDirectory(currentPath)
        }
    }

    var skipDeleteConfirmation: Bool {
        get { store.skipDeleteConfirmation }
        set {
            store.skipDeleteConfirmation = newValue
            objectWillChange.send()
        }
    }

    // MARK: - Sync pause

    var isSyncing: Bool {
        syncProgress != nil || importProgress != nil
    }

    var isSyncPaused: Bool {
        guard let until = syncPausedUntil else { return false }
        return until > Date()
    }

    var syncPauseDescription: String? {
        guard isSyncPaused, let until = syncPausedUntil else { return nil }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return "Paused until \(f.string(from: until))"
    }

    func pauseSync(hours: Double) {
        syncPausedUntil = Date().addingTimeInterval(hours * 3600)
        pauseTimer?.invalidate()
        let delay = hours * 3600
        pauseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.syncPausedUntil = nil
                self?.statusMessage = "Ready"
                self?.startBackgroundSyncIfNeeded()
            }
        }
        statusMessage = syncPauseDescription ?? "Paused"
    }

    func resumeSync() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        syncPausedUntil = nil
        statusMessage = "Ready"
        startBackgroundSyncIfNeeded()
    }

    static func pickFolder(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
