import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var connections: [SyncConnection] = []
    @Published var activeConnection: SyncConnection?
    @Published private(set) var connectingConnectionID: String?
    @Published var pinnedPaths: [String] = []
    @Published private(set) var favoriteFolders: [FavoriteFolder] = []
    @Published var listing: DirectoryListing? { didSet { cachedOutlineRows = nil } }
    @Published var currentPath: String = ""
    @Published var selectedIDs: Set<String> = []
    @Published var statusMessage: String = String(localized: "Ready")
    @Published var errorMessage: String?
    private var lastSyncErrorMessage: String?
    private var folderStorageStates: [String: FolderStorageState] = [:]
    private var folderStorageGeneration: UInt64 = 0
    @Published var isBusy = false
    @Published var isLoadingDirectory = false
    @Published private(set) var isMergingInitialFiles = false
    @Published var loadingFolderName: String?
    /// Non-blocking transfer feedback (Finder drops, etc.).
    @Published var importProgress: ImportProgress?
    /// Active pin/full sync transfer (status bar + per-row "Syncing…").
    @Published var syncProgress: SyncProgress?
    @Published private(set) var uploadBytesPerSecond: Double = 0
    @Published private(set) var downloadBytesPerSecond: Double = 0
    @Published var showConnectSheet = false
    @Published var editingConnection: SyncConnection?
    @Published private(set) var menuBarIconName: String = "default"
    @Published private(set) var isRemoteUnavailable: Bool = false
    @Published private(set) var connectionSyncStates: [String: ConnectionSyncCoordinator.State] = [:]
    private var connectionConfigurationErrors: [String: String] = [:]
    /// Filters / recursive search under the current folder.
    @Published var searchQuery: String = "" { didSet { cachedOutlineRows = nil } }
    @Published private(set) var showsHiddenFiles: Bool
    @Published private(set) var searchResults: [FileEntry] = [] { didSet { cachedOutlineRows = nil } }
    @Published private(set) var isSearchRunning = false
    @Published var viewMode: ViewMode {
        didSet { store.viewMode = viewMode.rawValue }
    }
    @Published var pendingDeleteIDs: Set<String> = []
    /// Trash from every configured network volume, grouped by connection.
    @Published private(set) var trashGroups: [TrashGroup] = []
    @Published private(set) var trashErrorMessage: String?
    struct TrashEntry: Identifiable {
        let connection: SyncConnection
        let item: TrashItem
        var id: String { "\(connection.id)|\(item.id)" }
    }
    struct TrashGroup: Identifiable {
        let connection: SyncConnection
        let items: [TrashEntry]
        let isAvailable: Bool
        var id: String { connection.id }
        let visibleItems: [TrashEntry]

        init(connection: SyncConnection, items: [TrashEntry], isAvailable: Bool) {
            self.connection = connection
            self.items = items
            self.isAvailable = isAvailable
            let folders = Dictionary(grouping: items.filter { $0.item.isDirectory }, by: { $0.item.originalPath })
            visibleItems = items.filter { entry in
                var parent = (entry.item.originalPath as NSString).deletingLastPathComponent
                while !parent.isEmpty && parent != "." {
                    if folders[parent]?.contains(where: { folder in
                        entry.item.deletedAt <= folder.item.deletedAt
                            && folder.item.deletedAt.timeIntervalSince(entry.item.deletedAt) <= 30
                    }) == true { return false }
                    parent = (parent as NSString).deletingLastPathComponent
                }
                return true
            }
        }
    }
    var trashItems: [TrashEntry] { trashGroups.flatMap(\.visibleItems) }
    @Published var trashSelection: Set<String> = []
    @Published private(set) var showingTrash = false
    @Published private(set) var isLoadingTrash = false
    @Published private(set) var isTrashBusy = false
    private var trashRefreshGeneration = 0
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
        var phase: SyncPhase = .transferring
        var direction: SyncEvent.TransferDirection? = nil
        var initialUpload: InitialUploadProgress? = nil

        var isIndeterminate: Bool {
            if let initialUpload { return phase == .preparing || initialUpload.bytesTotal == nil || total <= 0 }
            return total <= 0 || phase != .transferring
        }

        var fraction: Double {
            if let initialUpload { return initialUpload.fraction }
            guard total > 0 else { return 0 }
            return min(1, Double(done) / Double(total))
        }

        var percent: Int {
            Int((fraction * 100).rounded())
        }

        var byteSummary: String? {
            guard let initialUpload, let total = initialUpload.bytesTotal, phase != .preparing else { return nil }
            let done = ByteCountFormatter.string(fromByteCount: initialUpload.bytesDone, countStyle: .file)
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let format = phase == .transferring ? String(localized: "Uploaded %@ of %@") : String(localized: "Checked %@ of %@")
            return String(format: format, done, size)
        }

        var remainingTimeText: String? {
            guard let initialUpload, phase != .preparing, total > 0 else { return nil }
            guard let seconds = initialUpload.estimatedSecondsRemaining else {
                return String(localized: "Estimating time remaining…")
            }
            guard let remaining = Self.formattedRemainingTime(seconds) else { return nil }
            return String(format: String(localized: "This stage: %@"), remaining)
        }

        static func formattedRemainingTime(_ seconds: TimeInterval) -> String? {
            guard seconds.isFinite, seconds > 0 else { return nil }
            if seconds < 60 { return String(localized: "Less than a minute remaining") }
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 2
            guard let duration = formatter.string(from: ceil(seconds / 60) * 60) else { return nil }
            return String(format: String(localized: "About %@ remaining"), duration)
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
        var engine: SyncEngine
        var connectionID: String
    }

    private var importTask: Task<Void, Never>?
    private var pendingImports: [PendingImport] = []
    private var importActivity: NSObjectProtocol?
    private var pauseTimer: Timer?
    /// Hourly maintenance: purge trash items older than 15 days.
    private var trashMaintenanceTimer: Timer?
    private var trashMaintenanceTask: Task<Void, Never>?

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
    /// Not `@Published`: width changes during sidebar toggle must not re-render the split view.
    var iconsColumnsPerRow: Int = 4

    private var engine: SyncEngine
    private let syncCoordinator: ConnectionSyncCoordinator
    private let store: ConfigStore
    /// Bumped to cancel in-flight connect/restore so they cannot re-upsert a deleted disk.
    private var sessionGeneration = 0
    private var directoryLoadGeneration = 0
    private var trashRequestID: UUID?
    private var initialMergeTask: Task<[String], Error>?
    private var coordinatorAdoptionID: String?
    private var localStorageRequestID: UUID?
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
    private var columnListingCache: [String: [FileEntry]] = [:] { didSet { cachedOutlineRows = nil } }
    private var cachedOutlineRows: [OutlineRow]?
    private struct VolumeSnapshotKey: Hashable {
        var id: String
        var remote: String
        var local: String
        init(_ connection: SyncConnection) {
            id = connection.id
            remote = connection.remotePath
            local = connection.localPath
        }
    }
    /// Display-only snapshots; synchronization never uses this cache as a baseline.
    private var volumeRootSnapshots: [VolumeSnapshotKey: DirectoryListing] = [:]
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
    @Published private(set) var expandedFolderPaths: Set<String> = [] { didSet { cachedOutlineRows = nil } }
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

    init(store: ConfigStore = .shared, startsSession: Bool = true, engine: SyncEngine = SyncEngine(),
         engineFactory: @escaping () -> SyncEngine = { SyncEngine() }) {
        self.store = store
        self.engine = engine
        var initialEngine: SyncEngine? = engine
        self.syncCoordinator = ConnectionSyncCoordinator(makeEngine: {
            if let first = initialEngine { initialEngine = nil; return first }
            return engineFactory()
        })
        self.showsHiddenFiles = store.showsHiddenFiles
        if let mode = ViewMode(rawValue: store.viewMode) {
            viewMode = mode
        } else {
            viewMode = .list
        }
        syncCoordinator.onEvent = { [weak self] event in self?.handle(event) }
        syncCoordinator.onStatesChanged = { [weak self] states in
            guard let self else { return }
            self.connectionSyncStates = states
            for (id, error) in self.connectionConfigurationErrors {
                self.connectionSyncStates[id] = ConnectionSyncCoordinator.State(error: error)
            }
            if let id = self.coordinatorAdoptionID, self.activeConnection?.id == id {
                if self.syncCoordinator.isAdopting(id) {
                    self.restoreSelectedSyncProgress()
                } else {
                    self.coordinatorAdoptionID = nil
                    self.isMergingInitialFiles = false
                    self.syncProgress = nil
                    if let error = states[id]?.error { self.errorMessage = error }
                }
            }
            self.refreshMenuBarIcon()
        }
        syncCoordinator.onAdopted = { [weak self] id, paths in
            guard let self, self.store.connections.contains(where: { $0.id == id }) else { return }
            self.store.setPinnedPaths(paths, for: id)
            self.store.pendingInitialMergeIDs.remove(id)
            if self.activeConnection?.id == id {
                self.coordinatorAdoptionID = nil
                self.isMergingInitialFiles = false
                self.pinnedPaths = paths
                self.syncProgress = nil
                self.refreshListingsAfterTransfer()
            }
        }
        // Hosted XCTest launches the app too. Never reconnect or purge a user's
        // configured network volumes from a test host.
        guard startsSession, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
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
        Task { [weak self] in
            guard let self else { return }
            // App.init can construct this model before SwiftUI creates NSApp.
            // Defer AppKit work until the main actor starts running the app.
            NSApplication.shared.setActivationPolicy(.accessory)
            await restoreSession()
            synchronizeConfiguredConnections()
            if activeConnection == nil {
                startTrashMaintenance()
            }
        }
    }

    func refreshFromStore() {
        connections = store.connections
        favoriteFolders = store.favoriteFolders.filter { favorite in
            connections.contains { $0.id == favorite.connectionID }
        }
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
        refreshMenuBarIcon()
    }

    private var sessionRestoreRetry: Task<Void, Never>?

    private func restoreSession() async {
        guard let id = store.activeConnectionId,
              let connection = store.connections.first(where: { $0.id == id })
        else { return }

        if let conflict = Self.localRootConflict(
            for: connection,
            among: store.connections
        ) {
            errorMessage = "\(connection.localPath) is also used by \(conflict.name). Choose a separate local folder for each connection."
            statusMessage = "Connection needs attention"
            isRemoteUnavailable = false
            refreshMenuBarIcon()
            return
        }

        let generation = sessionGeneration
        isBusy = true
        defer { if generation == sessionGeneration { isBusy = false } }
        do {
            let pinned = store.pinnedPaths(for: connection.id)
            let resumeMerge = store.pendingInitialMergeIDs.contains(connection.id)
            let selectedEngine = try await syncCoordinator.connect(connection, pins: pinned,
                                                                   deferInitialMerge: resumeMerge, deferWatchers: true)
            guard generation == sessionGeneration,
                  store.connections.contains(where: { $0.id == connection.id })
            else { return }
            engine = selectedEngine
            folderStorageGeneration = 0
            activeConnection = connection
            pinnedPaths = await engine.getPinnedPaths()
            if resumeMerge { startInitialMerge(connection, generation: generation) }
            if viewMode == .columns {
                await ensureColumns(to: "", clearSelection: true)
            } else {
                try await loadDirectory("")
            }
            guard generation == sessionGeneration else { return }
            await engine.activateWatchers(connectionID: connection.id)
            guard generation == sessionGeneration else { return }
            startVisibleWatcher()
            startTrashMaintenance()
            if !resumeMerge { statusMessage = "Session restored" }
            errorMessage = nil
            sessionRestoreRetry?.cancel()
            sessionRestoreRetry = nil
            isRemoteUnavailable = false
            refreshMenuBarIcon()
            restoreSelectedSyncProgress()
            startBackgroundSyncIfNeeded()
        } catch {
            guard generation == sessionGeneration else { return }
            errorMessage = error.localizedDescription
            var isDirectory: ObjCBool = false
            let remoteAvailable = FileManager.default.fileExists(
                atPath: connection.remotePath, isDirectory: &isDirectory
            ) && isDirectory.boolValue
            statusMessage = remoteAvailable
                ? "Could not restore session: \(error.localizedDescription)"
                : "Waiting for network folder: \(connection.remotePath)"
            isRemoteUnavailable = true
            refreshMenuBarIcon()
            if !remoteAvailable {
                sessionRestoreRetry?.cancel()
                sessionRestoreRetry = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                        catch { return }
                        guard let self, self.sessionGeneration == generation,
                              self.store.activeConnectionId == connection.id else { return }
                        var isDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: connection.remotePath, isDirectory: &isDir),
                              isDir.boolValue, !self.isBusy else { continue }
                        await self.restoreSession()
                        return
                    }
                }
            }
        }
    }

    func handle(_ event: SyncEvent) {
        guard connectingConnectionID == nil else { return }
        if let source = event.connectionID, source != activeConnection?.id { return }
        if event.storageGeneration > folderStorageGeneration {
            folderStorageGeneration = event.storageGeneration
            folderStorageStates.removeAll()
        }
        // The initial uploader owns its progress until the engine adopts its paths.
        guard !isMergingInitialFiles else { return }
        if event.isRemoteAvailable {
            if isRemoteUnavailable {
                if let previous = lastSyncErrorMessage, errorMessage == previous { errorMessage = nil }
                lastSyncErrorMessage = nil
            }
            isRemoteUnavailable = false
            refreshMenuBarIcon()
        }
        if let speed = event.bytesPerSecond, let direction = event.transferDirection {
            switch direction {
            case .upload: uploadBytesPerSecond = speed
            case .download: downloadBytesPerSecond = speed
            }
        }
        switch event.kind {
        case .storage:
            guard event.storageGeneration == folderStorageGeneration,
                  let path = event.path, let state = event.folderStorageState else { return }
            folderStorageStates[path] = state
            applyFolderStorage(path: path, state: state)

        case .progress:
            // Show "Syncing" only while fixing real mismatches.
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
            } else if let done = event.progressDone {
                let name = event.path.map { ($0 as NSString).lastPathComponent }
                let wasNil = syncProgress == nil
                syncProgress = SyncProgress(
                    done: done,
                    total: event.progressTotal ?? 0,
                    activePath: event.path,
                    currentName: name,
                    phase: event.phase ?? .transferring,
                    direction: event.transferDirection ?? syncProgress?.direction,
                    initialUpload: event.initialUploadProgress
                )
                if wasNil { refreshMenuBarIcon() }
            }
            return

        case .complete:
            if let previous = lastSyncErrorMessage, errorMessage == previous { errorMessage = nil }
            lastSyncErrorMessage = nil
            syncProgress = nil
            uploadBytesPerSecond = 0
            downloadBytesPerSecond = 0
            isRemoteUnavailable = false
            refreshMenuBarIcon()
            statusMessage = event.message
            refreshListingsAfterTransfer()
            pinnedPathsRefresh()

        case .error:
            syncProgress = nil
            uploadBytesPerSecond = 0
            downloadBytesPerSecond = 0
            // A failed file or pinned folder does not mean the mounted remote
            // root is offline. Only a connectivity error should dim the icon.
            isRemoteUnavailable = event.isRemoteUnavailable
            refreshMenuBarIcon()
            statusMessage = event.message
            errorMessage = event.message
            lastSyncErrorMessage = event.message

        case .conflict:
            // Last-write-wins has already resolved this conflict. Inform without
            // interrupting the user with a confirmation that cannot change it.
            statusMessage = event.message

        case .file:
            // Explicit batch deletion refreshes the visible listing once below.
            guard trashRequestID == nil else { return }
            statusMessage = event.message
            if syncProgress == nil, importProgress == nil {
                refreshListingsAfterTransfer()
            }
            pinnedPathsRefresh()

        case .trash:
            statusMessage = event.message
            if syncProgress == nil, importProgress == nil {
                refreshListingsAfterTransfer()
            }
            pinnedPathsRefresh()
            // A local Finder deletion was propagated — keep the sidebar badge fresh.
            Task { [weak self] in
                await self?.refreshTrash(purgingExpired: false)
            }

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

    enum DisplayedSyncStatus: CaseIterable, Equatable {
        case local, partial, online, pending, preparing, checking, syncing, unavailable

        var title: String {
            switch self {
            case .local: return "Local"
            case .partial: return "Partially local"
            case .online: return "Online"
            case .pending: return "Pending sync"
            case .preparing: return "Preparing…"
            case .checking: return "Checking…"
            case .syncing: return "Syncing…"
            case .unavailable: return "Could not check"
            }
        }

        var systemImage: String {
            switch self {
            case .local: return "checkmark.circle"
            case .partial: return "circle.lefthalf.filled"
            case .online: return "icloud"
            case .pending, .checking: return "clock"
            case .preparing: return "arrow.down.circle"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .unavailable: return "exclamationmark.circle"
            }
        }

        var isSyncing: Bool { self == .preparing || self == .checking || self == .syncing }

        /// Shared by list, icons and columns. Pin policy never controls badge tint.
        func foregroundColor(isSelected: Bool, isKeyWindow: Bool) -> Color {
            if isSelected { return .white }
            guard isKeyWindow else { return .secondary }
            switch self {
            case .local, .partial, .preparing, .syncing: return .accentColor
            case .online, .pending, .checking: return .secondary
            case .unavailable: return .orange
            }
        }
    }

    /// Status label, icon and tint for a browser row (list / icons / columns).
    func displaySyncStatus(for entry: FileEntry) -> DisplayedSyncStatus {
        // Background preparation/checking must not replace a known folder badge.
        // Actual transfers still show Syncing immediately.
        let hasKnownFolderState = entry.isDirectory &&
            (entry.folderStorageState == .local || entry.folderStorageState == .partial)
        let isBackgroundCheck = syncProgress?.phase == .checking || syncProgress?.phase == .preparing
        if isActivelySyncing(entry.relativePath), !(hasKnownFolderState && isBackgroundCheck && importProgress == nil) {
            if syncProgress?.phase == .preparing { return .preparing }
            if syncProgress?.phase == .checking { return .checking }
            return .syncing
        }
        if entry.isDirectory, let state = entry.folderStorageState {
            switch state {
            case .local: return .local
            case .partial: return .partial
            case .onlineOnly: return .online
            case .pending: return .pending
            case .checking: return .checking
            case .unavailable: return .unavailable
            }
        }
        if entry.isDirectory, entry.syncMode == .onlineOnly, entry.hasPinnedDescendants {
            return entry.isLocallyAvailable ? .partial : .pending
        }
        switch entry.syncMode {
        case .offline:
            // Only when pinned copy is missing or differs from remote.
            if entry.syncStatus == .pending || entry.syncStatus == .syncing || !entry.isLocallyAvailable {
                if entry.isLocallyAvailable { return .pending }
                return .syncing
            }
            return .local
        case .onlineOnly:
            return .online
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
            let generation = sessionGeneration
            guard let id = activeConnection?.id else { return }
            let paths = await engine.getPinnedPaths()
            guard sessionGeneration == generation, activeConnection?.id == id else { return }
            pinnedPaths = paths
            store.setPinnedPaths(paths, for: id)
        }
    }

    private func storageAdjustedEntries(_ entries: [FileEntry]) -> [FileEntry] {
        entries.map { entry in
            guard entry.isDirectory, let state = folderStorageStates[entry.relativePath] else { return entry }
            var result = entry
            result.folderStorageState = state
            return result
        }
    }

    private func storageAdjustedColumns(_ value: [ColumnState]) -> [ColumnState] {
        value.map { column in
            var result = column
            result.entries = storageAdjustedEntries(column.entries)
            return result
        }
    }

    private func readDirectory(_ path: String) async throws -> DirectoryListing {
        let session = sessionGeneration
        let id = activeConnection?.id
        var result = try await engine.listDirectory(relativePath: path, includeHidden: showsHiddenFiles,
                                                    includeUnpinnedLocal: hasPendingInitialUpload)
        guard session == sessionGeneration, id == activeConnection?.id else { throw CancellationError() }
        if result.storageGeneration > folderStorageGeneration {
            folderStorageGeneration = result.storageGeneration
            folderStorageStates.removeAll()
        }
        result.entries = result.entries.map { entry in
            guard entry.isDirectory else { return entry }
            var updated = entry
            if let state = folderStorageStates[entry.relativePath] { updated.folderStorageState = state }
            else if result.storageGeneration < folderStorageGeneration,
                    entry.isLocallyAvailable, entry.syncMode == .offline || entry.hasPinnedDescendants {
                updated.folderStorageState = .checking
            }
            return updated
        }
        result.storageGeneration = folderStorageGeneration
        return result
    }

    /// Storage results update existing rows only: no new NAS listing or transfer
    /// is started for every completed background folder check.
    private func applyFolderStorage(path: String, state: FolderStorageState) {
        func needsUpdate(_ entries: [FileEntry]) -> Bool {
            entries.contains { $0.isDirectory && $0.relativePath == path && $0.folderStorageState != state }
        }
        func updated(_ entries: [FileEntry]) -> [FileEntry] {
            entries.map { entry in
                guard entry.isDirectory, entry.relativePath == path else { return entry }
                var result = entry
                result.folderStorageState = state
                return result
            }
        }
        if var current = listing, needsUpdate(current.entries) {
            current.entries = updated(current.entries)
            listing = current
        }
        if columns.contains(where: { needsUpdate($0.entries) }) {
            columns = columns.map { column in
                var result = column
                result.entries = updated(column.entries)
                return result
            }
        }
        if columnListingCache.values.contains(where: needsUpdate) {
            // Expanded list rows can exist only in this non-published cache.
            // Updating their data alone leaves SwiftUI showing Checking until
            // navigation causes an unrelated redraw.
            objectWillChange.send()
            columnListingCache = columnListingCache.mapValues(updated)
        }
        if needsUpdate(searchResults) { searchResults = updated(searchResults) }
        if let connection = activeConnection {
            let key = VolumeSnapshotKey(connection)
            if var snapshot = volumeRootSnapshots[key], needsUpdate(snapshot.entries) {
                snapshot.entries = updated(snapshot.entries)
                volumeRootSnapshots[key] = snapshot
            }
        }
    }

    func loadDirectory(_ relative: String, clearSelection: Bool = true) async throws {
        directoryLoadGeneration += 1
        let request = directoryLoadGeneration
        let session = sessionGeneration
        let connectionID = activeConnection?.id
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

        let loaded = try await readDirectory(relative)
        guard request == directoryLoadGeneration, session == sessionGeneration,
              connectionID == activeConnection?.id else { throw CancellationError() }
        var adjusted = loaded
        adjusted.entries = storageAdjustedEntries(loaded.entries)
        listing = adjusted
        if relative.isEmpty, let connection = activeConnection {
            rememberRootSnapshot(adjusted, for: connection)
        }
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
        guard request == directoryLoadGeneration, session == sessionGeneration else { throw CancellationError() }

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
        guard connectingConnectionID == nil else { return }
        let session = sessionGeneration
        let name = displayName
            ?? (relative.isEmpty
                ? (activeConnection?.name ?? "Root")
                : (relative as NSString).lastPathComponent)

        isLoadingDirectory = viewMode != .columns
        loadingFolderName = name
        statusMessage = "Opening \u{201C}\(name)\u{201D}\u{2026}"
        defer {
            if session == sessionGeneration {
                isLoadingDirectory = false
                loadingFolderName = nil
            }
        }

        do {
            if viewMode == .columns {
                await ensureColumns(to: relative, displayName: name)
            } else {
                try await loadDirectory(relative)
            }
            guard session == sessionGeneration else { return }
            statusMessage = "Ready"
        } catch is CancellationError {
            return
        } catch {
            guard session == sessionGeneration else { return }
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

    private var hasPendingInitialUpload: Bool {
        isMergingInitialFiles || activeConnection.map { store.pendingInitialMergeIDs.contains($0.id) } == true
    }

    func setShowsHiddenFiles(_ value: Bool) {
        guard value != showsHiddenFiles, connectingConnectionID == nil, !isLoadingDirectory else { return }
        showsHiddenFiles = value
        store.showsHiddenFiles = value
        volumeRootSnapshots.removeAll()
        columnListingCache.removeAll()
        cachedOutlineRows = nil
        columnsNavigationGeneration += 1
        columnsRefreshGeneration += 1
        guard activeConnection != nil else { return }
        Task {
            if !normalizedSearchQuery.isEmpty {
                await runRecursiveSearch(searchQuery)
            } else if viewMode == .columns {
                columns = []
                await ensureColumns(to: currentPath, clearSelection: false)
            } else {
                try? await loadDirectory(currentPath, clearSelection: false)
            }
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

        statusMessage = "Opening \u{201C}\(folderName)\u{201D}\u{2026}"

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
            // otherwise the first column stays on "Empty Folder" forever.
            if path != targetPath, let existing, Self.isReusableAncestor(existing, revealed: revealed) {
                var column = existing
                column.revealedChildID = revealed
                next.append(column)
                continue
            }

            do {
                let listing = try await readDirectory(path)
                guard generation == columnsNavigationGeneration else { return }
                if path.isEmpty, let connection = activeConnection {
                    rememberRootSnapshot(listing, for: connection)
                }
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
                columns = storageAdjustedColumns(progressive)
            } catch {
                guard generation == columnsNavigationGeneration else { return }
                next.append(.empty(path: path, loading: false))
                columns = storageAdjustedColumns(next)
                errorMessage = error.localizedDescription
                statusMessage = "Could not open folder"
                return
            }
        }

        guard generation == columnsNavigationGeneration else { return }

        columns = storageAdjustedColumns(next)
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
            columns = storageAdjustedColumns(next)
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
        // Never interrupt an in-progress folder open — that left columns stuck on "Loading…".
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
                let listing = try await readDirectory(column.path)
                guard generation == columnsRefreshGeneration else { return }
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

        columns = storageAdjustedColumns(refreshed)
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
    /// that was leaving the first Miller column stuck on "Empty Folder".
    nonisolated private static func isReusableCache(_ entries: [FileEntry], revealed: String?) -> Bool {
        if entries.isEmpty { return revealed == nil }
        guard let revealed else { return true }
        return entries.contains(where: { $0.relativePath == revealed && $0.isDirectory })
    }

    func connect(name: String, remotePath: String, localPath: String, connectionId: String? = nil,
                 mergeLocalFiles: Bool = false) async {
        if let connectionId, blockedConnectionIDs.contains(connectionId) {
            return
        }

        sessionGeneration += 1
        let generation = sessionGeneration
        let requestedID = connectionId ?? UUID().uuidString
        folderStorageStates.removeAll()
        folderStorageGeneration = 0
        connectingConnectionID = requestedID
        // The old engine operation is cancelled by connect. Its final events
        // are intentionally rejected, so clear its progress here rather than
        // leaving a permanent Checking badge on the newly selected volume.
        syncProgress = nil
        importProgress = nil
        uploadBytesPerSecond = 0
        downloadBytesPerSecond = 0
        listing = nil
        columns = [.empty(path: "", loading: true)]
        columnListingCache.removeAll()
        expandedFolderPaths.removeAll()
        expandingFolderPaths.removeAll()
        searchQuery = ""
        searchResults = []
        isLoadingDirectory = true
        loadingFolderName = name
        directoryLoadGeneration += 1
        columnsNavigationGeneration += 1
        columnsRefreshGeneration += 1
        columnPreviewGeneration += 1
        searchGeneration += 1
        columnPreviewTask?.cancel()
        selectedIDs = []
        cancelRename()
        QuickLookController.shared.close()
        stopVisibleWatcher()
        await stopInitialMerge(cancelBackground: false)
        guard generation == sessionGeneration else { return }
        coordinatorAdoptionID = nil
        isMergingInitialFiles = false

        isBusy = true
        errorMessage = nil
        statusMessage = "Connecting…"
        defer {
            if generation == sessionGeneration {
                isBusy = false
                connectingConnectionID = nil
                isLoadingDirectory = false
                loadingFolderName = nil
            }
        }

        let connection = SyncConnection(
            id: requestedID,
            name: name.isEmpty ? URL(fileURLWithPath: remotePath).lastPathComponent : name,
            remotePath: remotePath,
            localPath: localPath
        )

        if blockedConnectionIDs.contains(connection.id) {
            return
        }

        let candidate = SyncConnection(
            id: connection.id,
            name: connection.name,
            remotePath: remotePath,
            localPath: localPath,
            createdAt: connection.createdAt
        )
        let configured = store.connections
        do {
            try await Task.detached(priority: .userInitiated) {
                // Remote availability and containment are checked once, by the
                // engine. Do not repeat network stats/symlink resolution here.
                if let conflict = Self.localRootConflict(for: candidate, among: configured) {
                    throw SyncError.invalidMove("\(localPath) is already used by \(conflict.name). Choose a separate local folder for each connection.")
                }
            }.value
        } catch {
            guard generation == sessionGeneration else { return }
            errorMessage = error.localizedDescription
            statusMessage = "Connection failed"
            if case SyncError.remoteUnavailable = error { isRemoteUnavailable = true }
            else { isRemoteUnavailable = false }
            refreshMenuBarIcon()
            if let previous = activeConnection {
                listing = volumeRootSnapshots[VolumeSnapshotKey(previous)]
                currentPath = ""
                columns = [ColumnState(path: "", entries: listing?.entries ?? [], revealedChildID: nil, isLoading: false)]
                startVisibleWatcher()
            }
            return
        }
        guard generation == sessionGeneration else { return }

        let mergeRequired = mergeLocalFiles || store.pendingInitialMergeIDs.contains(connection.id)
        syncCoordinator.resume(connection.id)
        activeConnection = connection
        currentPath = ""
        listing = volumeRootSnapshots[VolumeSnapshotKey(connection)]
        if let snapshot = listing {
            columnListingCache[""] = snapshot.entries
            columns = [ColumnState(path: "", entries: snapshot.entries, revealedChildID: nil, isLoading: true)]
        }
        do {
            let pinned = mergeRequired ? [] : store.pinnedPaths(for: connection.id)
            let selectedEngine = try await syncCoordinator.connect(connection, pins: pinned,
                                                                   deferInitialMerge: mergeRequired, deferWatchers: true)
            guard generation == sessionGeneration else { return }
            guard !blockedConnectionIDs.contains(connection.id) else {
                await syncCoordinator.remove(connection.id)
                return
            }
            engine = selectedEngine

            store.upsert(connection)
            if mergeRequired { store.pendingInitialMergeIDs.insert(connection.id) }
            connections = store.connections.filter { !blockedConnectionIDs.contains($0.id) }
            activeConnection = connection
            currentPath = ""
            selectedIDs = []
            expandedFolderPaths.removeAll()
            expandingFolderPaths.removeAll()
            isRemoteUnavailable = false
            pinnedPaths = await engine.getPinnedPaths()
            guard generation == sessionGeneration, !blockedConnectionIDs.contains(connection.id) else {
                return
            }
            store.setPinnedPaths(pinnedPaths, for: connection.id)
            // The connection is ready to browse. Uploading existing local content
            // is a separate background task, never a prerequisite for dismissing the form.
            showConnectSheet = false
            if mergeRequired {
                startInitialMerge(connection, generation: generation)
            } else {
                statusMessage = "Connected"
            }
            isLoadingDirectory = true
            loadingFolderName = connection.name
            // The engine now belongs to this disk; browsing may proceed.
            connectingConnectionID = nil
            restoreSelectedSyncProgress()
            do {
                if viewMode == .columns {
                    await ensureColumns(to: "", clearSelection: true)
                } else {
                    try await loadDirectory("")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            guard generation == sessionGeneration else { return }
            isLoadingDirectory = false
            loadingFolderName = nil
            await engine.activateWatchers(connectionID: connection.id)
            guard generation == sessionGeneration else { return }
            startVisibleWatcher()
            startTrashMaintenance()
            refreshMenuBarIcon()
            synchronizeConfiguredConnections()
        } catch {
            guard generation == sessionGeneration else { return }
            initialMergeTask = nil
            activeConnection = connection
            listing = nil
            currentPath = ""
            columns = [.empty(path: "")]
            columnListingCache.removeAll()
            pinnedPaths = []
            isLoadingDirectory = false
            loadingFolderName = nil
            errorMessage = error.localizedDescription
            statusMessage = "Connection failed"
            isRemoteUnavailable = true
            refreshMenuBarIcon()
        }
    }

    private func rememberRootSnapshot(_ snapshot: DirectoryListing, for connection: SyncConnection) {
        let key = VolumeSnapshotKey(connection)
        var adjusted = snapshot
        adjusted.entries = storageAdjustedEntries(snapshot.entries)
        volumeRootSnapshots[key] = adjusted
        if volumeRootSnapshots.count > 16,
           let oldest = volumeRootSnapshots.keys.first(where: { $0 != key }) {
            volumeRootSnapshots.removeValue(forKey: oldest)
        }
    }

    nonisolated private static func syncRootsAreDisjoint(remotePath: String, localPath: String) -> Bool {
        let remote = canonicalPath(remotePath)
        let local = canonicalPath(localPath)
        guard !remote.isEmpty, !local.isEmpty,
              remote != "/", local != "/", remote != local else { return false }
        return !remote.hasPrefix(local + "/") && !local.hasPrefix(remote + "/")
    }

    nonisolated private static func canonicalPath(_ path: String) -> String {
        SyncEngine.canonicalPath(path)
    }

    nonisolated private static func localRootConflict(
        for candidate: SyncConnection,
        among connections: [SyncConnection]
    ) -> SyncConnection? {
        let candidatePath = canonicalPath(candidate.localPath)
        return connections.first { existing in
            existing.id != candidate.id && canonicalPath(existing.localPath) == candidatePath
        }
    }

    func selectConnection(_ connection: SyncConnection) async {
        guard !blockedConnectionIDs.contains(connection.id) else { return }
        guard connections.contains(where: { $0.id == connection.id }) else { return }

        // Already connected to this disk — do not reconnect (avoids re-upsert races).
        if connectingConnectionID == nil, activeConnection?.id == connection.id,
           listing != nil {
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
        folderStorageStates.removeAll()
        directoryLoadGeneration += 1
        columnsNavigationGeneration += 1
        columnsRefreshGeneration += 1
        connectingConnectionID = nil
        await stopInitialMerge()
        stopVisibleWatcher()
        if let id = activeConnection?.id { await syncCoordinator.suspend(id) }
        store.activeConnectionId = nil
        activeConnection = nil
        listing = nil
        isLoadingDirectory = false
        loadingFolderName = nil
        pinnedPaths = []
        selectedIDs = []
        columnListingCache.removeAll()
        scrollAnchorByPath.removeAll()
        liveIconsAnchorID = nil
        cancelRename()
        cancelBackgroundImport()
        syncProgress = nil
        isRemoteUnavailable = false
        refreshMenuBarIcon()
        expandedFolderPaths.removeAll()
        expandingFolderPaths.removeAll()
        stopTrashMaintenance()
        statusMessage = "Disconnected"
        connections = store.connections.filter { !blockedConnectionIDs.contains($0.id) }
        await refreshTrash(purgingExpired: false)
    }

    func deleteConnection(_ id: String) async {
        blockedConnectionIDs.insert(id)
        let removingActive = activeConnection?.id == id
        if removingActive {
            sessionGeneration += 1
            await stopInitialMerge()
        }

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
            isRemoteUnavailable = false
            stopTrashMaintenance()
            refreshMenuBarIcon()
        }
        connections.removeAll { $0.id == id }
        connections = store.deleteConnection(id: id)
        favoriteFolders = store.favoriteFolders

        await syncCoordinator.remove(id)

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
        // invalidate in-flight work so the next "New Connection" can use a fresh id now.
        if removingActive { sessionGeneration += 1 }
        blockedConnectionIDs.remove(id)
        statusMessage = "Connection removed"
        synchronizeConfiguredConnections()
        await refreshTrash(purgingExpired: false)
    }

    private func stopInitialMerge(cancelBackground: Bool = true) async {
        guard let task = initialMergeTask else {
            if let id = coordinatorAdoptionID {
                coordinatorAdoptionID = nil
                isMergingInitialFiles = false
                syncProgress = nil
                if cancelBackground { await syncCoordinator.cancelAdoption(id) }
            }
            return
        }
        let connectionID = activeConnection?.id
        let engine = self.engine
        task.cancel()
        initialMergeTask = nil
        isMergingInitialFiles = false
        syncProgress = nil
        // Do not permit deletion or another connection to race the final rename
        // of a cancelled upload. Cancellation is checked before publishing files.
        _ = await task.result
        if let id = connectionID {
            try? await engine.abortInitialMerge(connectionID: id)
        }
    }

    private func startInitialMerge(_ connection: SyncConnection, generation: Int) {
        if syncCoordinator.isAdopting(connection.id) {
            coordinatorAdoptionID = connection.id
            isMergingInitialFiles = true
            restoreSelectedSyncProgress()
            return
        }
        isMergingInitialFiles = true
        uploadBytesPerSecond = 0
        downloadBytesPerSecond = 0
        statusMessage = String(localized: "Checking existing local files…")
        syncProgress = SyncProgress(done: 0, total: 0, currentName: String(localized: "Checking local files"), phase: .preparing, direction: .upload)
        let task = Task { [weak self] in
            try await SyncEngine.mergeExistingLocalFiles(connection: connection, onTransferRate: nil, onSnapshot: { [weak self] snapshot in
                Task { @MainActor in
                    guard let self, self.sessionGeneration == generation, self.isMergingInitialFiles else { return }
                    if let rate = snapshot.bytesPerSecond { self.uploadBytesPerSecond = rate }
                    self.statusMessage = snapshot.phase == .preparing ? String(localized: "Counting files…") :
                        (snapshot.phase == .checking ? String(localized: "Checking local copies…") :
                         (snapshot.phase == .finishing ? String(localized: "Final checks…") : String(localized: "Uploading files…")))
                    self.syncProgress = SyncProgress(done: snapshot.filesDone, total: snapshot.filesTotal,
                                                     activePath: snapshot.currentPath, currentName: (snapshot.currentPath as NSString).lastPathComponent,
                                                     phase: snapshot.phase, direction: .upload, initialUpload: snapshot)
                }
            })
        }
        initialMergeTask = task
        refreshMenuBarIcon()
        Task { [weak self] in
            do {
                let paths = try await task.value
                guard let self, self.sessionGeneration == generation else { return }
                let adopted = try await self.engine.finishInitialMerge(connectionID: connection.id, paths: paths)
                guard self.sessionGeneration == generation else { return }
                self.pinnedPaths = adopted
                self.store.setPinnedPaths(adopted, for: connection.id)
                self.store.pendingInitialMergeIDs.remove(connection.id)
                self.initialMergeTask = nil
                self.isMergingInitialFiles = false
                self.syncProgress = nil
                self.errorMessage = nil
                self.statusMessage = String(localized: "Local files merged")
                self.uploadBytesPerSecond = 0
                self.downloadBytesPerSecond = 0
                self.refreshMenuBarIcon()
                self.refreshListingsAfterTransfer()
                self.startBackgroundSyncIfNeeded()
            } catch {
                guard let self, self.sessionGeneration == generation else { return }
                try? await self.engine.abortInitialMerge(connectionID: connection.id)
                guard self.sessionGeneration == generation else { return }
                self.initialMergeTask = nil
                self.isMergingInitialFiles = false
                self.syncProgress = nil
                self.errorMessage = error.localizedDescription
                self.statusMessage = String(localized: "Could not upload existing local files")
                self.uploadBytesPerSecond = 0
                self.downloadBytesPerSecond = 0
                self.refreshMenuBarIcon()
                self.refreshListingsAfterTransfer()
            }
        }
    }

    /// Always mints a new connection id (used by "New Connection").
    func connectNew(name: String, remotePath: String, localPath: String) async {
        await connect(
            name: name,
            remotePath: remotePath,
            localPath: localPath,
            connectionId: UUID().uuidString,
            mergeLocalFiles: true
        )
    }

    func updateConnection(id: String, name: String, remotePath: String, localPath: String) async {
        guard let existing = connections.first(where: { $0.id == id }) else { return }
        var updated = existing
        updated.name = name
        updated.remotePath = remotePath
        updated.localPath = localPath
        store.update(updated)
        connections = store.connections.filter { !blockedConnectionIDs.contains($0.id) }
        editingConnection = nil
        if activeConnection?.id == id {
            let pathsChanged = remotePath != existing.remotePath || localPath != existing.localPath
            if pathsChanged {
                await connect(name: name, remotePath: remotePath, localPath: localPath, connectionId: id)
            } else {
                activeConnection = updated
            }
        }
        synchronizeConfiguredConnections()
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
            statusMessage = "Could not open \u{201C}\(entry.name)\u{201D}"
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

    func isFavorite(_ relativePath: String) -> Bool {
        guard let id = activeConnection?.id else { return false }
        return favoriteFolders.contains { $0.connectionID == id && $0.relativePath == relativePath }
    }

    func toggleFavorite(_ relativePath: String) {
        guard let id = activeConnection?.id else { return }
        if let index = favoriteFolders.firstIndex(where: {
            $0.connectionID == id && $0.relativePath == relativePath
        }) {
            favoriteFolders.remove(at: index)
        } else {
            favoriteFolders.append(FavoriteFolder(connectionID: id, relativePath: relativePath))
        }
        store.favoriteFolders = favoriteFolders
    }

    func removeFavorite(_ id: String) {
        favoriteFolders.removeAll { $0.id == id }
        store.favoriteFolders = favoriteFolders
    }

    func favoriteTitle(_ favorite: FavoriteFolder) -> String {
        if favorite.relativePath.isEmpty {
            return connections.first { $0.id == favorite.connectionID }?.name ?? "Volume"
        }
        return (favorite.relativePath as NSString).lastPathComponent
    }

    private func remapFavorites(connectionID: String, from source: String, to destination: String) {
        favoriteFolders = favoriteFolders.map { favorite in
            guard favorite.connectionID == connectionID else { return favorite }
            var updated = favorite
            if favorite.relativePath == source {
                updated.relativePath = destination
            } else if favorite.relativePath.hasPrefix(source + "/") {
                updated.relativePath = destination + favorite.relativePath.dropFirst(source.count)
            }
            return updated
        }
        store.favoriteFolders = favoriteFolders
    }

    func togglePin(_ entry: FileEntry) async {
        guard connectingConnectionID == nil else { return }
        await changeLocalStorage(entry.relativePath, title: entry.name, pinned: entry.syncMode != .offline)
    }

    func togglePinCurrent() async {
        guard connectingConnectionID == nil else { return }
        await changeLocalStorage(currentPath, title: currentFolderTitle, pinned: !isCurrentPinned)
    }

    /// Unpin a saved sidebar folder without requiring it to be the current path.
    func unpinPath(_ relativePath: String) async {
        let title = relativePath.isEmpty
            ? (activeConnection?.name ?? "Disk")
            : (relativePath as NSString).lastPathComponent
        await changeLocalStorage(relativePath, title: title, pinned: false)
    }

    private func changeLocalStorage(_ path: String, title: String, pinned: Bool) async {
        guard !hasPendingInitialUpload else {
            errorMessage = String(localized: "Finish the initial upload, or retry it with Sync Now, before changing local storage.")
            return
        }
        guard let id = activeConnection?.id else { return }
        let generation = sessionGeneration
        let engine = self.engine
        let requestID = UUID()
        localStorageRequestID = requestID
        defer {
            if localStorageRequestID == requestID { localStorageRequestID = nil }
        }
        errorMessage = nil
        statusMessage = pinned ? "Preparing download of “\(title)”…" : "Removing local copy of “\(title)”…"
        if pinned {
            syncProgress = SyncProgress(done: 0, total: 0, activePath: path, currentName: title,
                                        phase: .preparing, direction: .download)
            // Persist the user's request immediately, not after a potentially long download.
            pinnedPaths = SyncEngine.compactPinnedPaths(pinnedPaths + [path])
            store.setPinnedPaths(pinnedPaths, for: id)
            refreshMenuBarIcon()
        }
        do {
            let paths = try await engine.setPinned(relativePath: path, pinned: pinned)
            if store.connections.contains(where: { $0.id == id }) { store.setPinnedPaths(paths, for: id) }
            guard generation == sessionGeneration, activeConnection?.id == id else { return }
            pinnedPaths = paths
            store.setPinnedPaths(paths, for: id)
            try await loadDirectory(currentPath, clearSelection: false)
            if generation == sessionGeneration { statusMessage = pinned ? "Local: \(title)" : "Online only: \(title)" }
        } catch is CancellationError {
            // A delete or connection switch owns the replacement progress/status.
            return
        } catch {
            let paths = await engine.getPinnedPaths()
            if store.connections.contains(where: { $0.id == id }) { store.setPinnedPaths(paths, for: id) }
            guard generation == sessionGeneration, activeConnection?.id == id else { return }
            pinnedPaths = paths
            store.setPinnedPaths(paths, for: id)
            syncProgress = nil
            errorMessage = error.localizedDescription
            statusMessage = String(localized: "Could not change local storage")
            refreshMenuBarIcon()
        }
    }

    func fullSync(recheckContents: Bool = false) async {
        guard connectingConnectionID == nil else { return }
        guard !isMergingInitialFiles, localStorageRequestID == nil else { return }
        if let connection = activeConnection, store.pendingInitialMergeIDs.contains(connection.id) {
            let generation = sessionGeneration
            do {
                try await engine.prepareInitialMerge(connectionID: connection.id)
                guard generation == sessionGeneration else { return }
                errorMessage = nil
                startInitialMerge(connection, generation: generation)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        // Never set isBusy — sync must not freeze browsing.
        // Progress belongs to the engine events. An overlapping request can be
        // rejected and must not clear the transfer already running.
        await engine.fullSync(recheckContents: recheckContents)
    }

    /// Kick off sync without blocking connect / restore.
    func startBackgroundSyncIfNeeded() {
        synchronizeConfiguredConnections()
    }

    /// Every configured volume owns a session, independent of the browser.
    func synchronizeConfiguredConnections() {
        guard !isSyncPaused else { return }
        let configured = store.connections.filter { !blockedConnectionIDs.contains($0.id) }
        // Refuse overlapping local trees just as the foreground connection does.
        connectionConfigurationErrors.removeAll()
        let safe = configured.filter { connection in
            guard let conflict = Self.localRootConflict(for: connection, among: configured) else { return true }
            connectionConfigurationErrors[connection.id] = "\(connection.localPath) is also used by \(conflict.name). Choose a separate local folder for each connection."
            return false
        }
        let externalMerges = initialMergeTask == nil ? Set<String>() : Set([activeConnection?.id].compactMap { $0 })
        syncCoordinator.synchronize(safe, pins: store.pinnedByConnection,
                                    pendingInitialMerges: store.pendingInitialMergeIDs, externallyMerging: externalMerges)
        for (id, error) in connectionConfigurationErrors {
            connectionSyncStates[id] = ConnectionSyncCoordinator.State(error: error)
        }
    }

    func shutdownSynchronization() async {
        await stopInitialMerge()
        await syncCoordinator.shutdown()
    }

    private func restoreSelectedSyncProgress() {
        guard let id = activeConnection?.id, (!isMergingInitialFiles || syncCoordinator.isAdopting(id)),
              let state = connectionSyncStates[id] else { return }
        if let event = state.progress {
            syncProgress = SyncProgress(done: event.progressDone ?? 0, total: event.progressTotal ?? 0,
                                        activePath: event.path, currentName: event.path.map { ($0 as NSString).lastPathComponent },
                                        phase: event.phase ?? .transferring, direction: event.transferDirection,
                                        initialUpload: event.initialUploadProgress)
        } else {
            syncProgress = nil
        }
        uploadBytesPerSecond = state.uploadBytesPerSecond
        downloadBytesPerSecond = state.downloadBytesPerSecond
        if let error = state.error { errorMessage = error }
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
        watcher.start(watching: urls, interval: 1.0)
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
        if let cachedOutlineRows { return cachedOutlineRows }
        if !normalizedSearchQuery.isEmpty {
            let rows = searchResults.map { OutlineRow(entry: $0, depth: 0) }
            cachedOutlineRows = rows
            return rows
        }
        guard let roots = listing?.entries else { return [] }
        var rows: [OutlineRow] = []
        appendOutlineRows(roots, depth: 0, into: &rows)
        cachedOutlineRows = rows
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
            let results = try await engine.search(query: query, under: root, includeHidden: showsHiddenFiles) { [weak self] partial in
                Task { @MainActor in
                    guard let self, generation == self.searchGeneration else { return }
                    self.searchResults = self.storageAdjustedEntries(partial)
                }
            }
            guard generation == searchGeneration, currentPath == root else { return }
            searchResults = storageAdjustedEntries(results)
            pruneSelectionToVisibleEntries()
            statusMessage = results.isEmpty
                ? "No results"
                : "Found: \(results.count)"
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
            errorMessage = error.localizedDescription
            statusMessage = String(localized: "Search failed")
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
        guard connectingConnectionID == nil else { return }
        let session = sessionGeneration
        guard entry.isDirectory else { return }
        let path = entry.relativePath
        if expandedFolderPaths.contains(path) {
            collapseFolder(path)
            updateVisibleWatcherPaths()
            return
        }

        expandedFolderPaths.insert(path)
        expandingFolderPaths.insert(path)
        defer { if session == sessionGeneration { expandingFolderPaths.remove(path) } }

        do {
            let listing = try await readDirectory(path)
            guard session == sessionGeneration else { return }
            columnListingCache[path] = listing.entries
            updateVisibleWatcherPaths()
        } catch {
            guard session == sessionGeneration else { return }
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
        let session = sessionGeneration
        let paths = expandedFolderPaths.sorted()
        guard !paths.isEmpty else { return }
        var stillExpanded = Set<String>()
        for path in paths {
            do {
                let listing = try await readDirectory(path)
                guard session == sessionGeneration else { return }
                columnListingCache[path] = listing.entries
                stillExpanded.insert(path)
            } catch {
                guard session == sessionGeneration else { return }
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
        let entries = displayedEntries(from: listing?.entries ?? [])
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
                columns = storageAdjustedColumns(next)
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
            columns = storageAdjustedColumns(next)
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
            columns = storageAdjustedColumns(next)
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
        columns = storageAdjustedColumns(next)

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
            columns = storageAdjustedColumns(next)
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
            columns = storageAdjustedColumns(next)
            focusColumn(columnIndex + 1)
            updateVisibleWatcherPaths()
            Task { await quietlyRefreshColumn(path: targetPath) }
            return
        }

        next.append(.empty(path: targetPath, loading: true))
        columns = storageAdjustedColumns(next)
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
            let listing = try await readDirectory(path)
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
        collapseColumns(to: columnIndex)
    }

    func collapseColumns(to columnIndex: Int) {
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
        if lastClickedID.map({ ids.contains($0) }) != true {
            let entries = columnIndex.flatMap { columns.indices.contains($0) ? columns[$0].entries : nil }
                ?? displayedEntries(from: listing?.entries ?? [])
            lastClickedID = entries.first(where: { ids.contains($0.id) })?.id
        }
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
        updateVisibleWatcherPaths()
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
            ids = displayedEntries(from: listing.entries).map(\.id)
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
        let start = entries.firstIndex(where: { $0.id == lastClickedID }) ?? 0
        QuickLookController.shared.toggle(urls: urls, startingAt: start)
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
        let generation = sessionGeneration
        let engine = self.engine
        let connectionID = activeConnection?.id
        defer { if generation == sessionGeneration { isBusy = false } }
        do {
            let newPath = try await engine.renameItem(relativePath: entry.relativePath, newName: trimmed)
            if let connectionID {
                remapFavorites(connectionID: connectionID, from: entry.relativePath, to: newPath)
            }
            let paths = await engine.getPinnedPaths()
            if let id = connectionID, store.connections.contains(where: { $0.id == id }) {
                store.setPinnedPaths(paths, for: id)
            }
            guard generation == sessionGeneration else { return }
            pinnedPaths = paths
            columnListingCache.removeValue(forKey: entry.relativePath)
            let parent = (entry.relativePath as NSString).deletingLastPathComponent
            let parentNorm = parent == "." ? "" : parent
            columnListingCache.removeValue(forKey: parentNorm)

            if viewMode == .columns {
                await refreshVisibleColumns(clearSelection: false)
            } else {
                try await loadDirectory(currentPath, clearSelection: false)
            }
            guard generation == sessionGeneration else { return }
            selectedIDs = [newPath]
            lastClickedID = newPath
            requestScrollToVisible(newPath)
            statusMessage = "Renamed: \(trimmed)"
        } catch {
            guard generation == sessionGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func requestDeleteSelected() {
        guard connectingConnectionID == nil else { return }
        if showingTrash {
            requestDeleteTrashSelection()
            return
        }
        guard !selectedIDs.isEmpty else { return }
        pendingDeleteIDs = selectedIDs
        presentDeleteConfirmationIfNeeded()
    }

    func requestDelete(entry: FileEntry) {
        if showingTrash { return }
        if selectedIDs.contains(entry.id), selectedIDs.count > 1 {
            pendingDeleteIDs = selectedIDs
        } else {
            pendingDeleteIDs = [entry.id]
        }
        presentDeleteConfirmationIfNeeded()
    }

    private func presentDeleteConfirmationIfNeeded() {
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
            title = "Move \u{201C}\(names[0])\u{201D} to Trash?"
        } else {
            title = "Move \(pendingDeleteIDs.count) selected items to Trash?"
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The items are moved to Trash on the network volume and kept for \(TrashStore.retentionDays) days. You can restore them from Trash. Local copies are removed from this Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

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
        guard trashRequestID == nil else { return }
        let ids = pendingDeleteIDs
        pendingDeleteIDs = []
        guard !ids.isEmpty else { return }
        guard let connectionID = activeConnection?.id else { return }
        let requestID = UUID()
        trashRequestID = requestID
        var generation = sessionGeneration

        isBusy = true
        errorMessage = nil
        defer {
            if trashRequestID == requestID { trashRequestID = nil }
            if generation == sessionGeneration {
                isBusy = false
                AppWindowFocus.reclaim()
            }
        }

        let resumeInitialMerge = isMergingInitialFiles
        if resumeInitialMerge {
            sessionGeneration += 1
            generation = sessionGeneration
            statusMessage = "Stopping the background upload before deleting…"
            await stopInitialMerge()
        }
        if importProgress != nil { cancelBackgroundImport() }
        guard generation == sessionGeneration, let connection = activeConnection,
              connection.id == connectionID else { return }
        let previewRoots = ids.compactMap(TrashStore.safeRelativePath).flatMap { path in
            [URL(fileURLWithPath: connection.remotePath).appendingPathComponent(path),
             URL(fileURLWithPath: connection.localPath).appendingPathComponent(path)]
        }
        let previewToken = suspendPreviews(in: previewRoots)
        defer { ThumbnailRequests.shared.resume(previewToken) }
        await Task.yield()
        guard generation == sessionGeneration else { return }
        statusMessage = "Moving selected items to Trash…"
        let engine = self.engine
        var failure: Error?
        do {
            try await engine.trashItems(relativePaths: Array(ids))
        } catch {
            failure = error
        }
        let resultingPins = await engine.getPinnedPaths()
        if store.connections.contains(where: { $0.id == connectionID }) { store.setPinnedPaths(resultingPins, for: connectionID) }
        guard generation == sessionGeneration, activeConnection?.id == connectionID else { return }

        // A watcher-driven transfer has no awaiting AppModel.fullSync() caller
        // to clear its progress after deletion cancels it.
        syncProgress = nil
        uploadBytesPerSecond = 0
        downloadBytesPerSecond = 0
        refreshMenuBarIcon()
        pinnedPaths = resultingPins
        guard generation == sessionGeneration, activeConnection?.id == connectionID else { return }
        if let id = activeConnection?.id {
            store.setPinnedPaths(pinnedPaths, for: id)
        }
        selectedIDs = failure == nil ? [] : ids
        if failure == nil {
            removeDeletedEntries(ids)
        } else {
            try? await reloadAfterMutation()
            guard generation == sessionGeneration else { return }
        }
        // Updating badges on other (possibly offline) disks is not part of the
        // foreground move. Do it after the visible deletion is complete.
        Task { [weak self] in await self?.refreshTrash(purgingExpired: false) }

        if let failure {
            errorMessage = failure.localizedDescription
            statusMessage = "Could not move some items to Trash"
        } else {
            statusMessage = ids.count == 1
                ? "Moved to Trash"
                : "Moved \(ids.count) items to Trash"
            if resumeInitialMerge, let connection = activeConnection {
                do {
                    try await engine.prepareInitialMerge(connectionID: connection.id)
                    startInitialMerge(connection, generation: sessionGeneration)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func removeDeletedEntries(_ paths: Set<String>) {
        func removed(_ path: String) -> Bool {
            paths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        if var current = listing {
            current.entries.removeAll { removed($0.relativePath) }
            listing = current
        }
        if let connection = activeConnection,
           var snapshot = volumeRootSnapshots[VolumeSnapshotKey(connection)] {
            snapshot.entries.removeAll { removed($0.relativePath) }
            rememberRootSnapshot(snapshot, for: connection)
        }
        columns = columns.filter { !removed($0.path) }.map { column in
            var updated = column
            updated.entries.removeAll { removed($0.relativePath) }
            if let revealed = updated.revealedChildID, removed(revealed) { updated.revealedChildID = nil }
            return updated
        }
        columnListingCache = columnListingCache.filter { !removed($0.key) }.mapValues {
            $0.filter { !removed($0.relativePath) }
        }
        expandedFolderPaths = expandedFolderPaths.filter { !removed($0) }
        expandingFolderPaths = expandingFolderPaths.filter { !removed($0) }
        if viewMode == .columns, let last = columns.last {
            currentPath = last.path
            listing = DirectoryListing(relativePath: last.path, entries: last.entries, breadcrumbs: breadcrumbs(for: last.path))
        }
        updateVisibleWatcherPaths()
    }

    // MARK: - Trash

    var trashCount: Int { trashItems.count }

    /// Opens the Trash for all configured volumes.
    func openTrash() async {
        showingTrash = true
        await loadTrash()
    }

    func closeTrash() {
        guard showingTrash else { return }
        showingTrash = false
        trashSelection = []
    }

    func loadTrash() async {
        trashErrorMessage = nil
        isLoadingTrash = true
        defer { isLoadingTrash = false }
        await refreshTrash(purgingExpired: true)
        statusMessage = trashItems.isEmpty ? "Trash is empty" : "Trash: \(trashItems.count) items"
    }

    /// Reads the trash index so the sidebar badge is accurate, purging expired items.
    private func refreshTrash(purgingExpired: Bool) async {
        trashRefreshGeneration += 1
        let generation = trashRefreshGeneration
        let configured = connections
        let groups = await Task.detached(priority: .utility) {
          await withTaskGroup(of: TrashGroup.self, returning: [TrashGroup].self) { tasks in
            for connection in configured {
                tasks.addTask {
                    let root = connection.remotePath
                    guard (try? FileManager.default.attributesOfItem(atPath: root)) != nil else {
                        return TrashGroup(connection: connection, items: [], isAvailable: false)
                    }
                    if purgingExpired { TrashStore.purgeExpired(remoteRoot: root) }
                    let items = TrashStore.loadItems(remoteRoot: root).map {
                        TrashEntry(connection: connection, item: $0)
                    }
                    return TrashGroup(connection: connection, items: items, isAvailable: true)
                }
            }
            var result: [TrashGroup] = []
            for await group in tasks { result.append(group) }
            return result
          }
        }.value
        guard generation == trashRefreshGeneration else { return }
        trashGroups = configured.compactMap { connection in
            groups.first { $0.id == connection.id }
        }
        trashSelection.formIntersection(Set(trashItems.map(\.id)))
    }

    private func startTrashMaintenance() {
        // Switching volumes must not start another all-volume Trash scan.
        guard trashMaintenanceTimer == nil else { return }
        trashMaintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard let self else { return }
                guard !self.isBusy, !self.isLoadingDirectory, self.connectingConnectionID == nil else { continue }
                await self.refreshTrash(purgingExpired: true)
                return
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshTrash(purgingExpired: true)
            }
        }
        trashMaintenanceTimer = timer
    }

    private func stopTrashMaintenance() {
        trashMaintenanceTask?.cancel()
        trashMaintenanceTask = nil
        trashMaintenanceTimer?.invalidate()
        trashMaintenanceTimer = nil
    }

    func trashURL(for entry: TrashEntry) -> URL {
        URL(fileURLWithPath: TrashStore.payloadPath(remoteRoot: entry.connection.remotePath, item: entry.item))
    }

    private func suspendPreviews(in roots: [URL]) -> UUID {
        let token = ThumbnailRequests.shared.suspend(in: roots)
        QuickLookController.shared.close(ifInside: roots)
        return token
    }

    private func suspendTrashPreviews(ids: Set<String>? = nil) -> UUID {
        let roots: [URL]
        if let ids {
            roots = trashGroups.flatMap(\.items).filter { ids.contains($0.id) }.map {
                URL(fileURLWithPath: TrashStore.payloadDirectory(remoteRoot: $0.connection.remotePath, id: $0.item.id))
            }
        } else {
            roots = trashGroups.map { URL(fileURLWithPath: TrashStore.trashRoot(remoteRoot: $0.connection.remotePath)) }
        }
        return suspendPreviews(in: roots)
    }

    var selectedTrashItems: [TrashEntry] {
        trashItems.filter { trashSelection.contains($0.id) }
    }

    /// Children trashed just before their folder belong to the same deletion.
    /// Keep them recoverable even though only the folder appears in the list.
    private func expandedTrashIDs(_ ids: Set<String>) -> Set<String> {
        var expanded = ids
        for group in trashGroups {
            var changed = true
            while changed {
                changed = false
                for folder in group.items where expanded.contains(folder.id) && folder.item.isDirectory {
                    for child in group.items where !expanded.contains(child.id) {
                        if child.item.originalPath.hasPrefix(folder.item.originalPath + "/"),
                           child.item.deletedAt <= folder.item.deletedAt,
                           folder.item.deletedAt.timeIntervalSince(child.item.deletedAt) <= 30 {
                            expanded.insert(child.id)
                            changed = true
                        }
                    }
                }
            }
        }
        return expanded
    }

    func restoreTrashSelection() {
        let ids = trashSelection
        guard !ids.isEmpty else { return }
        Task { await restoreTrashItems(ids: ids) }
    }

    func restoreTrashItems(ids: Set<String>) async {
        guard !ids.isEmpty, !isTrashBusy else { return }
        let ids = expandedTrashIDs(ids)
        isTrashBusy = true
        trashErrorMessage = nil
        let previewToken = suspendTrashPreviews(ids: ids)
        defer { isTrashBusy = false; ThumbnailRequests.shared.resume(previewToken) }
        await Task.yield()

        do {
            var restored: [TrashStore.RestoreResult] = []
            for group in trashGroups {
                let itemIDs = group.items.filter { ids.contains($0.id) }.map { $0.item.id }
                guard !itemIDs.isEmpty else { continue }
                let results: [TrashStore.RestoreResult]
                let restoringEngine: SyncEngine
                if group.id == activeConnection?.id {
                    restoringEngine = engine
                } else {
                    restoringEngine = try await syncCoordinator.connect(group.connection, pins: store.pinnedPaths(for: group.id),
                                                                         deferInitialMerge: store.pendingInitialMergeIDs.contains(group.id))
                }
                results = try await restoringEngine.restoreTrashItems(ids: itemIDs)
                let restoredPins = await restoringEngine.getPinnedPaths()
                store.setPinnedPaths(restoredPins, for: group.id)
                if group.id == activeConnection?.id { pinnedPaths = restoredPins }
                restored += results
            }
            trashSelection = []
            await loadTrash()
            if activeConnection != nil { try? await reloadAfterMutation() }

            switch restored.count {
            case 0:
                statusMessage = String(localized: "Nothing to restore")
            case 1:
                statusMessage = "Restored \u{201C}\(restored[0].item.name)\u{201D}"
            default:
                statusMessage = "Restored \(restored.count) items"
            }
            if restored.contains(where: { $0.item.wasPinned }) {
                startBackgroundSyncIfNeeded()
            }
        } catch {
            errorMessage = error.localizedDescription
            trashErrorMessage = error.localizedDescription
            statusMessage = "Could not restore from Trash"
            await refreshTrash(purgingExpired: false)
        }
    }

    /// Delete key / Delete command while the Trash is open.
    func requestDeleteTrashSelection() {
        let ids = trashSelection
        guard !ids.isEmpty, !isTrashBusy else { return }

        let names = selectedTrashItems.map { $0.item.name }
        let alert = NSAlert()
        alert.messageText = ids.count == 1
            ? "Permanently delete \u{201C}\(names.first ?? "this item")\u{201D}?"
            : "Permanently delete \(ids.count) items?"
        alert.informativeText = "This removes them from Trash immediately. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Immediately")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        DispatchQueue.main.async {
            AppWindowFocus.reclaim()
        }
        guard response == .alertFirstButtonReturn else { return }

        Task {
            await deleteTrashItems(ids: ids)
            await Task.yield()
            AppWindowFocus.reclaim()
        }
    }

    func deleteTrashItems(ids: Set<String>) async {
        guard !ids.isEmpty, !isTrashBusy else { return }
        let ids = expandedTrashIDs(ids)
        isTrashBusy = true
        trashErrorMessage = nil
        statusMessage = "Deleting selected items from Trash…"
        let previewToken = suspendTrashPreviews(ids: ids)
        defer { isTrashBusy = false; ThumbnailRequests.shared.resume(previewToken) }
        await Task.yield()

        var failures: [String] = []
        var handledIDs = Set<String>()
        for group in trashGroups {
            let prefix = group.id + "|"
            let entryIDs = ids.filter { $0.hasPrefix(prefix) }
            guard !entryIDs.isEmpty else { continue }
            handledIDs.formUnion(entryIDs)
            let itemIDs = Set(entryIDs.map { String($0.dropFirst(prefix.count)) })
            let root = group.connection.remotePath
            do {
                try await Task.detached(priority: .userInitiated) {
                    try TrashStore.deletePermanently(ids: itemIDs, remoteRoot: root)
                }.value
            } catch {
                failures.append("\(group.connection.name): \(error.localizedDescription)")
            }
        }
        if !ids.isSubset(of: handledIDs) {
            failures.append("Some selected items no longer have an available connection. Refresh Trash and try again.")
        }
        // Refresh prunes successfully removed IDs and keeps failed items selected.
        await refreshTrash(purgingExpired: false)
        if failures.isEmpty {
            statusMessage = ids.count == 1 ? "Deleted from Trash" : "Deleted \(ids.count) items"
        } else {
            trashErrorMessage = failures.joined(separator: "\n\n")
            statusMessage = "Could not delete from Trash"
        }
    }

    func requestEmptyTrash() {
        guard !trashItems.isEmpty, !isTrashBusy else { return }

        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "Permanently delete \(trashItems.count) item\(trashItems.count == 1 ? "" : "s") from all available network volumes. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        DispatchQueue.main.async {
            AppWindowFocus.reclaim()
        }
        guard response == .alertFirstButtonReturn else { return }

        Task {
            await emptyTrash()
            await Task.yield()
            AppWindowFocus.reclaim()
        }
    }

    func emptyTrash() async {
        guard !trashItems.isEmpty, !isTrashBusy else { return }
        isTrashBusy = true
        trashErrorMessage = nil
        statusMessage = "Emptying Trash…"
        let previewToken = suspendTrashPreviews()
        defer { isTrashBusy = false; ThumbnailRequests.shared.resume(previewToken) }
        await Task.yield()

        var failures: [String] = []
        for group in trashGroups {
            let root = group.connection.remotePath
            do {
                try await Task.detached(priority: .userInitiated) {
                    try TrashStore.empty(remoteRoot: root)
                }.value
            } catch {
                failures.append("\(group.connection.name): \(error.localizedDescription)")
            }
        }
        await refreshTrash(purgingExpired: false)
        if failures.isEmpty {
            statusMessage = "Trash emptied"
        } else {
            trashErrorMessage = failures.joined(separator: "\n\n")
            statusMessage = "Could not empty Trash"
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
        let generation = sessionGeneration
        let engine = self.engine
        let connectionID = activeConnection?.id
        defer { if generation == sessionGeneration { isBusy = false } }
        do {
            try await engine.moveItems(relativePaths: filtered, toDirectory: destination)
            if let connectionID {
                for source in filtered.sorted(by: { $0.count > $1.count }) {
                    let name = (source as NSString).lastPathComponent
                    let target = destination.isEmpty ? name : "\(destination)/\(name)"
                    remapFavorites(connectionID: connectionID, from: source, to: target)
                }
            }
            let paths = await engine.getPinnedPaths()
            if let id = connectionID, store.connections.contains(where: { $0.id == id }) {
                store.setPinnedPaths(paths, for: id)
            }
            guard generation == sessionGeneration else { return }
            pinnedPaths = paths
            selectedIDs = []
            try await reloadAfterMutation()
            statusMessage = "Moved"
        } catch {
            guard generation == sessionGeneration else { return }
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
        guard let id = activeConnection?.id else { return }
        pendingImports.append(PendingImport(urls: urls, destination: destination, engine: engine, connectionID: id))
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
            await self?.runImport(urls: next.urls, destination: next.destination,
                                  engine: next.engine, connectionID: next.connectionID)
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
        refreshMenuBarIcon()
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

    private func runImport(urls: [URL], destination: String, engine: SyncEngine, connectionID: String) async {
        guard store.connections.contains(where: { $0.id == connectionID }) else { return }
        beginImportActivity()
        if activeConnection?.id == connectionID {
            importProgress = ImportProgress(
                done: 0,
                total: max(urls.count, 1),
                currentName: urls.first?.lastPathComponent ?? "…",
                destination: destination,
                currentPath: destination,
                queuedBatches: pendingImports.count
            )
        }
        refreshMenuBarIcon()
        if activeConnection?.id == connectionID {
            statusMessage = urls.count == 1
                ? "Uploading \u{201c}\(urls[0].lastPathComponent)\u{201d} in background…"
                : "Uploading \(urls.count) items in background…"
        }

        defer {
            endImportActivity()
            // Keep banner only if another batch will start immediately.
            if pendingImports.isEmpty {
                importProgress = nil
                refreshMenuBarIcon()
            }
        }

        do {
            try await engine.importItems(from: urls, toDirectory: destination) { [weak self] done, total, name in
                Task { @MainActor in
                    guard let self, self.activeConnection?.id == connectionID else { return }
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
            let paths = await engine.getPinnedPaths()
            if store.connections.contains(where: { $0.id == connectionID }) { store.setPinnedPaths(paths, for: connectionID) }
            try Task.checkCancellation()
            guard activeConnection?.id == connectionID else { return }

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
            if activeConnection?.id == connectionID { statusMessage = "Upload canceled" }
        } catch {
            guard activeConnection?.id == connectionID else { return }
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

    // MARK: - Sync pause

    var isSyncing: Bool {
        syncProgress != nil || importProgress != nil || connectionSyncStates.values.contains(where: \.isSyncing)
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
        Task { await syncCoordinator.setPaused(true) }
        refreshMenuBarIcon()
        pauseTimer?.invalidate()
        let delay = hours * 3600
        pauseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resumeSync()
            }
        }
        statusMessage = syncPauseDescription ?? "Paused"
    }

    func resumeSync() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        syncPausedUntil = nil
        refreshMenuBarIcon()
        statusMessage = "Ready"
        Task {
            await syncCoordinator.setPaused(false)
            synchronizeConfiguredConnections()
        }
    }

    private func refreshMenuBarIcon() {
        let hasConnectedVolume = connectionSyncStates.values.contains(where: \.isConnected) ||
            (activeConnection != nil && !isRemoteUnavailable)
        let inactive = isSyncPaused || !hasConnectedVolume
        let syncing = isSyncing && !inactive
        let newName = syncing ? "sync" : (inactive ? "default-inactive" : "default")
        if menuBarIconName != newName { menuBarIconName = newName }
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
