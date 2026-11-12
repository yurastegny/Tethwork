import Foundation
import Darwin

/// Bidirectional selective sync between a network (or any remote) folder
/// and a local folder. Only pinned paths are kept locally.
actor SyncEngine {
    /// Rolling byte throughput, shared by normal copies and initial adoption.
    struct TransferRateMeter {
        private var startedAt: ContinuousClock.Instant
        private var bytes: Int64 = 0

        init(startedAt: ContinuousClock.Instant = .now) { self.startedAt = startedAt }

        mutating func record(bytes count: Int, at now: ContinuousClock.Instant = .now) -> Double? {
            bytes += Int64(count)
            guard startedAt.duration(to: now) >= .milliseconds(200) else { return nil }
            return flush(at: now)
        }

        mutating func flush(at now: ContinuousClock.Instant = .now) -> Double? {
            guard bytes > 0 else { return nil }
            let rate = SyncEngine.bytesPerSecond(byteCount: bytes, elapsed: startedAt.duration(to: now))
            bytes = 0
            startedAt = now
            return rate
        }
    }

    private struct PersistedSyncState: Codable {
        var remotePath: String
        var syncedPaths: [String]
    }

    private(set) var connection: SyncConnection?
    private var pinnedPaths: Set<String> = [] {
        didSet { cachedPinnedDirectories = nil }
    }
    private var cachedPinnedDirectories: Set<String>?
    /// Shared immutable snapshot for shallow listings. Rebuilding this for every
    /// folder turns a large individually pinned library into quadratic CPU work.
    private var pinnedDirectories: Set<String> {
        if let cachedPinnedDirectories { return cachedPinnedDirectories }
        let directories = Set(Self.watchDirectoryPaths(pins: pinnedPaths, knownPaths: pinnedPaths))
        cachedPinnedDirectories = directories
        return directories
    }
    /// Paths known to have existed on both sides after the last successful sync.
    /// This is the baseline that lets us distinguish a deletion from a new file.
    private var knownSyncedPaths: Set<String> = []
    private struct VerificationCache: Codable {
        var version = 1
        var remotePath: String
        var localPath: String
        var pairs: [String: VerifiedPair]
    }

    private struct VerifiedPair: Codable, Equatable, Sendable {
        var remoteSize: Int64
        var localSize: Int64
        var remoteModified: Date
        var localModified: Date
        var remoteFileID: UInt64?
        var localFileID: UInt64?

        init(remote: [FileAttributeKey: Any], local: [FileAttributeKey: Any]) {
            remoteSize = (remote[.size] as? NSNumber)?.int64Value ?? -1
            localSize = (local[.size] as? NSNumber)?.int64Value ?? -1
            remoteModified = (remote[.modificationDate] as? Date) ?? .distantPast
            localModified = (local[.modificationDate] as? Date) ?? .distantPast
            remoteFileID = (remote[.systemFileNumber] as? NSNumber)?.uint64Value
            localFileID = (local[.systemFileNumber] as? NSNumber)?.uint64Value
        }

        func matches(remote: [FileAttributeKey: Any], local: [FileAttributeKey: Any]) -> Bool {
            self == VerifiedPair(remote: remote, local: local)
        }

        func matches(remoteSize: Int64, localSize: Int64, remoteModified: Date, localModified: Date) -> Bool {
            self.remoteSize == remoteSize && self.localSize == localSize &&
                abs(self.remoteModified.timeIntervalSince(remoteModified)) < 0.000001 &&
                abs(self.localModified.timeIntervalSince(localModified)) < 0.000001
        }
    }
    /// Verified contents, separate from the path-existence deletion baseline.
    /// Size/mtime/file-ID changes invalidate cache hits during reconciliation.
    private var verifiedPairs: [String: VerifiedPair] = [:]
    private var verificationCacheDirty = false
    private var lastVerificationCheckpoint = ContinuousClock.now
    private var initialMergePending = false
    private var connectionEpoch: UInt64 = 0
    private var syncRevision: UInt64 = 0
    /// Automatic synchronization backs off after failures instead of stopping
    /// forever. A manual Sync clears the backoff immediately.
    private var consecutiveSyncFailures = 0
    private var retryNotBefore: Date = .distantPast
    private var retryTask: Task<Void, Never>?
    /// A watcher fired while a sync was running. Re-run afterwards so the change
    /// is not lost (the old code dropped these events entirely).
    private var pendingResync = false
    private var resyncTask: Task<Void, Never>?
    private var copyTasks: [UUID: Task<Void, Error>] = [:]
    private struct DirectoryRead {
        var listing: DirectoryListing
        var allEntries: [FileEntry]
        var hasLocalDirectory: Bool
        var isSelected: Bool
    }
    private struct StorageChild {
        var path: String
        var local: Bool
        var selected: Bool
        var pending: Bool
    }
    private struct StorageScan {
        var local: Bool
        var selected: Bool
        var allFilesLocal = true
        var anyLocalFile = false
        var pendingFile = false
        var children: [StorageChild] = []
    }
    private var listingTasks: [UUID: Task<DirectoryRead, Error>] = [:]
    private var folderStates: [String: FolderStorageState] = [:]
    private struct FolderDisplayKey: Hashable {
        var remote: String
        var local: String
    }
    private struct FolderDisplaySnapshot {
        var pins: Set<String>
        var states: [String: FolderStorageState] = [:]
    }
    /// Last-known badges only. Never used to skip inventory scans or reconcile files.
    private var folderDisplaySnapshots: [FolderDisplayKey: FolderDisplaySnapshot] = [:]

    private var folderDisplayKey: FolderDisplayKey? {
        connection.map { FolderDisplayKey(remote: $0.remotePath, local: $0.localPath) }
    }

    private var lastKnownFolderStates: [String: FolderStorageState] {
        guard let key = folderDisplayKey, let snapshot = folderDisplaySnapshots[key],
              snapshot.pins == pinnedPaths else { return [:] }
        return snapshot.states
    }

    private var displayedFolderStates: [String: FolderStorageState] {
        var states = lastKnownFolderStates
        for (path, state) in folderStates where state != .checking || states[path] == nil {
            states[path] = state
        }
        return states
    }

    private func rememberFolderState(_ state: FolderStorageState, path: String) {
        guard state != .checking, state != .unavailable, let key = folderDisplayKey else { return }
        if folderDisplaySnapshots[key]?.pins != pinnedPaths {
            folderDisplaySnapshots[key] = FolderDisplaySnapshot(pins: pinnedPaths)
        }
        folderDisplaySnapshots[key]?.states[path] = state
    }
    private var storageScans: [String: StorageScan] = [:]
    private var storageQueue: [String] = []
    private var storageQueueIndex = 0
    private var storageQueued = Set<String>()
    private var storageWorker: Task<Void, Never>?
    private var storageRead: Task<DirectoryRead, Error>?
    private var storageRetries: [String: Task<Void, Never>] = [:]
    private var storageGeneration: UInt64 = 0
    private var remoteWatcher: DirectoryWatcher?
    private var localWatcher: DirectoryWatcher?
    private var watchedRemotePaths = Set<String>()
    private var syncing = false
    private var paused = false
    private var automaticSyncPaused = false
    private var remoteWasUnavailable = false
    private var lastUploadRate: Double?
    private var lastDownloadRate: Double?
    private var publishedUploadRate = false
    private var publishedDownloadRate = false
    private var suppressUntil: Date = .distantPast
    private var eventHandler: (@Sendable (SyncEvent) -> Void)?
    private var syncProgressDone = 0
    private var syncProgressTotal = 0
    /// Files actually copied this sync (mismatches only).
    private var syncTransferDone = 0
    private var syncTransferTotal = 0
    private var transferTotalKnown = true
    private var lastProgressEmission: ContinuousClock.Instant?
    private var progressPhases: Set<SyncPhase> = []
    /// >0 while UI is listing/navigating — background sync waits so SMB stays responsive.
    private var uiHoldCount = 0

    private let fm = FileManager.default
    /// Deterministic sync tests can drive reconciliation without filesystem callbacks.
    private let watchesDirectories: Bool
    private let homeDirectory: URL
    private let inventoryDirectory: URL?
    private var localInventory: LocalFileInventory?
    /// Pause between file copies so Finder-style browsing can use the share.
    private let syncTransferGapNs: UInt64 = 150_000_000
    private let syncMetadataGapNs: UInt64 = 25_000_000

    init(watchesDirectories: Bool = true, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         inventoryDirectory: URL? = nil) {
        self.watchesDirectories = watchesDirectories
        self.homeDirectory = homeDirectory
        self.inventoryDirectory = inventoryDirectory ?? (watchesDirectories ? LocalFileInventory.defaultDirectory : nil)
    }

    func setEventHandler(_ handler: @escaping @Sendable (SyncEvent) -> Void) {
        eventHandler = handler
    }

    func getPinnedPaths() -> [String] {
        pinnedPaths.sorted()
    }

    func shouldKeepLocal(_ relativePath: String) -> Bool {
        Self.shouldKeepLocal(relativePath, pins: pinnedPaths)
    }

    func syncMode(for relativePath: String) -> SyncMode {
        shouldKeepLocal(relativePath) ? .offline : .onlineOnly
    }

    func connect(connection: SyncConnection, pinned: [String], initiallySyncedPaths: [String]? = nil,
                 deferInitialMerge: Bool = false, deferWatchers: Bool = false) async throws {
        connectionEpoch &+= 1
        let epoch = connectionEpoch
        await disconnectCurrentConnection(epoch: epoch)
        guard epoch == connectionEpoch else { throw CancellationError() }

        if let directory = inventoryDirectory {
            let prepared = await Task.detached(priority: .utility) { () -> LocalFileInventory? in
                let inventory = LocalFileInventory(directory: directory, connection: connection)
                do {
                    try inventory.beginSession(selectedPaths: pinned)
                    try inventory.auditBeforeSync()
                    return inventory
                } catch {
                    NSLog("Tethwork local inventory unavailable: %@", error.localizedDescription)
                    return nil
                }
            }.value
            guard epoch == connectionEpoch else { throw CancellationError() }
            localInventory = prepared
        }
        let homeDirectory = self.homeDirectory
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.validateConnectionSafety(connection, homeDirectory: homeDirectory)
                guard Self.rootsAreDisjoint(connection.remotePath, connection.localPath) else {
                    throw SyncError.overlappingRoots
                }
                try Self.validateRemoteRoot(connection.remotePath)
                try FileManager.default.createDirectory(atPath: connection.localPath, withIntermediateDirectories: true)
            }.value
        } catch {
            guard epoch == connectionEpoch else { throw CancellationError() }
            inventoryNote("connection_rejected", message: error.localizedDescription)
            throw error
        }
        guard epoch == connectionEpoch else { throw CancellationError() }
        self.connection = connection
        self.initialMergePending = deferInitialMerge
        self.pinnedPaths = Set(Self.compactPinnedPaths(pinned))

        knownSyncedPaths = initiallySyncedPaths.map(Set.init) ?? loadPersistedSyncState(for: connection)
        loadVerificationCache(for: connection)
        if initiallySyncedPaths != nil {
            persistSyncState()
        }

        // Sync pinned content in the background after connect so the UI stays usable.
        if watchesDirectories && !initialMergePending && !deferWatchers {
            startWatchers()
            cleanupStaleTemporaryFiles()
        }
        emit(.init(kind: .status, message: String(localized: "Connected")))
    }

    func disconnect() async {
        connectionEpoch &+= 1
        await disconnectCurrentConnection(epoch: connectionEpoch)
    }

    private func disconnectCurrentConnection(epoch: UInt64) async {
        invalidateFolderStorage(rescan: false)
        for task in listingTasks.values { task.cancel() }
        await stopTransfers()
        guard epoch == connectionEpoch else { return }
        stopWatchers()
        retryTask?.cancel()
        retryTask = nil
        resyncTask?.cancel()
        resyncTask = nil
        pendingResync = false
        consecutiveSyncFailures = 0
        retryNotBefore = .distantPast
        persistSyncState()
        inventoryCheckpoint(force: true)
        localInventory = nil
        connection = nil
        remoteWasUnavailable = false
        initialMergePending = false
        pinnedPaths.removeAll()
        knownSyncedPaths.removeAll()
        verifiedPairs.removeAll()
        verificationCacheDirty = false
        syncing = false
        paused = false
        uiHoldCount = 0
        emit(.init(kind: .status, message: String(localized: "Disconnected")))
    }

    /// Give the initial visible listing first use of the share, before pollers
    /// start collecting signatures for all pinned folders.
    func activateWatchers(connectionID: String) {
        guard connection?.id == connectionID, watchesDirectories, !initialMergePending,
              remoteWatcher == nil else { return }
        startWatchers()
        cleanupStaleTemporaryFiles()
    }

    @discardableResult
    func setPinned(relativePath: String, pinned: Bool) async throws -> [String] {
        let connection = try writableConnection()
        try validateUserPath(relativePath, connection: connection)
        await stopTransfers()
        guard self.connection?.id == connection.id else { throw CancellationError() }
        let epoch = connectionEpoch
        let revision = syncRevision
        syncing = true
        paused = true
        defer {
            if revision == syncRevision {
                syncing = false
                paused = false
                transferTotalKnown = true
            }
            schedulePendingResync()
        }
        let normalized = Self.normalize(relativePath)

        do {
            if pinned {
                pinnedPaths.insert(normalized)
                pinnedPaths = Set(Self.compactPinnedPaths(Array(pinnedPaths)))
                emit(.init(kind: .progress, message: "Preparing download: \(normalized.isEmpty ? "/" : normalized)",
                           path: normalized, progressDone: 0, isTransfer: true,
                           transferDirection: .download, phase: .preparing))
                try await downloadTreeWithProgress(normalized)
            } else {
                if normalized.isEmpty {
                    pinnedPaths.removeAll()
                } else {
                    pinnedPaths.remove(normalized)
                    pinnedPaths = pinnedPaths.filter { !$0.hasPrefix(normalized + "/") }
                }
                removeKnownPath(normalized)
                // Removing a local copy is not a Finder deletion. Persist the updated
                // baseline before eviction, without rescanning unrelated remote trees.
                persistSyncState()
                inventoryNote("local_removal_requested", message: "Keep Online Only", paths: [normalized])
                emit(.init(kind: .status, message: "Freeing local space: \(normalized.isEmpty ? "/" : normalized)", path: normalized))
                try await removeLocalTree(normalized)
                guard epoch == connectionEpoch, revision == syncRevision else { throw CancellationError() }
                inventoryRetire(normalized, reason: "Explicit Keep Online Only completed", remainingSelections: Array(pinnedPaths))
                inventoryCheckpoint(force: true, successfulOperation: "Keep Online Only")
            }

            guard epoch == connectionEpoch, revision == syncRevision else { throw CancellationError() }
            if pinned {
                emit(.init(kind: .progress, message: String(localized: "Finishing download…"), path: normalized,
                           progressDone: syncTransferDone, isTransfer: true,
                           transferDirection: .download, phase: .finishing))
                // materialize records matching/copied paths as it goes. Do not make
                // the user wait for another scan of every pinned tree on the NAS.
                persistSyncState()
            }
            updateRemoteWatchPaths()
            let paths = getPinnedPaths()
            if pinned {
                resetSyncBackoff()
                emit(.init(kind: .complete, message: String(localized: "Download complete"), isTransfer: false))
            }
            return paths
        } catch {
            guard epoch == connectionEpoch, revision == syncRevision, !(error is CancellationError) else {
                throw CancellationError()
            }
            let reported: Error = error is SyncError ? error : Self.transferFailure(error,
                from: join(connection.remotePath, normalized), to: join(connection.localPath, normalized),
                operation: pinned ? "Keep a local copy" : "Evict a local copy")
            registerSyncFailure(reported)
            persistSyncState()
            emit(.init(kind: .error, message: reported.localizedDescription,
                       isRemoteUnavailable: Self.isRemoteUnavailableError(error)))
            throw reported
        }
    }

    /// Reconciles every pinned tree. Returns `true` when this call actually ran
    /// (the caller uses that to avoid clearing another operation's progress).
    @discardableResult
    func fullSync(recheckContents: Bool = false) async -> Bool {
        guard let connection, !syncing, !initialMergePending else { return false }
        if recheckContents {
            verifiedPairs.removeAll()
            verificationCacheDirty = true
            persistVerificationCache()
        }
        invalidateFolderStorage()
        let epoch = connectionEpoch
        let revision = syncRevision
        resetSyncBackoff()
        var syncOperation = "Validate synchronization roots"
        var syncPath = ""
        pendingResync = false
        syncing = true
        paused = true
        suppress(for: 2)

        defer {
            if epoch == connectionEpoch { persistVerificationCache() }
            if revision == syncRevision {
                syncing = false
                paused = false
                syncProgressDone = 0
                syncProgressTotal = 0
                syncTransferDone = 0
                syncTransferTotal = 0
            }
            schedulePendingResync()
        }

        do {
            let pins = pinnedPaths.sorted()
            await auditLocalInventory()
            guard epoch == connectionEpoch, revision == syncRevision else { return false }
            try Self.validateConnectionSafety(connection, homeDirectory: homeDirectory)
            try Self.validateRemoteRoot(connection.remotePath)
            try reportRemoteRecovery(connection)

            // Do not walk the entire NAS tree once just to guess a total: with
            // tens of thousands of files that delay can last minutes. Report
            // indeterminate progress and start reconciling immediately.
            syncTransferTotal = 0
            syncTransferDone = 0
            syncProgressDone = 0
            syncProgressTotal = 0
            transferTotalKnown = false
            lastProgressEmission = nil
            progressPhases.removeAll()
            emit(.init(kind: .progress, message: String(localized: "Checking files to synchronize…"),
                       path: pins.count == 1 ? pins.first : nil,
                       progressDone: 0, isTransfer: true, phase: .preparing))

            for pin in pins {
                guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return false }
                syncOperation = "Reconcile synchronized path"
                syncPath = pin
                try await syncTree(pin)
            }
            guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return false }
            // A settings reload or missing pin is never consent to delete data.
            // Eviction is only performed by the explicit Keep Online Only action.
            syncOperation = "Refresh synchronization baseline"
            emit(.init(kind: .progress, message: String(localized: "Finishing synchronization…"),
                       path: nil, progressDone: syncTransferDone,
                       progressTotal: transferTotalKnown ? syncTransferTotal : nil,
                       isTransfer: true, phase: .finishing))
            try await refreshPersistedSyncState()
            updateRemoteWatchPaths()
            resetSyncBackoff()
            emit(.init(
                kind: .complete,
                message: String(localized: "Sync complete"),
                progressDone: syncTransferDone,
                progressTotal: syncTransferTotal,
                isTransfer: true
            ))
            return true
        } catch {
            guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending,
                  !(error is CancellationError) else { return false }
            let diagnostic = Self.transferFailure(error, from: join(connection.remotePath, syncPath),
                                                   to: join(connection.localPath, syncPath), operation: syncOperation)
            registerSyncFailure(diagnostic)
            emit(.init(
                kind: .error,
                message: diagnostic.localizedDescription,
                isRemoteUnavailable: Self.isRemoteUnavailableError(error)
            ))
            return false
        }
    }

    /// Moves items from the network drive into the server-side trash and removes
    /// local copies; updates pins. Trashed items can be restored for 15 days.
    func trashItems(relativePaths: [String]) async throws {
        let connection = try writableConnection()
        let epoch = connectionEpoch
        await stopTransfers()
        guard epoch == connectionEpoch else { throw CancellationError() }
        let revision = syncRevision
        suppress(for: 1.5)
        paused = true
        defer {
            if epoch == connectionEpoch, revision == syncRevision {
                paused = false
                schedulePendingResync()
            }
        }

        var failures: [String] = []

        let pins = pinnedPaths
        let remoteRoot = connection.remotePath
        inventoryNote("trash_requested", message: "Explicit Move to Trash", paths: relativePaths)
        // TrashStore performs directory walks and SMB moves. Keep them off the
        // actor so directory listing and navigation do not freeze.
        let outcome = await Task.detached(priority: .userInitiated) {
            TrashStore.moveToTrash(
                relativePaths: relativePaths,
                remoteRoot: remoteRoot,
                wasPinned: { Self.shouldKeepLocal($0, pins: pins) }
            )
        }.value
        guard epoch == connectionEpoch, revision == syncRevision else { throw CancellationError() }

        for item in outcome.moved {
            let normalized = item.originalPath
            let local = join(connection.localPath, normalized)

            if fm.fileExists(atPath: local) {
                do {
                    try stageLocalTrashCleanup(local, localRoot: connection.localPath)
                    inventoryRetire(normalized, reason: "Explicit Move to Trash completed")
                } catch {
                    failures.append("\(normalized) (local copy: \(error.localizedDescription))")
                }
            }

            pinnedPaths.remove(normalized)
            pinnedPaths = Set(pinnedPaths.filter { !$0.hasPrefix(normalized + "/") })
            removeKnownPath(normalized)
            emit(.init(
                kind: .file,
                message: "Moved to Trash: \(item.name)",
                path: normalized
            ))
        }
        failures += outcome.failures.map { path in
            outcome.failureReasons[path].map { "\(path): \($0)" } ?? path
        }
        if let indexError = outcome.indexError {
            // The payloads are on disk and can be recovered by a later scan, but
            // other Macs cannot see their original paths until the index is fixed.
            failures.append("Trash index could not be updated:\n\(indexError)")
        }

        // removeKnownPath already updated the exact affected subtree. A full
        // pinned-tree scan here turns one server rename into thousands of SMB stats.
        persistSyncState()
        updateRemoteWatchPaths()

        if !failures.isEmpty {
            let list = failures.prefix(3).joined(separator: ", ")
            let suffix = failures.count > 3 ? " and \(failures.count - 3) more" : ""
            throw SyncError.invalidMove("Could not move to Trash: \(list)\(suffix)")
        }
    }

    // MARK: - Trash

    /// Move cached trees out of the browser with one rename; unlink off-actor.
    private func stageLocalTrashCleanup(_ path: String, localRoot: String) throws {
        let staging = (localRoot as NSString).appendingPathComponent(".tethwork-trash-cleanup-\(UUID().uuidString)")
        guard TrashStore.isContained(path, in: localRoot) else {
            throw SyncError.invalidMove("Local Trash path is outside the sync folder: \(path)")
        }
        guard Darwin.rename(path, staging) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
        Task.detached(priority: .utility) {
            do { try FileManager.default.removeItem(atPath: staging) }
            catch { NSLog("Tethwork local Trash cleanup deferred at %@: %@", staging, error.localizedDescription) }
        }
    }

    /// Trash contents for the connected volume, newest first. Expired items are purged first.
    func listTrashItems(purgingExpired: Bool = false) async -> [TrashItem] {
        guard let root = connection?.remotePath else { return [] }
        return await Task.detached(priority: .utility) {
            if purgingExpired {
                TrashStore.purgeExpired(remoteRoot: root)
            }
            return TrashStore.loadItems(remoteRoot: root)
        }.value
    }

    /// Removes trash items whose 15-day retention has elapsed. Returns the count.
    @discardableResult
    func purgeExpiredTrash() async -> Int {
        guard let root = connection?.remotePath else { return 0 }
        return await Task.detached(priority: .utility) {
            TrashStore.purgeExpired(remoteRoot: root)
        }.value
    }

    /// Moves trashed items back to their original location (or a free name next to it).
    func restoreTrashItems(ids: [String]) async throws -> [TrashStore.RestoreResult] {
        let connection = try writableConnection()
        suppress(for: 1.5)
        paused = true
        defer { paused = false; schedulePendingResync() }

        let root = connection.remotePath
        let results = try await Task.detached(priority: .userInitiated) {
            try TrashStore.restore(ids: Set(ids), remoteRoot: root)
        }.value

        for result in results where result.item.wasPinned {
            // An ancestor pin may already cover the restored path.
            if !shouldKeepLocal(result.restoredPath) {
                pinnedPaths.insert(result.restoredPath)
            }
        }
        try? await refreshPersistedSyncState()
        persistSyncState()
        updateRemoteWatchPaths()
        for result in results {
            emit(.init(
                kind: .file,
                message: "Restored: \(result.item.name)",
                path: result.restoredPath
            ))
        }
        return results
    }

    func deleteTrashItems(ids: [String]) async throws {
        let connection = try writableConnection()
        let root = connection.remotePath
        try await Task.detached(priority: .userInitiated) {
            try TrashStore.deletePermanently(ids: Set(ids), remoteRoot: root)
        }.value
    }

    func emptyTrash() async throws {
        let connection = try writableConnection()
        let root = connection.remotePath
        try await Task.detached(priority: .userInitiated) {
            try TrashStore.empty(remoteRoot: root)
        }.value
    }

    /// Moves items into a destination directory (remote + local copy if present).
    func moveItems(relativePaths: [String], toDirectory destinationDir: String) async throws {
        let connection = try writableConnection()
        try validateUserPath(destinationDir, connection: connection)
        for path in relativePaths { try validateUserPath(path, connection: connection) }
        await stopTransfers()
        guard self.connection?.id == connection.id else { throw CancellationError() }
        guard destinationDir.isEmpty || TrashStore.safeRelativePath(destinationDir) != nil else {
            throw SyncError.invalidMove("Invalid destination folder: \(destinationDir)")
        }
        let destDir = Self.normalize(destinationDir)
        suppress(for: 1.5)
        paused = true
        defer { paused = false; schedulePendingResync() }

        for relativePath in relativePaths {
            let source = Self.normalize(relativePath)
            guard !source.isEmpty else { continue }

            let name = (source as NSString).lastPathComponent
            let destination = destDir.isEmpty ? name : "\(destDir)/\(name)"

            if source == destination { continue }
            if destination == source || destination.hasPrefix(source + "/") {
                throw SyncError.invalidMove("Cannot move a folder into itself")
            }
            if !destDir.isEmpty && (destDir == source || destDir.hasPrefix(source + "/")) {
                throw SyncError.invalidMove("Cannot move a folder into itself")
            }

            let remoteFrom = join(connection.remotePath, source)
            let remoteTo = join(connection.remotePath, destination)
            let localFrom = join(connection.localPath, source)
            let localTo = join(connection.localPath, destination)

            guard fm.fileExists(atPath: remoteFrom) else {
                throw SyncError.notFound(source)
            }
            if fm.fileExists(atPath: remoteTo) {
                throw SyncError.invalidMove("“\(name)” already exists in the destination folder")
            }

            try fm.createDirectory(
                atPath: (remoteTo as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try fm.moveItem(atPath: remoteFrom, toPath: remoteTo)

            var localFailure: Error?
            if fm.fileExists(atPath: localFrom) {
                do {
                    try fm.createDirectory(
                        atPath: (localTo as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true
                    )
                    guard !fm.fileExists(atPath: localTo) else {
                        throw SyncError.invalidMove("A different local item already exists: \(destination)")
                    }
                    try fm.moveItem(atPath: localFrom, toPath: localTo)
                } catch {
                    localFailure = error
                }
            }

            // Remap pins under the moved path.
            var updated = Set<String>()
            for pin in pinnedPaths {
                if pin == source {
                    updated.insert(destination)
                } else if pin.hasPrefix(source + "/") {
                    let suffix = pin.dropFirst(source.count)
                    updated.insert(destination + suffix)
                } else {
                    updated.insert(pin)
                }
            }
            pinnedPaths = updated
            remapKnownPaths(from: source, to: destination)

            if let localFailure {
                persistSyncState()
                throw SyncError.invalidMove(
                    "“\(name)” was moved on the network volume, but the local copy could not be moved: \(localFailure.localizedDescription)"
                )
            }

            emit(.init(kind: .file, message: "Moved: \(name)", path: destination))
        }
        persistSyncState()
    }

    /// Renames a single item on the remote volume and its local copy if present.
    /// Returns the new relative path.
    func renameItem(relativePath: String, newName: String) async throws -> String {
        let connection = try writableConnection()
        try validateUserPath(relativePath, connection: connection)
        let source = Self.normalize(relativePath)
        guard !source.isEmpty else {
            throw SyncError.invalidMove("Cannot rename the root")
        }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SyncError.invalidMove("Name cannot be empty")
        }
        guard TrashStore.isValidName(trimmed) else {
            throw SyncError.invalidMove("Invalid name")
        }
        guard !trimmed.hasPrefix(".") else {
            throw SyncError.invalidMove("Name cannot start with a period")
        }

        let parent = (source as NSString).deletingLastPathComponent
        let parentNorm = (parent == "." || parent.isEmpty) ? "" : Self.normalize(parent)
        let destination = parentNorm.isEmpty ? trimmed : "\(parentNorm)/\(trimmed)"
        if source == destination { return destination }

        await stopTransfers()
        guard self.connection?.id == connection.id else { throw CancellationError() }
        suppress(for: 1.5)
        paused = true
        defer { paused = false; schedulePendingResync() }

        let remoteFrom = join(connection.remotePath, source)
        let remoteTo = join(connection.remotePath, destination)
        let localFrom = join(connection.localPath, source)
        let localTo = join(connection.localPath, destination)

        guard fm.fileExists(atPath: remoteFrom) else {
            throw SyncError.notFound(source)
        }

        // On case-insensitive volumes (the macOS default), "work" and "Work" are the
        // same file, so an existence check against the destination — and a direct
        // rename — would collide with the source itself. Route case-only renames
        // through a temporary name instead.
        let caseOnlyRename = destination.caseInsensitiveCompare(source) == .orderedSame
        var localFailure: Error?

        if caseOnlyRename {
            let tempSuffix = "__tethwork_rename_\(UUID().uuidString.prefix(8))"
            try fm.moveItem(atPath: remoteFrom, toPath: remoteFrom + tempSuffix)
            do {
                try fm.moveItem(atPath: remoteFrom + tempSuffix, toPath: remoteTo)
            } catch {
                try? fm.moveItem(atPath: remoteFrom + tempSuffix, toPath: remoteFrom)
                throw error
            }

            if fm.fileExists(atPath: localFrom) {
                do {
                    try fm.moveItem(atPath: localFrom, toPath: localFrom + tempSuffix)
                    do {
                        try fm.moveItem(atPath: localFrom + tempSuffix, toPath: localTo)
                    } catch {
                        try? fm.moveItem(atPath: localFrom + tempSuffix, toPath: localFrom)
                        throw error
                    }
                } catch {
                    localFailure = error
                }
            }
        } else {
            if fm.fileExists(atPath: remoteTo) {
                throw SyncError.invalidMove("“\(trimmed)” already exists")
            }

            try fm.moveItem(atPath: remoteFrom, toPath: remoteTo)

            if fm.fileExists(atPath: localFrom) {
                do {
                    guard !fm.fileExists(atPath: localTo) else {
                        throw SyncError.invalidMove("A different local item already exists: \(destination)")
                    }
                    try fm.moveItem(atPath: localFrom, toPath: localTo)
                } catch {
                    localFailure = error
                }
            }
        }

        var updated = Set<String>()
        for pin in pinnedPaths {
            if pin == source {
                updated.insert(destination)
            } else if pin.hasPrefix(source + "/") {
                let suffix = pin.dropFirst(source.count)
                updated.insert(destination + suffix)
            } else {
                updated.insert(pin)
            }
        }
        pinnedPaths = updated
        remapKnownPaths(from: source, to: destination)
        persistSyncState()

        if let localFailure {
            throw SyncError.invalidMove(
                "“\(trimmed)” was renamed on the network volume, but the local copy could not be renamed: \(localFailure.localizedDescription)"
            )
        }

        emit(.init(kind: .file, message: "Renamed: \(trimmed)", path: destination))
        return destination
    }

    /// Publish the final local paths only after the additive background upload finishes.
    /// Reading/listing is available throughout; reconciliation and mutations wait.
    @discardableResult
    func finishInitialMerge(connectionID: String, paths: [String]) throws -> [String] {
        guard connection?.id == connectionID, initialMergePending else { throw SyncError.notConnected }
        invalidateFolderStorage()
        pinnedPaths = Set(Self.compactPinnedPaths(Array(pinnedPaths) + paths))
        knownSyncedPaths.formUnion(paths.map(Self.normalize))
        persistSyncState()
        initialMergePending = false
        if watchesDirectories { startWatchers() }
        return getPinnedPaths()
    }

    func prepareInitialMerge(connectionID: String) throws {
        guard connection?.id == connectionID, !syncing else { throw SyncError.notConnected }
        stopWatchers()
        initialMergePending = true
    }

    /// Stop adoption without committing an empty baseline over existing pins.
    func abortInitialMerge(connectionID: String) throws {
        guard connection?.id == connectionID else { throw SyncError.notConnected }
        initialMergePending = false
        if watchesDirectories { startWatchers() }
    }

    private func writableConnection() throws -> SyncConnection {
        guard let connection else { throw SyncError.notConnected }
        try Self.validateConnectionSafety(connection, homeDirectory: homeDirectory)
        guard !initialMergePending else {
            throw SyncError.invalidMove("Local files are still being merged. Please wait before changing files or local storage.")
        }
        invalidateFolderStorage()
        return connection
    }

    /// Size and modification date identify an unchanged file without reading
    /// its bytes. A full adoption of a large share must not re-read 100 GB just
    /// to confirm what a previous pass already proved.
    private struct InitialMergeSignature: Equatable {
        let size: Int64
        let modified: Date

        init?(_ attributes: [FileAttributeKey: Any]) {
            guard let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.size = size.int64Value
            self.modified = modified
        }

        func matches(_ other: InitialMergeSignature) -> Bool {
            // SMB may round timestamps to whole seconds.
            size == other.size && abs(modified.timeIntervalSince(other.modified)) < 1
        }

        /// Metadata proves equality only when the timestamps are identical, not
        /// merely within the coarse SMB tolerance: two files written in the same
        /// second can share a size while their contents differ. Uploads align the
        /// remote timestamp with the source, so settled pairs still match here.
        func provesEquality(of other: InitialMergeSignature) -> Bool {
            // Back-to-back writes differ by microseconds; only filesystem
            // timestamp rounding (100 ns on SMB) may be ignored here.
            size == other.size && abs(modified.timeIntervalSince(other.modified)) < 0.000001
        }
    }

    private struct InitialMergeMatch {
        let source: URL
        let remote: URL
        let finalLocal: URL
        let sourceSignature: InitialMergeSignature
        let remoteSignature: InitialMergeSignature
    }

    private struct InitialMergeUpload {
        let source: URL
        let destination: URL
        let relativePath: String
        let bytes: Int64
    }

    private struct InitialMergeRename {
        let source: URL
        let destination: URL
        /// Where the local file was uploaded. Directories are renamed without
        /// an upload.
        let remoteDestination: URL?
        var signature: InitialMergeSignature?
    }

    private struct InitialMergePlan {
        let localRoot: URL
        var directories: [URL] = []
        var uploads: [InitialMergeUpload] = []
        var renames: [InitialMergeRename] = []
        var matchingFiles: [InitialMergeMatch] = []
        var localPaths = Set<String>()
        var reservedPaths = Set<String>()
    }

    /// Adopt only existing local content. Never download or overwrite server content.
    /// Conflicting local names are changed only after every upload succeeds.
    nonisolated static func mergeExistingLocalFiles(
        connection: SyncConnection,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> [String] {
        try await mergeExistingLocalFiles(connection: connection, onTransferRate: nil, onProgress: onProgress)
    }

    nonisolated static func mergeExistingLocalFiles(
        connection: SyncConnection,
        onTransferRate: (@Sendable (Double) -> Void)?,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> [String] {
        try await mergeExistingLocalFiles(connection: connection, onTransferRate: onTransferRate,
                                          onSnapshot: nil, onProgress: onProgress)
    }

    nonisolated static func mergeExistingLocalFiles(
        connection: SyncConnection,
        onTransferRate: (@Sendable (Double) -> Void)?,
        onSnapshot: (@Sendable (InitialUploadProgress) -> Void)?,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> [String] {
        let task = Task.detached(priority: .utility) {
            try validateConnectionSafety(connection)
            onSnapshot?(.init(phase: .preparing, filesDone: 0, filesTotal: 0, bytesDone: 0,
                              bytesTotal: nil, currentPath: "", bytesPerSecond: nil, estimatedSecondsRemaining: nil))
            guard rootsAreDisjoint(connection.remotePath, connection.localPath) else {
                throw SyncError.overlappingRoots
            }
            try validateRemoteRoot(connection.remotePath)
            let fm = FileManager.default
            let localRoot = URL(fileURLWithPath: canonicalPath(connection.localPath))
            let remoteRoot = URL(fileURLWithPath: connection.remotePath)
            guard try mergeItemType(at: localRoot, fm: fm) != nil else { return [String]() }
            var sizes: [String: Int64] = [:]
            try inventoryInitialMerge(local: localRoot, relativePath: "", root: localRoot.path, fm: fm, sizes: &sizes)
            var totalBytes = sizes.values.reduce(Int64(0), +)
            var filesTotal = sizes.count
            var bytesDone: Int64 = 0
            var filesDone = 0
            var currentRate: Double?
            var estimator = TransferTimeEstimator()
            var startedAt = ContinuousClock.now
            var lastSnapshot: ContinuousClock.Instant?
            // Sources that change while the pass runs are left for normal sync
            // instead of aborting (and re-counting) the whole adoption.
            var deferredFiles = 0
            var plan = InitialMergePlan(localRoot: localRoot)
            func report(_ phase: SyncPhase, path: String, force: Bool = false) {
                let now = ContinuousClock.now
                if !force, let lastSnapshot, lastSnapshot.duration(to: now) < .milliseconds(200) { return }
                lastSnapshot = now
                let duration = startedAt.duration(to: now).components
                let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                let remaining = estimator.estimate(bytesDone: bytesDone, filesDone: filesDone,
                                                    bytesTotal: totalBytes, filesTotal: filesTotal, elapsed: elapsed)
                onSnapshot?(.init(phase: phase, filesDone: filesDone, filesTotal: filesTotal,
                                  bytesDone: bytesDone, bytesTotal: totalBytes, currentPath: path,
                                  bytesPerSecond: currentRate, estimatedSecondsRemaining: remaining,
                                  deferredFiles: deferredFiles))
            }
            func resetStage(bytes: Int64, files: Int) {
                totalBytes = bytes
                filesTotal = files
                bytesDone = 0
                filesDone = 0
                currentRate = nil
                estimator = TransferTimeEstimator()
                startedAt = .now
                lastSnapshot = nil
            }
            report(.checking, path: "", force: true)
            var comparisonPath = ""
            var comparisonSize: Int64 = 0
            var comparisonBytes: Int64 = 0
            try planInitialMerge(local: localRoot, remote: remoteRoot, relativePath: "", fm: fm, plan: &plan,
                                 onDeferred: { deferredFiles += 1 },
                                 onFileStarted: { path, size in
                if let previous = sizes[path] { totalBytes += size - previous }
                else { totalBytes += size; filesTotal += 1 }
                sizes[path] = size
                comparisonPath = initialMergeRelativePath(path, root: localRoot.path)
                comparisonSize = size
                comparisonBytes = 0
                report(.checking, path: comparisonPath)
            }, onComparedBytes: { count in
                let amount = min(Int64(count), max(0, comparisonSize - comparisonBytes))
                comparisonBytes += amount
                bytesDone += amount
                report(.checking, path: comparisonPath)
            }, onFileFinished: {
                // A missing/different remote file needs no full byte comparison,
                // but its inventory work is complete and must advance progress.
                bytesDone += max(0, comparisonSize - comparisonBytes)
                filesDone += 1
                report(.checking, path: comparisonPath)
            })
            filesTotal = filesDone + plan.directories.count
            totalBytes = bytesDone
            for directory in plan.directories {
                try Task.checkCancellation()
                try validateRemoteRoot(connection.remotePath)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                filesDone += 1
                report(.checking, path: directory.lastPathComponent)
            }
            report(.checking, path: "", force: true)
            onProgress?(0, plan.uploads.count, "")
            resetStage(bytes: plan.uploads.reduce(Int64(0)) { $0 + $1.bytes }, files: plan.uploads.count)
            report(.transferring, path: "", force: true)
            var rateMeter = TransferRateMeter()
            for upload in plan.uploads {
                try Task.checkCancellation()
                try validateRemoteRoot(connection.remotePath)
                guard let attributes = try initialMergeAttributes(at: upload.source.path, root: localRoot.path) else {
                    totalBytes -= upload.bytes
                    filesTotal -= 1
                    plan.localPaths.remove(upload.relativePath)
                    onProgress?(filesDone, filesTotal, upload.relativePath)
                    report(.transferring, path: upload.relativePath, force: true)
                    continue
                }
                let currentSize = (attributes[.size] as? NSNumber)?.int64Value ?? upload.bytes
                let sourceSignature = InitialMergeSignature(attributes)
                totalBytes += max(0, currentSize) - upload.bytes
                let bytesBefore = bytesDone
                let temporary = upload.destination.deletingLastPathComponent()
                    .appendingPathComponent(".tethwork-copy-\(UUID().uuidString)")
                // Unlike ordinary sync, initial adoption must never replace a destination,
                // even if another client creates it after the plan was made.
                do {
                    defer { try? fm.removeItem(at: temporary) }
                    try copyCancellably(from: upload.source.path, to: temporary.path, fm: fm) { count in
                        bytesDone += Int64(count)
                        if let rate = rateMeter.record(bytes: count) {
                            currentRate = rate
                            onTransferRate?(rate)
                        }
                        report(.transferring, path: upload.relativePath)
                    }
                    try Task.checkCancellation()
                    try validateRemoteRoot(connection.remotePath)
                    // Never publish a snapshot of a file that was being written
                    // while it was copied (databases, Photos journals, logs).
                    let afterCopy = try initialMergeAttributes(at: upload.source.path, root: localRoot.path)
                        .flatMap(InitialMergeSignature.init)
                    if let sourceSignature, let afterCopy, !sourceSignature.matches(afterCopy) {
                        try? fm.removeItem(at: temporary)
                        bytesDone = bytesBefore
                        totalBytes -= max(0, currentSize)
                        filesTotal -= 1
                        deferredFiles += 1
                        plan.localPaths.remove(upload.relativePath)
                        onProgress?(filesDone, filesTotal, upload.relativePath)
                        report(.transferring, path: upload.relativePath, force: true)
                        continue
                    }
                    try fm.moveItem(at: temporary, to: upload.destination)
                    if let afterCopy {
                        if let index = plan.renames.firstIndex(where: { $0.source.path == upload.source.path }) {
                            plan.renames[index].signature = afterCopy
                        }
                        // Align timestamps so a later pass can prove equality by
                        // metadata and skip re-reading the whole file.
                        try? fm.setAttributes([.modificationDate: afterCopy.modified],
                                              ofItemAtPath: upload.destination.path)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if isVanishedInitialMergeSource(error, path: upload.source.path, root: localRoot.path) {
                        bytesDone = bytesBefore
                        totalBytes -= max(0, currentSize)
                        filesTotal -= 1
                        plan.localPaths.remove(upload.relativePath)
                        onProgress?(filesDone, filesTotal, upload.relativePath)
                        report(.transferring, path: upload.relativePath, force: true)
                        continue
                    }
                    let diagnostic = transferFailure(error, from: upload.source.path, to: upload.destination.path,
                                                     operation: "Initial upload")
                    NSLog("Tethwork initial upload failed: %@", diagnostic.localizedDescription)
                    throw diagnostic
                }
                filesDone += 1
                onProgress?(filesDone, filesTotal, upload.relativePath)
                report(.transferring, path: upload.relativePath, force: filesDone == filesTotal)
            }
            if let rate = rateMeter.flush() {
                currentRate = rate
                onTransferRate?(rate)
            }

            try Task.checkCancellation()
            let plannedMatches = plan.matchingFiles
            plan.matchingFiles.removeAll(keepingCapacity: true)
            var verificationSizes: [String: Int64] = [:]
            for match in plannedMatches {
                guard let attributes = try initialMergeAttributes(at: match.source.path, root: localRoot.path) else {
                    plan.localPaths.remove(initialMergeRelativePath(match.finalLocal.path, root: localRoot.path))
                    continue
                }
                verificationSizes[match.source.path] = max(0, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
                plan.matchingFiles.append(match)
            }
            let verificationBytes = verificationSizes.values.reduce(Int64(0), +)
            resetStage(bytes: verificationBytes, files: plan.matchingFiles.count * 2 + plan.renames.count)
            report(.finishing, path: "", force: true)
            var unverifiedMatches = Set<String>()
            for match in plan.matchingFiles {
                let bytesBefore = bytesDone
                let size = verificationSizes[match.source.path] ?? match.sourceSignature.size
                do {
                    guard let sourceNow = try initialMergeSignature(at: match.source.path),
                          try mergeItemType(at: match.remote, fm: fm) == .typeRegular,
                          let remoteNow = try initialMergeSignature(at: match.remote.path) else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                    }
                    // Comparison already proved byte equality. A fresh stat is
                    // enough; re-read only if either side moved in the meantime.
                    var verified = match.sourceSignature.matches(sourceNow) && match.remoteSignature.matches(remoteNow)
                    if !verified, sourceNow.size == remoteNow.size {
                        verified = try compareRegularFiles(match.source.path, match.remote.path, onBytes: { count in
                            bytesDone += Int64(count)
                            report(.finishing, path: match.source.lastPathComponent)
                        })
                    }
                    if verified {
                        try? fm.setAttributes([.modificationDate: remoteNow.modified], ofItemAtPath: match.finalLocal.path)
                    } else {
                        // An actively edited file is not an access failure. Never
                        // fail (and re-count) the whole adoption because a live
                        // database changed; normal sync reconciles it next.
                        bytesDone = bytesBefore
                        totalBytes -= size
                        filesTotal -= 2
                        deferredFiles += 1
                        unverifiedMatches.insert(match.source.path)
                        plan.localPaths.remove(initialMergeRelativePath(match.finalLocal.path, root: localRoot.path))
                        report(.finishing, path: match.source.lastPathComponent, force: true)
                        continue
                    }
                } catch {
                    guard isVanishedInitialMergeSource(error, path: match.source.path, root: localRoot.path) else { throw error }
                    bytesDone = bytesBefore
                    totalBytes -= size
                    filesTotal -= 2
                    unverifiedMatches.insert(match.source.path)
                    plan.localPaths.remove(initialMergeRelativePath(match.finalLocal.path, root: localRoot.path))
                    report(.finishing, path: match.source.lastPathComponent, force: true)
                    continue
                }
                bytesDone += max(0, size - (bytesDone - bytesBefore))
                filesDone += 1
                report(.finishing, path: match.source.lastPathComponent)
            }
            // Nested renames must happen before their parent folder is renamed.
            // A source that changed during the pass must keep its live name so a
            // running app (for example Photos) still finds its database.
            for rename in plan.renames.sorted(by: { $0.source.pathComponents.count > $1.source.pathComponents.count }) {
                let relativePath = initialMergeRelativePath(rename.destination.path, root: localRoot.path)
                if let remote = rename.remoteDestination, try mergeItemType(at: remote, fm: fm) == nil {
                    deferredFiles += 1
                    plan.localPaths.remove(relativePath)
                    filesDone += 1
                    report(.finishing, path: rename.source.lastPathComponent, force: true)
                    continue
                }
                if let signature = rename.signature,
                   let current = try initialMergeSignature(at: rename.source.path),
                   !signature.matches(current) {
                    deferredFiles += 1
                    plan.localPaths.remove(relativePath)
                    filesDone += 1
                    report(.finishing, path: rename.source.lastPathComponent, force: true)
                    continue
                }
                do { try fm.moveItem(at: rename.source, to: rename.destination) }
                catch {
                    if isVanishedInitialMergeSource(error, path: rename.source.path, root: localRoot.path) {
                        plan.localPaths = plan.localPaths.filter { $0 != relativePath && !$0.hasPrefix(relativePath + "/") }
                        filesDone += 1
                        report(.finishing, path: rename.source.lastPathComponent)
                        continue
                    }
                    throw transferFailure(error, from: rename.source.path, to: rename.destination.path,
                                          operation: "Rename local conflict after upload")
                }
                filesDone += 1
                report(.finishing, path: rename.source.lastPathComponent)
            }
            // Verification already aligned timestamps; this pass keeps the file
            // count honest without touching the network again.
            for match in plan.matchingFiles where !unverifiedMatches.contains(match.source.path) {
                filesDone += 1
                report(.finishing, path: match.finalLocal.lastPathComponent)
            }
            report(.finishing, path: "", force: true)
            // A missing child may be transient; losing the entire source root
            // must never be reported as a successful empty adoption.
            _ = try fm.contentsOfDirectory(at: localRoot, includingPropertiesForKeys: nil)
            return plan.localPaths.sorted()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func mergeItemType(at url: URL, fm: FileManager) throws -> FileAttributeType? {
        do {
            return try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code)) ||
                (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)) {
                return nil
            }
            throw transferFailure(error, from: url.path, to: url.path, operation: "Read file type for initial upload")
        }
    }

    nonisolated private static func transferFailure(_ error: Error, from: String, to: String, operation: String) -> NSError {
        let original = error as NSError
        if original.userInfo["Tethwork.Operation"] != nil { return original }
        var details = original.userInfo
        details["Tethwork.Operation"] = operation
        details["Tethwork.Source"] = from
        details["Tethwork.Destination"] = to
        details[NSUnderlyingErrorKey] = original
        let locations = from == to ? "Path: \(from)" : "Source: \(from)\nDestination: \(to)"
        details[NSLocalizedDescriptionKey] = "\(operation): \(error.localizedDescription)\n\(locations)\n\(TrashStore.fileErrorDiagnostic(error).details)"
        return NSError(domain: original.domain, code: original.code, userInfo: details)
    }

    nonisolated private static func readAttributes(at path: String) throws -> [FileAttributeKey: Any] {
        do { return try FileManager.default.attributesOfItem(atPath: path) }
        catch { throw transferFailure(error, from: path, to: path, operation: "Read file metadata") }
    }

    /// Unlike fileExists, lstat sees dangling symlinks as existing directory entries.
    nonisolated private static func itemExistsWithoutFollowingLink(_ path: String) throws -> Bool {
        var info = stat()
        while Darwin.lstat(path, &info) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == ENOENT { return false }
            throw posixFileError(code, path: path, operation: "Read directory entry")
        }
        return true
    }

    nonisolated private static func readResourceValues(_ url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        do { return try url.resourceValues(forKeys: keys) }
        catch { throw transferFailure(error, from: url.path, to: url.path, operation: "Read file properties") }
    }

    nonisolated private static func initialMergeName(
        preferred: String, isDirectory: Bool, localParent: URL, remoteParent: URL,
        fm: FileManager, reserved: Set<String>
    ) throws -> String {
        let ext = isDirectory ? "" : (preferred as NSString).pathExtension
        let stem = ext.isEmpty ? preferred : (preferred as NSString).deletingPathExtension
        for index in 1...Int.max {
            let suffix = index == 1 ? " (Local)" : " (Local \(index))"
            let name = stem + suffix + (ext.isEmpty ? "" : ".\(ext)")
            let remote = remoteParent.appendingPathComponent(name)
            if !reserved.contains(remote.path.lowercased()),
               try mergeItemType(at: remote, fm: fm) == nil,
               try mergeItemType(at: localParent.appendingPathComponent(name), fm: fm) == nil {
                return name
            }
        }
        throw SyncError.invalidMove("Could not find a free name for \(preferred)")
    }

    nonisolated private static func isInitialMergeInternal(_ name: String, relativePath: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix(".tethwork-copy-") ||
            (relativePath.isEmpty && [".tethwork-sync-state.json", ".tethwork-verification-cache.json", ".tethwork-trash"].contains(name))
    }

    nonisolated private static func initialMergeRelativePath(_ path: String, root: String) -> String {
        let source = canonicalPath(path)
        let base = canonicalPath(root)
        guard source.hasPrefix(base + "/") else { return path }
        return String(source.dropFirst(base.count + 1))
    }

    /// Only an explicit missing-source error is recoverable here. Never hide
    /// access failures, a vanished destination, or an unavailable local root.
    nonisolated static func isVanishedInitialMergeSource(_ error: Error, path: String, root: String) -> Bool {
        var cause = error as NSError
        var seen = Set<ObjectIdentifier>()
        for _ in 0..<8 {
            guard seen.insert(ObjectIdentifier(cause)).inserted else { return false }
            guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            cause = underlying
        }
        let missing = (cause.domain == NSPOSIXErrorDomain && cause.code == Int(ENOENT)) ||
            (cause.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cause.code))
        let source = canonicalPath(path)
        let base = canonicalPath(root)
        guard missing, source != base, source.hasPrefix(base + "/") else { return false }
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: root)) != nil
    }

    nonisolated private static func initialMergeAttributes(at path: String, root: String) throws -> [FileAttributeKey: Any]? {
        do { return try readAttributes(at: path) }
        catch {
            if isVanishedInitialMergeSource(error, path: path, root: root) { return nil }
            throw error
        }
    }

    /// Remote metadata, where a missing file is an ordinary planning outcome
    /// rather than a lost source root.
    nonisolated private static func initialMergeSignature(at path: String) throws -> InitialMergeSignature? {
        do { return InitialMergeSignature(try readAttributes(at: path)) }
        catch {
            let error = error as NSError
            if (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) ||
                (error.domain == NSCocoaErrorDomain &&
                 [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) { return nil }
            throw error
        }
    }

    /// Read local metadata only, before any slow network content comparisons.
    nonisolated private static func inventoryInitialMerge(local: URL, relativePath: String, root: String, fm: FileManager,
                                                          sizes: inout [String: Int64]) throws {
        let children: [URL]
        do { children = try fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) }
        catch {
            if isVanishedInitialMergeSource(error, path: local.path, root: root) { return }
            throw error
        }
        for child in children {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            if isInitialMergeInternal(name, relativePath: relativePath) { continue }
            guard let attributes = try initialMergeAttributes(at: child.path, root: root) else { continue }
            let type = attributes[.type] as? FileAttributeType
            if type == .typeDirectory {
                try inventoryInitialMerge(local: child, relativePath: relativePath.isEmpty ? name : "\(relativePath)/\(name)", root: root, fm: fm, sizes: &sizes)
            } else if type == .typeRegular {
                sizes[child.path] = max(0, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
            } else {
                throw SyncError.invalidMove("Cannot safely merge this local item (links and special files are not followed): \(child.path)")
            }
        }
    }

    nonisolated private static func planInitialMerge(
        local: URL, remote: URL, relativePath: String, fm: FileManager, plan: inout InitialMergePlan,
        onDeferred: (() -> Void)? = nil,
        onFileStarted: ((String, Int64) -> Void)? = nil,
        onComparedBytes: ((Int) -> Void)? = nil,
        onFileFinished: (() -> Void)? = nil
    ) throws {
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            if isVanishedInitialMergeSource(error, path: local.path, root: plan.localRoot.path) { return }
            throw transferFailure(error, from: local.path, to: remote.path, operation: "Read local folder for initial upload")
        }
        for child in children {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            // Internal state is not user content. Other dotfiles are deliberately included.
            if isInitialMergeInternal(name, relativePath: relativePath) { continue }
            guard let attributes = try initialMergeAttributes(at: child.path, root: plan.localRoot.path) else { continue }
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else {
                throw SyncError.invalidMove("Cannot safely merge this local item (links and special files are not followed): \(child.path)")
            }
            let isDirectory = type == .typeDirectory
            let size = max(0, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
            let localSignature = InitialMergeSignature(attributes)
            if !isDirectory {
                onFileStarted?(child.path, size)
            }
            var destination = remote.appendingPathComponent(name)
            let remoteType = try mergeItemType(at: destination, fm: fm)
            let reserved = plan.reservedPaths.contains(destination.path.lowercased())
            let matchingFile: Bool
            var matchedSource: InitialMergeSignature?
            var matchedRemote: InitialMergeSignature?
            do {
                if isDirectory || remoteType != .typeRegular || reserved || localSignature == nil {
                    matchingFile = false
                } else {
                    let remoteSignature = try initialMergeSignature(at: destination.path)
                    if let localSignature, let remoteSignature,
                       localSignature.provesEquality(of: remoteSignature) {
                        // Proven equal by size and timestamp: no bytes to read.
                        matchingFile = true
                        matchedSource = localSignature
                        matchedRemote = remoteSignature
                    } else if let localSignature, let remoteSignature, remoteSignature.size == localSignature.size {
                        let equal = try compareRegularFiles(child.path, destination.path, onBytes: onComparedBytes)
                        let after = try initialMergeSignature(at: child.path)
                        if equal, let after, !localSignature.matches(after) {
                            // The file was being written during the comparison.
                            onDeferred?()
                            onFileFinished?()
                            continue
                        }
                        matchingFile = equal
                        if equal {
                            try? fm.setAttributes([.modificationDate: remoteSignature.modified], ofItemAtPath: child.path)
                            matchedSource = try initialMergeSignature(at: child.path) ?? after
                            matchedRemote = remoteSignature
                        }
                    } else {
                        matchingFile = false
                    }
                }
            } catch {
                if isVanishedInitialMergeSource(error, path: child.path, root: plan.localRoot.path) {
                    onFileFinished?()
                    continue
                }
                throw error
            }
            if reserved || (remoteType != nil && !(isDirectory && remoteType == .typeDirectory) && !matchingFile) {
                let unique = try initialMergeName(preferred: name, isDirectory: isDirectory,
                                                  localParent: local, remoteParent: remote,
                                                  fm: fm, reserved: plan.reservedPaths)
                destination = remote.appendingPathComponent(unique)
                plan.renames.append(InitialMergeRename(source: child,
                                                       destination: local.appendingPathComponent(unique),
                                                       remoteDestination: isDirectory ? nil : destination,
                                                       signature: isDirectory ? localSignature : nil))
            }
            plan.reservedPaths.insert(destination.path.lowercased())
            let destinationPath = relativePath.isEmpty ? destination.lastPathComponent : "\(relativePath)/\(destination.lastPathComponent)"
            if isDirectory {
                plan.directories.append(destination)
                let countBefore = plan.localPaths.count
                try planInitialMerge(local: child, remote: destination, relativePath: destinationPath, fm: fm, plan: &plan,
                                     onDeferred: onDeferred, onFileStarted: onFileStarted, onComparedBytes: onComparedBytes, onFileFinished: onFileFinished)
                if plan.localPaths.count == countBefore {
                    guard try initialMergeAttributes(at: child.path, root: plan.localRoot.path) != nil else {
                        plan.directories.removeAll { $0.path == destination.path || $0.path.hasPrefix(destination.path + "/") }
                        continue
                    }
                    // Pin an empty directory only if it will not pull existing online files down.
                    let serverChildren = (remoteType == .typeDirectory && destination.lastPathComponent == name)
                        ? try fm.contentsOfDirectory(atPath: destination.path) : []
                    if serverChildren.isEmpty { plan.localPaths.insert(destinationPath) }
                }
            } else {
                plan.localPaths.insert(destinationPath)
                if matchingFile, let matchedSource, let matchedRemote {
                    plan.matchingFiles.append(InitialMergeMatch(source: child, remote: destination,
                                                                finalLocal: plan.localRoot.appendingPathComponent(destinationPath),
                                                                sourceSignature: matchedSource,
                                                                remoteSignature: matchedRemote))
                } else {
                    plan.uploads.append(InitialMergeUpload(source: child, destination: destination,
                                                           relativePath: destinationPath, bytes: size))
                }
                onFileFinished?()
            }
        }
    }

    /// Copies Finder / external files and folders into a destination directory on the network volume.
    /// Also mirrors into the local sync folder when that path is pinned.
    /// `onProgress` is called with (completed, total, currentName) as each file finishes.
    func importItems(
        from sourceURLs: [URL],
        toDirectory destinationDir: String,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws {
        let connection = try writableConnection()
        try validateUserPath(destinationDir, connection: connection)
        await stopTransfers()
        guard self.connection?.id == connection.id else { throw CancellationError() }
        guard destinationDir.isEmpty || TrashStore.safeRelativePath(destinationDir) != nil else {
            throw SyncError.invalidMove("Invalid destination folder: \(destinationDir)")
        }
        let destDir = Self.normalize(destinationDir)
        suppress(for: 2.0)
        paused = true
        defer { paused = false; schedulePendingResync() }

        let remoteDestDir = join(connection.remotePath, destDir)
        try fm.createDirectory(atPath: remoteDestDir, withIntermediateDirectories: true)

        // Plan file-level jobs so a big folder reports real progress.
        var jobs: [(sourcePath: String, destRel: String, displayName: String)] = []
        // Two dropped items can share a name; reserve names before either copy
        // runs, otherwise both would target the same destination.
        var reservedNames = Set<String>()

        for sourceURL in sourceURLs {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }

            let sourcePath = sourceURL.path
            guard fm.fileExists(atPath: sourcePath) else { continue }

            let preferredName = sourceURL.lastPathComponent
            guard !preferredName.isEmpty, !Self.isInternalImportName(preferredName) else { continue }

            let uniqueName = Self.uniqueChildName(
                preferred: preferredName,
                inDirectory: remoteDestDir,
                reserved: reservedNames,
                fm: fm
            )
            reservedNames.insert(uniqueName.lowercased())
            let topRel = destDir.isEmpty ? uniqueName : "\(destDir)/\(uniqueName)"

            var isDir: ObjCBool = false
            fm.fileExists(atPath: sourcePath, isDirectory: &isDir)

            if isDir.boolValue {
                let nested = try Self.enumerateFiles(at: sourcePath, relativeTo: sourcePath)
                if nested.isEmpty {
                    // Empty folder — create it and count as one step.
                    jobs.append((sourcePath, topRel, uniqueName + "/"))
                } else {
                    for (absPath, relInside) in nested {
                        let destRel = "\(topRel)/\(relInside)"
                        jobs.append((absPath, destRel, (destRel as NSString).lastPathComponent))
                    }
                }
            } else {
                jobs.append((sourcePath, topRel, uniqueName))
            }
        }

        let total = jobs.count
        guard total > 0 else {
            onProgress?(1, 1, "—")
            return
        }
        onProgress?(0, total, jobs[0].displayName)

        for (index, job) in jobs.enumerated() {
            try Task.checkCancellation()

            let remoteTo = join(connection.remotePath, job.destRel)
            let parentRemote = (remoteTo as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: parentRemote, withIntermediateDirectories: true)

            var isDir: ObjCBool = false
            fm.fileExists(atPath: job.sourcePath, isDirectory: &isDir)

            if isDir.boolValue {
                try fm.createDirectory(atPath: remoteTo, withIntermediateDirectories: true)
                if shouldKeepLocal(job.destRel) {
                    let localTo = join(connection.localPath, job.destRel)
                    try fm.createDirectory(atPath: localTo, withIntermediateDirectories: true)
                }
            } else {
                await cooperateWithUI(transferGap: true)
                try await copyPath(from: job.sourcePath, to: remoteTo, direction: "import→remote")
                if shouldKeepLocal(job.destRel) {
                    let localTo = join(connection.localPath, job.destRel)
                    try await copyPath(from: job.sourcePath, to: localTo, direction: "import→local")
                }
            }

            let done = index + 1
            onProgress?(done, total, job.displayName)
            emit(.init(
                kind: .progress,
                message: "Uploading \(done) of \(total) · \(job.displayName)",
                path: job.destRel,
                progressDone: done,
                progressTotal: total,
                isTransfer: true
            ))

            await cooperateWithUI(transferGap: true)
        }
    }

    /// Internal state and interrupted-copy scratch files are never user content.
    nonisolated private static func isInternalImportName(_ name: String) -> Bool {
        name == ".DS_Store"
            || name == TrashStore.folderName
            || name == ".tethwork-sync-state.json"
            || name == ".tethwork-verification-cache.json"
            || name == ".tethwork-tombstones.json"
            || name.hasPrefix(".tethwork-copy-")
            || name.hasPrefix(".tethwork-backup-")
            || name.hasPrefix(".tethwork-trash-cleanup-")
    }

    /// Flat list of files under `root` as (absolutePath, pathRelativeToRoot).
    /// Hidden files are included: dropping a folder must not silently lose a
    /// `.env` or `.gitignore` that lives inside it.
    nonisolated private static func enumerateFiles(
        at root: String,
        relativeTo base: String
    ) throws -> [(String, String)] {
        let fm = FileManager.default
        let canonicalBase = canonicalPath(base)
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: canonicalPath(root)),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else { return [] }

        var result: [(String, String)] = []
        for case let url as URL in enumerator {
            let values = try readResourceValues(url, keys: [.isRegularFileKey, .isDirectoryKey])
            let abs = url.path
            let comparable = canonicalPath(abs)
            var rel = comparable
            if comparable.hasPrefix(canonicalBase + "/") {
                rel = String(comparable.dropFirst(canonicalBase.count + 1))
            } else if comparable == canonicalBase {
                continue
            } else {
                throw SyncError.invalidMove("Import path is outside the selected folder: \(abs)")
            }
            let components = rel.split(separator: "/").map(String.init)
            guard !components.contains(where: isInternalImportName) else {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw SyncError.invalidMove("Cannot import a symbolic link or unsupported file: \(rel)")
            }
            result.append((abs, rel))
        }
        return result
    }

    /// Avoids overwriting: `file.txt` → `file 2.txt` → `file 3.txt`…
    nonisolated private static func uniqueChildName(
        preferred: String,
        inDirectory directory: String,
        reserved: Set<String> = [],
        fm: FileManager
    ) -> String {
        let candidate = (directory as NSString).appendingPathComponent(preferred)
        guard fm.fileExists(atPath: candidate) || reserved.contains(preferred.lowercased()) else {
            return preferred
        }

        let ns = preferred as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let stem = base.isEmpty ? preferred : base

        var index = 2
        while true {
            let name: String
            if ext.isEmpty {
                name = "\(stem) \(index)"
            } else {
                name = "\(stem) \(index).\(ext)"
            }
            let path = (directory as NSString).appendingPathComponent(name)
            if !fm.fileExists(atPath: path), !reserved.contains(name.lowercased()) { return name }
            index += 1
        }
    }

    func listDirectory(relativePath: String, includeHidden: Bool = false,
                       includeUnpinnedLocal: Bool = false) async throws -> DirectoryListing {
        guard let connection else { throw SyncError.notConnected }
        let epoch = connectionEpoch
        uiHoldCount += 1
        defer { if epoch == connectionEpoch { uiHoldCount = max(0, uiHoldCount - 1) } }

        let normalized = Self.normalize(relativePath)
        let remoteRoot = connection.remotePath
        let localRoot = connection.localPath
        let pins = pinnedPaths
        let includeLocal = initialMergePending || includeUnpinnedLocal
        let directories = pinnedDirectories
        let verified = verifiedPairs
        let states = displayedFolderStates
        let storageVersion = storageGeneration

        // High-priority listing off the actor so it can run while a sync copy is in flight,
        // and uiHoldCount makes sync wait before starting the next transfer.
        let id = UUID()
        let task = Task.detached(priority: .userInitiated) {
            try Self.buildListing(
                relativePath: normalized,
                remoteRoot: remoteRoot,
                localRoot: localRoot,
                pinnedPaths: pins,
                pinnedDirectories: directories,
                includeHidden: includeHidden,
                includeUnpinnedLocal: includeLocal,
                verifiedPairs: verified,
                folderStates: states,
                storageGeneration: storageVersion
            )
        }
        listingTasks[id] = task
        defer { listingTasks.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard epoch == connectionEpoch else { throw CancellationError() }
        let verificationChanged = result.allEntries.contains {
            !$0.isDirectory && verified[$0.relativePath] != verifiedPairs[$0.relativePath]
        }
        if storageVersion == storageGeneration, !verificationChanged {
            recordStorageScan(result, path: normalized)
        } else if storageQueued.insert(normalized).inserted {
            // A transfer invalidated this listing while its I/O was in flight.
            // Recheck it in the background instead of requiring another visit.
            if storageVersion == storageGeneration {
                storageScans.removeValue(forKey: normalized)
                folderStates.removeValue(forKey: normalized)
            }
            storageQueue.append(normalized)
        }
        startStorageWorker()
        return result.listing
    }

    nonisolated private static func buildListing(
        relativePath normalized: String,
        remoteRoot: String,
        localRoot: String,
        pinnedPaths: Set<String>,
        pinnedDirectories: Set<String>,
        includeHidden: Bool,
        includeUnpinnedLocal: Bool,
        verifiedPairs: [String: VerifiedPair],
        folderStates: [String: FolderStorageState],
        storageGeneration: UInt64
    ) throws -> DirectoryRead {
        let fm = FileManager.default
        let remoteDir = normalized.isEmpty ? remoteRoot : (remoteRoot as NSString).appendingPathComponent(normalized)
        let localDir = normalized.isEmpty ? localRoot : (localRoot as NSString).appendingPathComponent(normalized)

        try validateRemoteRoot(remoteRoot)
        var isDir: ObjCBool = false
        let remoteExists = fm.fileExists(atPath: remoteDir, isDirectory: &isDir) && isDir.boolValue

        // Prefetch directory-entry attributes in bulk. Calling attributesOfItem
        // for each child produces a separate SMB round trip per row on many NASes.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
        // Aggregate all real contents, not only currently visible names. This is
        // still one shallow bulk read; recursive status work runs separately.
        let options: FileManager.DirectoryEnumerationOptions = []
        let children = remoteExists ? try fm.contentsOfDirectory(at: URL(fileURLWithPath: remoteDir),
                                                  includingPropertiesForKeys: Array(keys),
                                                  options: options) : []
        let localChildren = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: localDir),
                                                         includingPropertiesForKeys: Array(keys),
                                                         options: options)) ?? []
        let localExists = fm.fileExists(atPath: localDir, isDirectory: &isDir) && isDir.boolValue
        guard remoteExists || (localExists && (includeUnpinnedLocal || shouldKeepLocal(normalized, pins: pinnedPaths) ||
              pinnedDirectories.contains(normalized))) else {
            throw SyncError.notFound(normalized.isEmpty ? "/" : normalized)
        }
        let localByName = Dictionary(uniqueKeysWithValues: localChildren.map { ($0.lastPathComponent, $0) })

        var entries: [FileEntry] = []
        var hiddenNames = Set<String>()
        entries.reserveCapacity(children.count)
        for child in children {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            if isInternalImportName(name) { continue }
            let rel = normalized.isEmpty ? name : "\(normalized)/\(name)"
            let remoteAbs = (remoteDir as NSString).appendingPathComponent(name)
            let values: URLResourceValues
            do { values = try readResourceValues(child, keys: keys) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                // A concurrent rename/deletion must not fail the whole listing.
                continue
            }
            let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
            let localURL = localByName[name]
            let localValues = localURL.flatMap { try? $0.resourceValues(forKeys: keys) }
            let size = try listingSize(at: child, isSymbolicLink: values.isSymbolicLink == true,
                                       reportedSize: Int64(values.fileSize ?? 0),
                                       pairedIsSymbolicLink: localValues?.isSymbolicLink == true)
            let mtime = values.contentModificationDate ?? .distantPast
            if values.isHidden == true || name.hasPrefix(".") { hiddenNames.insert(name) }
            let localSize = try localURL.flatMap { url in
                try localValues.map { values in
                    try listingSize(at: url, isSymbolicLink: values.isSymbolicLink == true,
                                    reportedSize: Int64(values.fileSize ?? 0))
                }
            }
            let locallyAvailable = localValues?.isDirectory == isDirectory
            let mode: SyncMode = Self.shouldKeepLocal(rel, pins: pinnedPaths) ? .offline : .onlineOnly
            let syncStatus = Self.displayedStatus(mode: mode, isDirectory: isDirectory,
                                                  remoteSize: size, remoteModified: mtime,
                                                  localValues: localValues, verified: verifiedPairs[rel], localSize: localSize)

            entries.append(
                FileEntry(
                    name: name,
                    absolutePath: remoteAbs,
                    relativePath: rel,
                    isDirectory: isDirectory,
                    size: isDirectory ? 0 : size,
                    modified: mtime,
                    syncMode: mode,
                    isLocallyAvailable: locallyAvailable,
                    syncStatus: syncStatus,
                    hasPinnedDescendants: isDirectory && pinnedDirectories.contains(rel),
                    folderStorageState: isDirectory ?
                        (!locallyAvailable ? (mode == .offline || pinnedDirectories.contains(rel) ? .pending : .onlineOnly)
                            : (mode == .offline || pinnedDirectories.contains(rel) ? folderStates[rel] ?? .checking : .onlineOnly)) : nil
                )
            )
        }

        // Adoption uploads asynchronously. Its local-only rows must be visible
        // before the final upload succeeds, and remain visible after a failure.
        let remoteNames = Set(children.map(\.lastPathComponent))
        for child in localChildren where !remoteNames.contains(child.lastPathComponent) {
            let name = child.lastPathComponent
            guard !isInternalImportName(name) else { continue }
            let rel = normalized.isEmpty ? name : "\(normalized)/\(name)"
            guard includeUnpinnedLocal || shouldKeepLocal(rel, pins: pinnedPaths) ||
                    pinnedDirectories.contains(rel) else { continue }
            let values = try readResourceValues(child, keys: keys)
            guard values.isSymbolicLink != true else { continue }
            if values.isHidden == true || name.hasPrefix(".") { hiddenNames.insert(name) }
            entries.append(FileEntry(name: name, absolutePath: child.path, relativePath: rel,
                                     isDirectory: values.isDirectory == true,
                                     size: values.isDirectory == true ? 0 : Int64(values.fileSize ?? 0),
                                     modified: values.contentModificationDate ?? .distantPast,
                                     syncMode: .offline, isLocallyAvailable: true, syncStatus: .pending,
                                     folderStorageState: values.isDirectory == true ? .pending : nil))
        }

        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        var breadcrumbs = [Breadcrumb(name: "Root", path: "")]
        if !normalized.isEmpty {
            var acc = ""
            for part in normalized.split(separator: "/") {
                acc = acc.isEmpty ? String(part) : "\(acc)/\(part)"
                breadcrumbs.append(Breadcrumb(name: String(part), path: acc))
            }
        }

        let visible = includeHidden ? entries : entries.filter { !hiddenNames.contains($0.name) }
        return DirectoryRead(listing: DirectoryListing(relativePath: normalized, entries: visible, breadcrumbs: breadcrumbs,
                                                       storageGeneration: storageGeneration),
                             allEntries: entries, hasLocalDirectory: localExists,
                             isSelected: shouldKeepLocal(normalized, pins: pinnedPaths) || pinnedDirectories.contains(normalized))
    }

    // MARK: - Actual folder contents (display-only; never changes pins)

    private func invalidateFolderStorage(rescan: Bool = true) {
        // Invalidating facts must not discard the work needed to refresh badges
        // already on screen. Include queued children as well as visited folders.
        let paths = rescan ? Set(storageScans.keys).union(storageQueued) : Set<String>()
        storageGeneration &+= 1
        storageWorker?.cancel()
        storageRead?.cancel()
        storageWorker = nil
        storageRead = nil
        for retry in storageRetries.values { retry.cancel() }
        storageRetries.removeAll()
        folderStates.removeAll()
        storageScans.removeAll()
        storageQueue = paths.sorted()
        storageQueueIndex = 0
        storageQueued = paths
        startStorageWorker()
    }

    private func recordStorageScan(_ read: DirectoryRead, path: String) {
        var scan = StorageScan(local: read.hasLocalDirectory, selected: read.isSelected)
        let names = Set(read.allEntries.map(\.name))
        for entry in read.allEntries {
            // Paired AppleDouble files represent Mac metadata for the logical
            // file, not additional online-only user documents on an SMB share.
            if entry.name.hasPrefix("._"), names.contains(String(entry.name.dropFirst(2))) { continue }
            if entry.isDirectory {
                let selected = entry.syncMode == .offline || entry.hasPinnedDescendants
                scan.children.append(StorageChild(path: entry.relativePath, local: entry.isLocallyAvailable,
                                                  selected: selected, pending: entry.syncStatus == .pending))
                if selected, entry.isLocallyAvailable, entry.syncStatus != .pending,
                   folderStates[entry.relativePath] == nil,
                   storageQueued.insert(entry.relativePath).inserted {
                    storageQueue.append(entry.relativePath)
                }
                // Keep directory pending state on the child, not as a sticky
                // file mismatch on its parent. A newer child scan must be able
                // to clear it when the empty directory upload completes.
            } else {
                let complete = entry.syncMode == .offline && entry.isLocallyAvailable && entry.syncStatus == .synced
                scan.allFilesLocal = scan.allFilesLocal && complete
                scan.anyLocalFile = scan.anyLocalFile || (entry.syncMode == .offline && entry.isLocallyAvailable)
                scan.pendingFile = scan.pendingFile || (entry.syncMode == .offline && entry.syncStatus != .synced)
            }
        }
        storageScans[path] = scan
        updateStorageAncestors(from: path)
    }

    private func storageState(for scan: StorageScan) -> FolderStorageState {
        guard scan.local else { return scan.selected ? .pending : .onlineOnly }
        var allLocal = scan.allFilesLocal
        var anyLocal = scan.anyLocalFile
        var pending = scan.pendingFile
        var checking = false
        var unavailable = false
        for child in scan.children {
            let state = folderStates[child.path] ??
                (child.pending ? .pending : (!child.selected ? .onlineOnly : (!child.local ? .pending : .checking)))
            allLocal = allLocal && state == .local
            anyLocal = anyLocal || state == .local || state == .partial
            pending = pending || state == .pending
            checking = checking || state == .checking
            unavailable = unavailable || state == .unavailable
        }
        if unavailable { return .unavailable }
        if pending { return .pending }
        if checking { return .checking }
        if allLocal { return .local }
        return anyLocal ? .partial : .onlineOnly
    }

    private func updateStorageAncestors(from path: String) {
        var current = path
        while let scan = storageScans[current] {
            let state = storageState(for: scan)
            if folderStates[current] != state {
                folderStates[current] = state
                rememberFolderState(state, path: current)
                if !current.isEmpty, state != .checking || lastKnownFolderStates[current] == nil {
                    emit(.init(kind: .storage, message: "", folderStorageState: state, path: current))
                }
            }
            if current.isEmpty { break }
            let parent = (current as NSString).deletingLastPathComponent
            current = parent == "." ? "" : parent
        }
    }

    private func startStorageWorker() {
        guard storageWorker == nil, storageQueueIndex < storageQueue.count,
              connection != nil else { return }
        // The worker waits while transfers/merges hold the share. Start it even
        // during that pause so queued badges resume without another UI listing.
        let generation = storageGeneration
        storageWorker = Task(priority: .utility) { [weak self] in
            await self?.drainStorageQueue(generation: generation)
        }
    }

    private func drainStorageQueue(generation: UInt64) async {
        defer { if generation == storageGeneration { storageWorker = nil; storageRead = nil } }
        while !Task.isCancelled, generation == storageGeneration,
              let connection, storageQueueIndex < storageQueue.count {
            // Foreground browsing gets the share first; only one status directory
            // is read at a time, with no recursive scan in the UI listing path.
            // A global reconciliation may spend minutes verifying unrelated
            // files. It must not block badges for folders already fully local.
            // Yield only to actual copies, foreground browsing and mutations
            // outside reconciliation; generation checks reject stale reads.
            if uiHoldCount > 0 || !copyTasks.isEmpty || (paused && !syncing) || initialMergePending {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                continue
            }
            let path = storageQueue[storageQueueIndex]
            storageQueueIndex += 1
            if storageScans[path] != nil { storageQueued.remove(path); continue }
            let pins = pinnedPaths
            let directories = pinnedDirectories
            let verified = verifiedPairs
            let states = folderStates
            let task = Task.detached(priority: .utility) {
                try Self.buildListing(relativePath: path, remoteRoot: connection.remotePath,
                                      localRoot: connection.localPath, pinnedPaths: pins, pinnedDirectories: directories,
                                      includeHidden: true, includeUnpinnedLocal: false,
                                      verifiedPairs: verified, folderStates: states, storageGeneration: generation)
            }
            storageRead = task
            do {
                let read = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard generation == storageGeneration, !Task.isCancelled else { return }
                if read.allEntries.contains(where: {
                    !$0.isDirectory && verified[$0.relativePath] != verifiedPairs[$0.relativePath]
                }) {
                    // Verification finished while this read was in flight. Do
                    // not cache its obsolete Pending result until the next sync.
                    storageScans.removeValue(forKey: path)
                    folderStates.removeValue(forKey: path)
                    storageQueue.append(path)
                    continue
                }
                recordStorageScan(read, path: path)
            } catch {
                guard generation == storageGeneration, !Task.isCancelled else { return }
                folderStates[path] = .unavailable
                NSLog("Tethwork could not check folder storage at %@: %@", path, error.localizedDescription)
                emit(.init(kind: .storage, message: error.localizedDescription, folderStorageState: .unavailable, path: path))
                let parent = (path as NSString).deletingLastPathComponent
                updateStorageAncestors(from: parent == "." ? "" : parent)
                scheduleStorageRetry(path, generation: generation)
            }
            storageQueued.remove(path)
            do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return }
        }
    }

    /// A transient SMB authentication/remount failure is not a permanent folder
    /// state. Refresh its parent too: the failed directory may have been renamed
    /// or removed while inaccessible. Retrying only the stale path would leave
    /// every ancestor permanently unavailable. This remains a shallow read, not
    /// a new scan of the entire network tree.
    private func scheduleStorageRetry(_ path: String, generation: UInt64) {
        guard storageRetries[path] == nil else { return }
        storageRetries[path] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.retryFolderStorage(path, generation: generation)
        }
    }

    private func retryFolderStorage(_ path: String, generation: UInt64) {
        guard storageGeneration == generation else { return }
        storageRetries.removeValue(forKey: path)
        guard folderStates[path] == .unavailable else { return }
        folderStates.removeValue(forKey: path)
        storageScans.removeValue(forKey: path)
        let parent = (path as NSString).deletingLastPathComponent
        let retryPath = parent == "." ? "" : parent
        storageScans.removeValue(forKey: retryPath)
        // A successful parent listing will enqueue the child again if it still
        // exists, or remove it from the aggregate if it no longer does.
        if storageQueued.insert(retryPath).inserted {
            storageQueue.append(retryPath)
        }
        startStorageWorker()
    }

    /// Bulk SMB reads can expose an XSym container as a regular 1067-byte file,
    /// losing both the link flag and the size returned by reconciliation's lstat.
    /// The local counterpart's link flag also requires a stat of the remote row.
    /// Ordinary file pairs retain inexpensive bulk metadata.
    nonisolated static func listingSize(at url: URL, isSymbolicLink: Bool, reportedSize: Int64,
                                       pairedIsSymbolicLink: Bool = false) throws -> Int64 {
        guard isSymbolicLink || pairedIsSymbolicLink else { return reportedSize }
        return (try readAttributes(at: url.path)[.size] as? NSNumber)?.int64Value ?? reportedSize
    }

    nonisolated private static func displayedStatus(mode: SyncMode, isDirectory: Bool,
                                                    remoteSize: Int64, remoteModified: Date,
                                                    localValues: URLResourceValues?, verified: VerifiedPair?,
                                                    localSize normalizedLocalSize: Int64? = nil) -> SyncStatus {
        if mode == .onlineOnly { return .onlineOnly }
        guard let localValues, localValues.isDirectory == isDirectory else { return .pending }
        if isDirectory { return .synced }
        let localSize = normalizedLocalSize ?? Int64(localValues.fileSize ?? 0)
        let localModified = localValues.contentModificationDate ?? .distantPast
        let matched = verified?.matches(remoteSize: remoteSize, localSize: localSize,
                                        remoteModified: remoteModified, localModified: localModified) == true
        // SMB can represent a symlink as a 1067-byte XSym file while the Mac
        // reports the link target's length. An unchanged, verified pair is
        // authoritative even when these representation sizes differ.
        return matched || (remoteSize == localSize && abs(remoteModified.timeIntervalSince(localModified)) < 0.001)
            ? .synced : .pending
    }

    /// Recursive name search under `relativePath` (includes nested folders).
    /// Calls `onPartial` with growing results so the UI can update before the walk finishes.
    func search(
        query: String,
        under relativePath: String,
        limit: Int = 1000,
        includeHidden: Bool = false,
        onPartial: (@Sendable ([FileEntry]) -> Void)? = nil
    ) async throws -> [FileEntry] {
        guard let connection else { throw SyncError.notConnected }
        let epoch = connectionEpoch
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Pause background sync so the share isn't saturated during search.
        uiHoldCount += 1
        defer { if epoch == connectionEpoch { uiHoldCount = max(0, uiHoldCount - 1) } }

        let normalized = Self.normalize(relativePath)
        let remoteRoot = connection.remotePath
        let localRoot = connection.localPath
        let pins = pinnedPaths
        let verified = verifiedPairs
        let states = displayedFolderStates

        let results = try await Task.detached(priority: .userInitiated) {
            try Self.searchWithEnumerator(
                query: trimmed,
                under: normalized,
                remoteRoot: remoteRoot,
                localRoot: localRoot,
                pinnedPaths: pins,
                verifiedPairs: verified,
                folderStates: states,
                limit: limit,
                includeHidden: includeHidden,
                onPartial: onPartial
            )
        }.value
        guard epoch == connectionEpoch else { throw CancellationError() }
        for entry in results where entry.isDirectory && entry.isLocallyAvailable &&
            (entry.syncMode == .offline || entry.hasPinnedDescendants) {
            if folderStates[entry.relativePath] == nil, storageQueued.insert(entry.relativePath).inserted {
                storageQueue.append(entry.relativePath)
            }
        }
        startStorageWorker()
        return results
    }

    nonisolated private static func searchWithEnumerator(
        query: String,
        under rootRelative: String,
        remoteRoot: String,
        localRoot: String,
        pinnedPaths: Set<String>,
        verifiedPairs: [String: VerifiedPair],
        folderStates: [String: FolderStorageState],
        limit: Int,
        includeHidden: Bool,
        onPartial: (@Sendable ([FileEntry]) -> Void)?
    ) throws -> [FileEntry] {
        let fm = FileManager.default
        let remoteDir = rootRelative.isEmpty
            ? remoteRoot
            : (remoteRoot as NSString).appendingPathComponent(rootRelative)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: remoteDir, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let rootURL = URL(fileURLWithPath: remoteDir, isDirectory: true)
        // No prefetch — only stat matches. Visiting every node is still required to recurse.
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: includeHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let comparableRoot = canonicalPath(remoteDir)
        let rootPrefix = comparableRoot.hasSuffix("/") ? comparableRoot : comparableRoot + "/"
        var results: [FileEntry] = []
        results.reserveCapacity(min(limit, 256))
        var sincePartial = 0
        let pinnedDirectories = Set(watchDirectoryPaths(pins: pinnedPaths, knownPaths: pinnedPaths))

        for case let url as URL in enumerator {
            if results.count >= limit { break }

            let name = url.lastPathComponent
            if isInternalImportName(name) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if !includeHidden && name.hasPrefix(".") { continue }

            // Name-only match first — no extra SMB round-trip for misses.
            guard name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { continue }

            let values = try readResourceValues(url, keys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
            let mtime = values.contentModificationDate ?? Date()

            let absPath = url.path
            let comparable = canonicalPath(absPath)
            let relSuffix: String
            if comparable == comparableRoot {
                continue
            } else if comparable.hasPrefix(rootPrefix) {
                relSuffix = String(comparable.dropFirst(rootPrefix.count))
            } else {
                continue
            }

            let rel = rootRelative.isEmpty
                ? relSuffix
                : "\(rootRelative)/\(relSuffix)"
            let displayName = relSuffix

            let mode: SyncMode = shouldKeepLocal(rel, pins: pinnedPaths) ? .offline : .onlineOnly
            // Only matches need local metadata; keep search badges consistent
            // with the regular listing instead of assuming every pin is present.
            let localURL = URL(fileURLWithPath: (localRoot as NSString).appendingPathComponent(rel))
            let localValues = try? localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            let size = try listingSize(at: url, isSymbolicLink: values.isSymbolicLink == true,
                                       reportedSize: Int64(values.fileSize ?? 0),
                                       pairedIsSymbolicLink: localValues?.isSymbolicLink == true)
            let localSize = try localValues.map { values in
                try listingSize(at: localURL, isSymbolicLink: values.isSymbolicLink == true,
                                reportedSize: Int64(values.fileSize ?? 0))
            }
            let status = displayedStatus(mode: mode, isDirectory: isDirectory, remoteSize: size,
                                         remoteModified: mtime, localValues: localValues, verified: verifiedPairs[rel], localSize: localSize)

            results.append(
                FileEntry(
                    name: displayName,
                    absolutePath: absPath,
                    relativePath: rel,
                    isDirectory: isDirectory,
                    size: isDirectory ? 0 : size,
                    modified: mtime,
                    syncMode: mode,
                    isLocallyAvailable: localValues?.isDirectory == isDirectory,
                    syncStatus: status,
                    hasPinnedDescendants: isDirectory && pinnedDirectories.contains(rel),
                    folderStorageState: isDirectory ?
                        (mode == .offline || pinnedDirectories.contains(rel)
                            ? (localValues?.isDirectory == true ? folderStates[rel] ?? .checking : .pending)
                            : .onlineOnly) : nil
                )
            )
            sincePartial += 1

            if let onPartial, sincePartial >= 24 {
                onPartial(results)
                sincePartial = 0
            }
        }

        results.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        onPartial?(results)
        return results
    }

    nonisolated private static func shouldKeepLocal(_ relativePath: String, pins: Set<String>) -> Bool {
        if pins.contains("") { return true }
        var path = normalize(relativePath)
        while !path.isEmpty && path != "." {
            if pins.contains(path) { return true }
            path = (path as NSString).deletingLastPathComponent
        }
        return false
    }

    // MARK: - Tree sync

    /// Yield to UI listings and pace SMB so browsing stays usable during sync.
    private func cooperateWithUI(transferGap: Bool) async {
        var waited = false
        var maxWaits = 250 // 250 × 40 ms = 10 s max; guards against a hung listDirectory
        while uiHoldCount > 0, maxWaits > 0 {
            waited = true
            maxWaits -= 1
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        if waited {
            // Nested column / outline loads often come in bursts.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await Task.yield()
        // Only pace transfers while someone is actively browsing right now — otherwise
        // a bulk upload/download would lose minutes to gaps nobody benefits from.
        guard uiHoldCount > 0 else { return }
        if transferGap {
            try? await Task.sleep(nanoseconds: syncTransferGapNs)
        } else {
            try? await Task.sleep(nanoseconds: syncMetadataGapNs)
        }
    }

    private func syncTree(_ relativePath: String) async throws {
        let epoch = connectionEpoch
        let revision = syncRevision
        await cooperateWithUI(transferGap: false)
        guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
        guard let connection else { return }
        try validateUserPath(relativePath, connection: connection)
        let remote = join(connection.remotePath, relativePath)
        let local = join(connection.localPath, relativePath)

        let remoteExists = try Self.itemExistsWithoutFollowingLink(remote)
        let localExists = try Self.itemExistsWithoutFollowingLink(local)

        if !remoteExists && !localExists { return }

        // Never interpret an unavailable root as a request to erase the other root.
        if relativePath.isEmpty, !remoteExists {
            throw SyncError.remoteUnavailable(connection.remotePath)
        }

        if remoteExists && !localExists {
            if !relativePath.isEmpty,
               shouldKeepLocal(relativePath),
               knownSyncedPaths.contains(relativePath) {
                // Only propagate disappearance of previously synchronized content.
                // Failed access to the local root/parent must never erase remote data.
                try validateLocalDeletion(relativePath, connection: connection)
                // The user deleted the local copy in Finder: keep the deletion
                // recoverable by moving the remote item to Trash instead of
                // removing it permanently.
                let wasPinned = shouldKeepLocal(relativePath)
                _ = try await Task.detached(priority: .utility) {
                    try TrashStore.moveToTrash(
                        relativePath: relativePath,
                        remoteRoot: connection.remotePath,
                        wasPinned: wasPinned,
                        origin: .local
                    )
                }.value
                guard epoch == connectionEpoch, revision == syncRevision else { throw CancellationError() }
                removeKnownPath(relativePath)
                persistSyncState()
                let name = (relativePath as NSString).lastPathComponent
                emit(.init(
                    kind: .trash,
                    message: "Moved to Trash (deleted on this Mac): \(name)",
                    path: relativePath
                ))
                return
            }
            try await materialize(from: remote, to: local, relativePath: relativePath, direction: "remote→local")
            return
        }
        if localExists && !remoteExists {
            // Another Mac deleted this path and it is still recoverable from the
            // shared Trash. Uploading the stale local copy would resurrect it on
            // every machine, so drop the local copy instead.
            if try await wasDeletedRemotely(relativePath) {
                try forgetTrashedLocalCopy(local, relativePath: relativePath)
                return
            }
            try await materialize(from: local, to: remote, relativePath: relativePath, direction: "local→remote")
            return
        }

        let rAttrs = try Self.readAttributes(at: remote)
        let lAttrs = try Self.readAttributes(at: local)
        let rIsDir = (rAttrs[.type] as? FileAttributeType) == .typeDirectory
        let lIsDir = (lAttrs[.type] as? FileAttributeType) == .typeDirectory

        let rIsLink = (rAttrs[.type] as? FileAttributeType) == .typeSymbolicLink
        let lIsLink = (lAttrs[.type] as? FileAttributeType) == .typeSymbolicLink
        if rIsLink || lIsLink {
            // Some SMB servers expose the uploaded link as a regular XSym
            // container. Its verified size is different, but it is still the
            // same unchanged pair; do not upload it on every reconciliation.
            if verifiedPairs[relativePath]?.matches(remote: rAttrs, local: lAttrs) == true {
                noteMatchedFile()
                return
            }
            if rIsLink && lIsLink {
                if let remoteTarget = try? fm.destinationOfSymbolicLink(atPath: remote),
                   let localTarget = try? fm.destinationOfSymbolicLink(atPath: local), remoteTarget == localTarget {
                    try recordComparedPair(relativePath, remote: remote, local: local,
                                           remoteBefore: rAttrs, localBefore: lAttrs)
                    noteMatchedFile()
                    return
                }
            }
            // Compare link text, never target contents. If SMB cannot read an old
            // link, let the same last-write-wins copy path replace it atomically.
            let remoteWins = ((rAttrs[.modificationDate] as? Date) ?? .distantPast) >
                ((lAttrs[.modificationDate] as? Date) ?? .distantPast)
            if rIsDir || lIsDir {
                try await replacePathAtomically(from: remoteWins ? remote : local, to: remoteWins ? local : remote,
                                                relativePath: relativePath, direction: remoteWins ? "remote→local" : "local→remote")
            } else {
                try await transferFile(from: remoteWins ? remote : local, to: remoteWins ? local : remote,
                                       relativePath: relativePath, direction: remoteWins ? "remote→local" : "local→remote")
            }
            return
        }

        if rIsDir && lIsDir {
            let remoteNames = Set(try fm.contentsOfDirectory(atPath: remote).filter { !Self.isInternalImportName($0) })
            let localNames = Set(try fm.contentsOfDirectory(atPath: local).filter { !Self.isInternalImportName($0) })
            for name in remoteNames.union(localNames) {
                guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
                let child = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                if shouldKeepLocal(relativePath) || shouldKeepLocal(child) || hasPinnedDescendant(child) {
                    try await syncTree(child)
                }
            }
            return
        }

        if !rIsDir && !lIsDir {
            if verifiedPairs[relativePath]?.matches(remote: rAttrs, local: lAttrs) == true {
                noteMatchedFile()
                return
            }
            emit(.init(kind: .progress, message: "Checking: \((relativePath as NSString).lastPathComponent)",
                       path: relativePath, progressDone: syncTransferDone,
                       progressTotal: transferTotalKnown ? syncTransferTotal : nil,
                       isTransfer: true, phase: .checking))
            let rSize = (rAttrs[.size] as? NSNumber)?.int64Value ?? 0
            let lSize = (lAttrs[.size] as? NSNumber)?.int64Value ?? 0
            let rM = (rAttrs[.modificationDate] as? Date) ?? .distantPast
            let lM = (lAttrs[.modificationDate] as? Date) ?? .distantPast
            if rSize == lSize {
                let timestampsClose = abs(rM.timeIntervalSince(lM)) < 3
                if timestampsClose, try await Self.filesHaveEqualContents(remote, local) {
                    guard epoch == connectionEpoch, revision == syncRevision else { throw CancellationError() }
                    try recordComparedPair(relativePath, remote: remote, local: local,
                                           remoteBefore: rAttrs, localBefore: lAttrs)
                    noteMatchedFile()
                    await cooperateWithUI(transferGap: false)
                    return
                }
            }
            try await transferFile(
                from: rM > lM ? remote : local,
                to: rM > lM ? local : remote,
                relativePath: relativePath,
                direction: rM > lM ? "remote→local" : "local→remote"
            )
            return
        }

        // A path cannot be a file on one side and a directory on the other.
        // Stage the winning tree next to the destination and swap only after the
        // complete copy succeeds, so a failed network copy preserves both versions.
        let rM = (rAttrs[.modificationDate] as? Date) ?? .distantPast
        let lM = (lAttrs[.modificationDate] as? Date) ?? .distantPast
        let remoteWins = rM >= lM
        try await replacePathAtomically(
            from: remoteWins ? remote : local,
            to: remoteWins ? local : remote,
            relativePath: relativePath,
            direction: remoteWins ? "remote→local" : "local→remote"
        )
    }

    /// Copy a missing tree file-by-file so progress stays accurate.
    private func materialize(
        from: String,
        to: String,
        relativePath: String,
        direction: String
    ) async throws {
        if let connection { try validateUserPath(relativePath, connection: connection) }
        let epoch = connectionEpoch
        let revision = syncRevision
        await cooperateWithUI(transferGap: false)
        guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
        if direction == "local→remote", let connection {
            try Self.validateRemoteRoot(connection.remotePath)
            if try await wasDeletedRemotely(relativePath) {
                try forgetTrashedLocalCopy(from, relativePath: relativePath)
                return
            }
        }
        let sourceType = try Self.readAttributes(at: from)[.type] as? FileAttributeType
        let destinationExists = try Self.itemExistsWithoutFollowingLink(to)
        let destinationType = destinationExists ? try Self.readAttributes(at: to)[.type] as? FileAttributeType : nil
        if destinationExists,
           sourceType == .typeSymbolicLink || destinationType == .typeSymbolicLink {
            try await syncTree(relativePath)
            return
        }
        if sourceType == .typeDirectory {
            try fm.createDirectory(atPath: to, withIntermediateDirectories: true)
            knownSyncedPaths.insert(relativePath)
            if !transferTotalKnown {
                emit(.init(kind: .progress, message: "Opening folder: \(relativePath.isEmpty ? "/" : relativePath)",
                           path: relativePath, progressDone: syncTransferDone, isTransfer: true,
                           transferDirection: direction == "local→remote" ? .upload : .download, phase: .preparing))
            }
            let names = try await Task.detached(priority: .utility) {
                try FileManager.default.contentsOfDirectory(atPath: from)
                    .filter { !Self.isInternalImportName($0) }.sorted()
            }.value
            guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
            for name in names {
                guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
                let child = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                try await materialize(
                    from: join(from, name),
                    to: join(to, name),
                    relativePath: child,
                    direction: direction
                )
            }
            if direction == "remote→local" {
                guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
                // Preserve the previous bidirectional behavior without scheduling
                // another count/scan of every pinned folder after this download.
                let remoteNames = Set(names)
                let localOnly = try fm.contentsOfDirectory(atPath: to)
                    .filter { !Self.isInternalImportName($0) && !remoteNames.contains($0) }.sorted()
                for name in localOnly {
                    guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
                    let child = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                    try await materialize(from: join(to, name), to: join(from, name),
                                          relativePath: child, direction: "local→remote")
                }
            }
            return
        }

        // The destination may already hold a file here (e.g. local files that predate
        // pinning this folder for the first time) — reconcile instead of blindly
        // overwriting: keep whichever side is newer, or skip if they already match.
        if !transferTotalKnown {
            emit(.init(kind: .progress, message: "Checking local copy: \((relativePath as NSString).lastPathComponent)",
                       path: relativePath, progressDone: syncTransferDone, isTransfer: true,
                       transferDirection: direction == "local→remote" ? .upload : .download, phase: .checking))
        }
        if fm.fileExists(atPath: to),
           let fromAttrs = try? fm.attributesOfItem(atPath: from),
           let toAttrs = try? fm.attributesOfItem(atPath: to) {
            let fromSize = (fromAttrs[.size] as? NSNumber)?.int64Value ?? 0
            let toSize = (toAttrs[.size] as? NSNumber)?.int64Value ?? 0
            let fromM = (fromAttrs[.modificationDate] as? Date) ?? .distantPast
            let toM = (toAttrs[.modificationDate] as? Date) ?? .distantPast

            let remoteAttrs = direction == "remote→local" ? fromAttrs : toAttrs
            let localAttrs = direction == "remote→local" ? toAttrs : fromAttrs
            if verifiedPairs[relativePath]?.matches(remote: remoteAttrs, local: localAttrs) == true {
                noteMatchedFile()
                knownSyncedPaths.insert(relativePath)
                return
            }

            if fromSize == toSize,
               abs(fromM.timeIntervalSince(toM)) < 3,
                try await Self.filesHaveEqualContents(from, to) {
                guard epoch == connectionEpoch, revision == syncRevision else { return }
                try recordComparedPair(relativePath,
                                       remote: direction == "remote→local" ? from : to,
                                       local: direction == "remote→local" ? to : from,
                                       remoteBefore: remoteAttrs, localBefore: localAttrs)
                noteMatchedFile()
                knownSyncedPaths.insert(relativePath)
                return
            }
            if toM > fromM {
                let reversedDirection = direction == "remote→local" ? "local→remote" : "remote→local"
                try await transferFile(from: to, to: from, relativePath: relativePath, direction: reversedDirection)
                if epoch == connectionEpoch, revision == syncRevision { knownSyncedPaths.insert(relativePath) }
                return
            }
        }

        try await transferFile(from: from, to: to, relativePath: relativePath, direction: direction)
        if epoch == connectionEpoch, revision == syncRevision { knownSyncedPaths.insert(relativePath) }
    }

    /// Real mismatch / missing copy — the only path that reports “Syncing”.
    private func transferFile(
        from: String,
        to: String,
        relativePath: String,
        direction: String
    ) async throws {
        let epoch = connectionEpoch
        let revision = syncRevision
        await cooperateWithUI(transferGap: true)
        guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
        if syncTransferTotal < syncTransferDone + 1 {
            syncTransferTotal = syncTransferDone + 1
        }
        emitTransferProgress(path: relativePath, direction: direction.contains("local→remote") ? .upload : .download)
        let warning = overwriteWarning(from: from, to: to, relativePath: relativePath, direction: direction)
        let byteCount = Self.fileSize(at: from)
        let startedAt = ContinuousClock.now
        try await copyPath(from: from, to: to, direction: direction, relativePath: relativePath, emitFile: false)
        guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
        try await verifyCopiedPairIfNeeded(relativePath)
        guard epoch == connectionEpoch, revision == syncRevision else { return }
        reportOverwrite(warning)
        let elapsed = startedAt.duration(to: .now)
        syncTransferDone += 1
        syncProgressDone += 1
        emitTransferProgress(
            path: relativePath,
            bytesPerSecond: Self.bytesPerSecond(byteCount: byteCount, elapsed: elapsed),
            direction: direction.contains("local→remote") ? .upload : .download
        )
        await cooperateWithUI(transferGap: true)
    }

    private func hasPinnedDescendant(_ relativePath: String) -> Bool {
        if relativePath.isEmpty { return pinnedPaths.count > (pinnedPaths.contains("") ? 1 : 0) }
        return pinnedDirectories.contains(relativePath)
    }

    /// SMB timestamp rounding can differ from the local filesystem even after a
    /// successful copy. Verify bytes in that case rather than displaying a
    /// permanent pending badge or treating every close timestamp as synchronized.
    private func verifyCopiedPairIfNeeded(_ path: String) async throws {
        guard let connection else { throw CancellationError() }
        let epoch = connectionEpoch
        let revision = syncRevision
        let remote = join(connection.remotePath, path)
        let local = join(connection.localPath, path)
        let verified: VerifiedPair = try await Task.detached(priority: .utility) {
            let remoteAttributes = try Self.readAttributes(at: remote)
            let localAttributes = try Self.readAttributes(at: local)
            let pair = VerifiedPair(remote: remoteAttributes, local: localAttributes)
            if (remoteAttributes[.type] as? FileAttributeType) == .typeSymbolicLink,
               (localAttributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                // The copy operation copied the link itself. SMB may expose lstat
                // but not readlink; never open the target as a regular file here.
                return pair
            }
            // The copy routine validates source stability and destination size.
            // Only timestamp rounding needs an extra byte comparison here.
            if abs(pair.remoteModified.timeIntervalSince(pair.localModified)) < 0.001 { return pair }
            guard pair.remoteSize == pair.localSize,
                  try await Self.filesHaveEqualContents(remote, local) else {
                throw SyncError.invalidMove("A file changed immediately after copying: \(path). Retry synchronization.")
            }
            guard pair.matches(remote: try Self.readAttributes(at: remote), local: try Self.readAttributes(at: local)) else {
                throw SyncError.invalidMove("A file changed during verification: \(path). Retry synchronization.")
            }
            return pair
        }.value
        guard epoch == connectionEpoch, revision == syncRevision else { throw CancellationError() }
        recordVerifiedPair(verified, path: path)
    }

    private func downloadTreeWithProgress(_ relativePath: String) async throws {
        guard let connection else { throw SyncError.notConnected }
        try Self.validateRemoteRoot(connection.remotePath)
        let remote = join(connection.remotePath, relativePath)
        let local = join(connection.localPath, relativePath)
        guard fm.fileExists(atPath: remote) else { throw SyncError.notFound(relativePath) }

        syncTransferDone = 0
        syncTransferTotal = 0
        syncProgressDone = 0
        transferTotalKnown = false
        lastProgressEmission = nil
        progressPhases.removeAll()
        // Stream the first files immediately. Counting the whole NAS tree first
        // can take minutes and used to leave the UI showing only "Downloading".
        try await materialize(from: remote, to: local, relativePath: relativePath, direction: "remote→local")
    }

    private func noteMatchedFile() {
        syncProgressDone += 1
        // No “Syncing” status — file already matches where it should.
    }

    private func emitTransferProgress(
        path: String,
        bytesPerSecond: Double? = nil,
        direction: SyncEvent.TransferDirection? = nil
    ) {
        let name = (path as NSString).lastPathComponent
        let total = max(syncTransferTotal, 1)
        let done = min(syncTransferDone, total)
        let percent = Int((Double(done) / Double(total) * 100).rounded())
        let message: String
        if !transferTotalKnown {
            message = "Transferred \(syncTransferDone) files\(name.isEmpty ? "" : " · \(name)")"
        } else if name.isEmpty {
            message = "Syncing \(done) of \(total) · \(percent)%"
        } else {
            message = "Syncing \(done) of \(total) · \(percent)% · \(name)"
        }
        emit(.init(
            kind: .progress,
            message: message,
            path: path,
            progressDone: syncTransferDone,
            progressTotal: transferTotalKnown ? syncTransferTotal : nil,
            isTransfer: true,
            bytesPerSecond: bytesPerSecond,
            transferDirection: direction,
            phase: .transferring
        ))
    }

    private func removeLocalTree(_ relativePath: String) async throws {
        guard let connection else { return }
        let local = join(connection.localPath, relativePath)

        if relativePath.isEmpty {
            let entries = try fm.contentsOfDirectory(atPath: local)
            for name in entries where !Self.isInternalImportName(name) {
                if !shouldKeepLocal(name) && !hasPinnedDescendant(name) {
                    try fm.removeItem(atPath: join(local, name))
                }
            }
            return
        }

        guard fm.fileExists(atPath: local) else { return }

        if hasPinnedDescendant(relativePath) {
            let entries = try fm.contentsOfDirectory(atPath: local)
            for name in entries {
                let child = "\(relativePath)/\(name)"
                if !shouldKeepLocal(child) && !hasPinnedDescendant(child) {
                    try fm.removeItem(atPath: join(local, name))
                }
            }
            return
        }

        try fm.removeItem(atPath: local)
    }

    private func copyPath(
        from: String,
        to: String,
        direction: String,
        relativePath: String? = nil,
        emitFile: Bool = true
    ) async throws {
        suppress(for: 1.5)
        let byteCount = Self.fileSize(at: from)
        let startedAt = ContinuousClock.now
        let transferDirection: SyncEvent.TransferDirection? = direction.contains("→remote") ? .upload
            : (direction.contains("remote→") ? .download : nil)
        // Leave the actor while copying so listDirectory / navigation stay responsive.
        try await performCopy(from: from, to: to, path: relativePath ?? (from as NSString).lastPathComponent,
                              direction: transferDirection)
        if emitFile {
            let name = (from as NSString).lastPathComponent
            emit(.init(
                kind: .file,
                message: "\(direction): \(name)",
                path: relativePath ?? name,
                isTransfer: true,
                bytesPerSecond: Self.bytesPerSecond(
                    byteCount: byteCount,
                    elapsed: startedAt.duration(to: .now)
                ),
                transferDirection: transferDirection
            ))
        }
    }

    nonisolated private static func fileSize(at path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated private static func bytesPerSecond(
        byteCount: Int64,
        elapsed: Duration
    ) -> Double {
        let components = elapsed.components
        let seconds = max(
            Double(components.seconds) + Double(components.attoseconds) / 1e18,
            0.001
        )
        return Double(byteCount) / seconds
    }

    private func replacePathAtomically(
        from: String,
        to: String,
        relativePath: String,
        direction: String
    ) async throws {
        await cooperateWithUI(transferGap: true)
        let warning = overwriteWarning(from: from, to: to, relativePath: relativePath, direction: direction)
        emit(.init(kind: .file, message: "\(direction): \((from as NSString).lastPathComponent)", path: relativePath))
        try await performCopy(from: from, to: to, path: relativePath,
                              direction: direction.contains("local→remote") ? .upload : .download)
        reportOverwrite(warning)
        syncTransferDone += 1
        syncProgressDone += 1
    }

    private func stopTransfers() async {
        syncRevision &+= 1
        transferTotalKnown = true
        paused = true
        syncing = false
        let tasks = Array(copyTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.result }
    }

    private func performCopy(from: String, to: String, path: String, direction: SyncEvent.TransferDirection?) async throws {
        let id = UUID()
        let revision = syncRevision
        let remoteRoot = connection?.remotePath
        let task = Task { [weak self] in
            try await Self.copyItemOffActor(from: from, to: to, remoteRoot: remoteRoot) { [weak self] rate in
                guard let direction else { return }
                Task { await self?.reportCopyRate(rate, copyID: id, revision: revision, path: path, direction: direction) }
            }
        }
        copyTasks[id] = task
        defer { copyTasks.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard revision == syncRevision else { throw CancellationError() }
    }

    private func reportCopyRate(_ rate: Double, copyID: UUID, revision: UInt64, path: String,
                                direction: SyncEvent.TransferDirection) {
        guard syncRevision == revision, copyTasks[copyID] != nil else { return }
        emitTransferProgress(path: path, bytesPerSecond: rate, direction: direction)
    }

    nonisolated private static func copyItemOffActor(from: String, to: String, remoteRoot: String?,
                                                    onTransferRate: @escaping @Sendable (Double) -> Void) async throws {
        let task = Task.detached(priority: .background) {
            try Task.checkCancellation()
            if let remoteRoot { try validateRemoteRoot(remoteRoot) }
            let fm = FileManager.default
            let parent = (to as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            let temporary = (parent as NSString).appendingPathComponent(
                ".tethwork-copy-\(UUID().uuidString)"
            )
            defer { try? fm.removeItem(atPath: temporary) }

            var rateMeter = TransferRateMeter()
            try copyCancellably(from: from, to: temporary, fm: fm) { count in
                if let rate = rateMeter.record(bytes: count) { onTransferRate(rate) }
            }
            try Task.checkCancellation()
            let temporaryURL = URL(fileURLWithPath: temporary)
            let destinationURL = URL(fileURLWithPath: to)
            if let remoteRoot { try validateRemoteRoot(remoteRoot) }
            let sourceType = try fm.attributesOfItem(atPath: temporary)[.type] as? FileAttributeType
            let destinationExists = try itemExistsWithoutFollowingLink(to)
            let destinationType = destinationExists ? try fm.attributesOfItem(atPath: to)[.type] as? FileAttributeType : nil
            if sourceType != .typeDirectory && destinationType != .typeDirectory {
                // rename replaces directory entries, including dangling links,
                // without following targets or requiring SMB metadata exchange.
                if Darwin.rename(temporary, to) != 0 {
                    let code = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                                  userInfo: [NSFilePathErrorKey: to])
                }
            } else if destinationExists {
                // Different node types cannot be replaced by plain rename. Keep a
                // sibling backup until publication succeeds, restoring it on failure.
                let backup = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".tethwork-backup-\(UUID().uuidString)")
                try fm.moveItem(at: destinationURL, to: backup)
                do {
                    try fm.moveItem(at: temporaryURL, to: destinationURL)
                } catch {
                    try fm.moveItem(at: backup, to: destinationURL)
                    throw error
                }
                try? fm.removeItem(at: backup)
            } else {
                try fm.moveItem(at: temporaryURL, to: destinationURL)
            }
            if let rate = rateMeter.flush() { onTransferRate(rate) }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw transferFailure(error, from: from, to: to, operation: "Copy synchronized file")
        }
    }

    /// Bounded memory and cancellation between chunks, including directory copies.
    nonisolated private static func copyCancellably(from: String, to: String, fm: FileManager,
                                                  onBytes: ((Int) -> Void)? = nil) throws {
        try Task.checkCancellation()
        let attributes = try readAttributes(at: from)
        let type = attributes[.type] as? FileAttributeType
        if type == .typeDirectory {
            try fm.createDirectory(atPath: to, withIntermediateDirectories: false)
            for name in try fm.contentsOfDirectory(atPath: from) {
                try copyCancellably(from: (from as NSString).appendingPathComponent(name),
                                    to: (to as NSString).appendingPathComponent(name), fm: fm, onBytes: onBytes)
            }
        } else if type == .typeRegular {
            let input = try Self.openRegularFileForReading(from)
            defer { Darwin.close(input.descriptor) }
            let descriptor = Darwin.open(to, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: to])
            }
            defer { Darwin.close(descriptor) }
            var copied: Int64 = 0
            let chunkSize = Int(min(1024 * 1024, max(1, input.size)))
            while true {
                try Task.checkCancellation()
                let chunk = try readFileChunk(descriptor: input.descriptor, path: from, maximumCount: chunkSize)
                if chunk.isEmpty { break }
                try writeFileChunk(chunk, descriptor: descriptor, path: to)
                copied += Int64(chunk.count)
                onBytes?(chunk.count)
                if copied > input.size {
                    throw SyncError.invalidMove("Source grew during copy: \(from). Retry synchronization.")
                }
            }
            while Darwin.fsync(descriptor) != 0 {
                let code = errno
                if code == EINTR { try Task.checkCancellation(); continue }
                throw posixFileError(code, path: to, operation: "Flush copied file")
            }
            let after = try readAttributes(at: from)
            guard copied == (attributes[.size] as? NSNumber)?.int64Value,
                  copied == (after[.size] as? NSNumber)?.int64Value,
                  (attributes[.modificationDate] as? Date) == (after[.modificationDate] as? Date),
                  copied == fileSize(at: to) else {
                throw SyncError.invalidMove("Source changed during copy: \(from). Retry synchronization.")
            }
            // Preserve resource forks, extended attributes and permissions without
            // copying the data a second time.
            if copyfile(from, to, nil, copyfile_flags_t(COPYFILE_METADATA)) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: to])
            }
        } else if type == .typeSymbolicLink {
            try fm.copyItem(atPath: from, toPath: to)
            let after = try readAttributes(at: from)
            guard VerifiedPair(remote: attributes, local: attributes).matches(remote: after, local: after) else {
                throw SyncError.invalidMove("Source link changed during copy: \(from). Retry synchronization.")
            }
            return // Never set metadata through a newly copied symbolic link.
        } else {
            throw SyncError.invalidMove("Unsupported file type: \(from)")
        }
        if let date = attributes[.modificationDate] as? Date {
            do { try fm.setAttributes([.modificationDate: date], ofItemAtPath: to) }
            catch { throw transferFailure(error, from: from, to: to, operation: "Set copied file modification time") }
        }
    }

    nonisolated private static func posixFileError(_ code: Int32, path: String, operation: String) -> NSError {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey: "\(operation): \(path)\n\(underlying.localizedDescription) (errno \(code))"
        ])
    }

    nonisolated private static func openRegularFileForReading(_ path: String) throws -> (descriptor: Int32, size: Int64) {
        // Nonblocking open prevents an accidentally selected FIFO/device from
        // hanging synchronization before its type can be checked with fstat.
        var descriptor: Int32 = -1
        while descriptor < 0 {
            try Task.checkCancellation()
            descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if descriptor < 0, errno != EINTR { throw posixFileError(errno, path: path, operation: "Open file for reading") }
        }
        var handedOff = false
        defer { if !handedOff { Darwin.close(descriptor) } }
        var info = stat()
        while Darwin.fstat(descriptor, &info) != 0 {
            let code = errno
            if code == EINTR { try Task.checkCancellation(); continue }
            throw posixFileError(code, path: path, operation: "Read opened file metadata")
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw SyncError.invalidMove("Cannot read a non-regular file for synchronization: \(path)")
        }
        handedOff = true
        return (descriptor, Int64(info.st_size))
    }

    /// Fill a chunk even when the filesystem returns short reads. A short read
    /// is not EOF and must not make identical local/SMB files look different.
    nonisolated static func readFileChunk(descriptor: Int32, path: String, maximumCount: Int = 1024 * 1024,
                                         read: (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) }) throws -> Data {
        guard maximumCount > 0 else { return Data() }
        var result = Data(count: maximumCount)
        let filled = try result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) throws -> Int in
            var offset = 0
            while offset < maximumCount {
                try Task.checkCancellation()
                let count = read(descriptor, bytes.baseAddress!.advanced(by: offset), maximumCount - offset)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw posixFileError(code, path: path, operation: "Read file data")
                }
                if count == 0 { break }
                offset += count
            }
            return offset
        }
        result.count = filled
        return result
    }

    nonisolated private static func writeFileChunk(_ data: Data, descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) throws -> Void in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw posixFileError(code, path: path, operation: "Write copied file data")
                }
                guard count > 0 else { throw posixFileError(EIO, path: path, operation: "Write copied file") }
                offset += count
            }
        }
    }

    nonisolated static func filesHaveEqualContents(_ lhs: String, _ rhs: String) async throws -> Bool {
        let task = Task.detached(priority: .utility) {
            try compareRegularFiles(lhs, rhs)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    nonisolated private static func compareRegularFiles(_ lhs: String, _ rhs: String,
                                                        onBytes: ((Int) -> Void)? = nil) throws -> Bool {
        do {
            let leftFile = try openRegularFileForReading(lhs)
            defer { Darwin.close(leftFile.descriptor) }
            let rightFile = try openRegularFileForReading(rhs)
            defer { Darwin.close(rightFile.descriptor) }
            if leftFile.size != rightFile.size { return false }
            let chunkSize = Int(min(1024 * 1024, max(1, leftFile.size)))
            var compared: Int64 = 0
            while true {
                try Task.checkCancellation()
                let left = try readFileChunk(descriptor: leftFile.descriptor, path: lhs, maximumCount: chunkSize)
                let right = try readFileChunk(descriptor: rightFile.descriptor, path: rhs, maximumCount: chunkSize)
                onBytes?(left.count)
                if left != right { return false }
                if left.isEmpty { return compared == leftFile.size }
                compared += Int64(left.count)
                if compared > leftFile.size { return false }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw transferFailure(error, from: lhs, to: rhs, operation: "Compare synchronized files") }
    }

    // MARK: - Watchers

    private func startWatchers() {
        guard let connection else { return }
        stopWatchers()

        let localRoot = URL(fileURLWithPath: connection.localPath)
        let remoteURLs = remoteWatchURLs(connection: connection)

        let remote = DirectoryWatcher(mode: .polling) { [weak self] _ in
            Task { await self?.handleRemoteRootChange() }
        }
        // A single recursive stream covers the whole local tree. One kernel
        // descriptor per synchronized folder exhausted the process limit on
        // shares with thousands of directories.
        let local = DirectoryWatcher(mode: .recursiveFileEvents) { [weak self] _ in
            Task { await self?.handleLocalRootChange() }
        }

        // Watchers enqueue their own setup, preserving start/stop order without
        // blocking this actor on a slow NAS listing.
        remoteWatcher = remote
        localWatcher = local
        watchedRemotePaths = Set(remoteURLs.map(\.path))
        // SMB rarely delivers kernel events. Back off large background watch
        // sets; the currently visible directory still has its own fast watcher.
        let remoteInterval = min(30, max(1, Double(remoteURLs.count) / 100))
        remote.start(watching: remoteURLs, interval: remoteInterval)
        local.start(watching: [localRoot], interval: 1.0)
    }

    private func stopWatchers() {
        remoteWatcher?.stop()
        localWatcher?.stop()
        remoteWatcher = nil
        localWatcher = nil
        watchedRemotePaths.removeAll()
    }

    /// Re-target remote/local watchers when pins change (nested folders need their own shallow poll).
    private func updateRemoteWatchPaths() {
        guard let connection, let remoteWatcher else { return }
        let remoteURLs = remoteWatchURLs(connection: connection)
        let paths = Set(remoteURLs.map(\.path))
        guard paths != watchedRemotePaths else { return }
        watchedRemotePaths = paths
        remoteWatcher.setWatchedURLs(remoteURLs)
        localWatcher?.setWatchedURLs([URL(fileURLWithPath: connection.localPath)])
    }

    private func remoteWatchURLs(connection: SyncConnection) -> [URL] {
        watchURLs(root: connection.remotePath)
    }

    private func watchURLs(root: String) -> [URL] {
        Self.watchDirectoryPaths(pins: pinnedPaths, knownPaths: knownSyncedPaths).map {
            URL(fileURLWithPath: join(root, $0), isDirectory: true)
        }
    }

    /// Hundreds of individually adopted files in one directory need one watcher,
    /// not hundreds of descriptors and one SMB stat/poll for each file.
    nonisolated static func watchDirectoryPaths(pins: Set<String>, knownPaths: Set<String>) -> [String] {
        var directories: Set<String> = [""]
        for path in pins.union(knownPaths) where !path.isEmpty {
            guard TrashStore.safeRelativePath(path) != nil else { continue }
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." {
                // Every ancestor above an existing parent was already visited.
                guard directories.insert(parent).inserted else { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        // Until the first reconciliation classifies a new pin, keep its direct
        // watch too. Known leaves are observed by their containing directory.
        directories.formUnion(pins.subtracting(knownPaths).filter { !$0.isEmpty && TrashStore.safeRelativePath($0) != nil })
        return directories.sorted()
    }

    private func handleRemoteRootChange() async {
        await reconcileWatcherChange()
    }

    private func handleLocalRootChange() async {
        await reconcileWatcherChange()
    }

    func setAutomaticSyncPaused(_ value: Bool) {
        automaticSyncPaused = value
        if value {
            retryTask?.cancel()
            retryTask = nil
            resyncTask?.cancel()
            resyncTask = nil
            pendingResync = false
        }
    }

    private func reconcileWatcherChange() async {
        guard let connection, !initialMergePending, !automaticSyncPaused else { return }
        // Changes triggered by our own writes are not worth another pass.
        if syncing || paused {
            // Do not drop the event: re-run once the current transfer finishes.
            pendingResync = true
            return
        }
        if Date() < suppressUntil {
            pendingResync = true
            schedulePendingResync()
            return
        }
        guard Date() >= retryNotBefore else {
            if retryTask == nil { scheduleRetry(after: retryNotBefore.timeIntervalSinceNow) }
            return
        }
        pendingResync = false
        let epoch = connectionEpoch
        let revision = syncRevision
        invalidateFolderStorage()
        syncing = true
        paused = true
        defer {
            if revision == syncRevision {
                syncing = false
                paused = false
            }
            schedulePendingResync()
        }
        suppress(for: 0.8)
        syncTransferDone = 0
        syncTransferTotal = 0
        var syncPath = ""
        var syncOperation = "Automatic synchronization"
        do {
            await auditLocalInventory()
            guard epoch == connectionEpoch, revision == syncRevision else { return }
            try Self.validateConnectionSafety(connection, homeDirectory: homeDirectory)
            try Self.validateRemoteRoot(connection.remotePath)
            try reportRemoteRecovery(connection)
            for pin in pinnedPaths.sorted() {
                guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
                syncPath = pin
                try await syncTree(pin)
            }
            guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
            syncPath = ""
            syncOperation = "Refresh automatic synchronization baseline"
            try await refreshPersistedSyncState()
            updateRemoteWatchPaths()
            resetSyncBackoff()
            emit(.init(kind: .complete, message: String(localized: "Ready"), isTransfer: false))
        } catch {
            guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending,
                  !(error is CancellationError) else { return }
            let diagnostic = Self.transferFailure(error, from: join(connection.remotePath, syncPath),
                                                   to: join(connection.localPath, syncPath), operation: syncOperation)
            registerSyncFailure(diagnostic)
            emit(.init(kind: .error, message: diagnostic.localizedDescription,
                       isRemoteUnavailable: Self.isRemoteUnavailableError(error)))
        }
    }

    // MARK: - Automatic retry

    /// Automatic sync keeps retrying with an exponential backoff (capped at one
    /// minute) instead of staying disabled until the user intervenes.
    private func registerSyncFailure(_ error: Error) {
        consecutiveSyncFailures += 1
        let exponent = min(consecutiveSyncFailures - 1, 6)
        let delay = min(pow(2, Double(exponent)), 60)
        retryNotBefore = Date().addingTimeInterval(delay)
        NSLog("Tethwork sync failed (%d in a row), retrying in %.0fs: %@",
              consecutiveSyncFailures, delay, error.localizedDescription)
        scheduleRetry(after: delay)
    }

    /// A manual action succeeded (or was requested): start from a clean slate.
    private func resetSyncBackoff() {
        consecutiveSyncFailures = 0
        retryNotBefore = .distantPast
        retryTask?.cancel()
        retryTask = nil
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = nil
        guard connection != nil, !initialMergePending else { return }
        let epoch = connectionEpoch
        let nanoseconds = UInt64(min(max(delay, 0.5), 60) * 1_000_000_000)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.runScheduledRetry(epoch: epoch)
        }
    }

    private func runScheduledRetry(epoch: UInt64) async {
        guard epoch == connectionEpoch, connection != nil, !initialMergePending else { return }
        retryTask = nil
        guard Date() >= retryNotBefore else {
            scheduleRetry(after: retryNotBefore.timeIntervalSinceNow)
            return
        }
        await reconcileWatcherChange()
    }

    /// Runs one more pass when a watcher fired during a sync (debounced).
    private func schedulePendingResync() {
        guard pendingResync, connection != nil else {
            pendingResync = false
            return
        }
        pendingResync = false
        resyncTask?.cancel()
        let epoch = connectionEpoch
        let revision = syncRevision
        let delay = max(0.4, suppressUntil.timeIntervalSinceNow + 0.1)
        resyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runPendingResync(epoch: epoch, revision: revision)
        }
    }

    private func runPendingResync(epoch: UInt64, revision: UInt64) async {
        guard epoch == connectionEpoch, revision == syncRevision,
              connection != nil, !initialMergePending else { return }
        resyncTask = nil
        await reconcileWatcherChange()
    }

    // MARK: - Helpers

    private func validateUserPath(_ path: String, connection: SyncConnection) throws {
        try Self.validateRemoteRoot(connection.remotePath)
        guard path.isEmpty || TrashStore.safeRelativePath(path) != nil,
              TrashStore.isContained(join(connection.remotePath, path), in: connection.remotePath),
              TrashStore.isContained(join(connection.localPath, path), in: connection.localPath) else {
            throw SyncError.invalidMove("Path is outside the selected folders or addresses internal state: \(path)")
        }
    }

    private func validateLocalDeletion(_ relativePath: String, connection: SyncConnection) throws {
        let root = connection.localPath
        // A readable root distinguishes a removed item from an unavailable volume.
        _ = try fm.contentsOfDirectory(atPath: root)
        let components = relativePath.split(separator: "/").map(String.init)
        var parent = root
        for component in components {
            let names = try fm.contentsOfDirectory(atPath: parent)
            if !names.contains(component) { return }
            parent = (parent as NSString).appendingPathComponent(component)
        }
        // It reappeared between the initial check and validation; do not delete.
        throw SyncError.invalidMove("Local item reappeared during sync: \(relativePath)")
    }

    private var syncStatePath: String? {
        guard let connection else { return nil }
        return (connection.localPath as NSString).appendingPathComponent(".tethwork-sync-state.json")
    }

    // Diagnostic metadata only. Inventory failures never authorize deletion or
    // change the sync baseline; the problem is retained in the system log.
    private func inventoryNote(_ kind: String, message: String? = nil, paths: [String]? = nil) {
        do { try localInventory?.note(kind: kind, message: message, paths: paths) }
        catch { NSLog("Tethwork inventory journal failed: %@", error.localizedDescription) }
    }

    private func inventoryCheckpoint(force: Bool = false, successfulOperation: String? = nil) {
        do {
            try localInventory?.checkpoint(force: force, successfulOperation: successfulOperation,
                                           selectedPaths: connection == nil ? nil : pinnedPaths.sorted())
        } catch { NSLog("Tethwork inventory checkpoint failed: %@", error.localizedDescription) }
    }

    private func inventoryRetire(_ scope: String, reason: String, remainingSelections: [String] = []) {
        do { try localInventory?.retire(scope: scope, reason: reason, remainingSelections: remainingSelections) }
        catch { NSLog("Tethwork inventory removal record failed: %@", error.localizedDescription) }
    }

    private func auditLocalInventory() async {
        guard let inventory = localInventory else { return }
        do { try await Task.detached(priority: .utility) { try inventory.auditBeforeSync() }.value }
        catch { NSLog("Tethwork inventory audit failed: %@", error.localizedDescription) }
    }

    /// Separate from the deletion baseline: checkpointing a partial scan must
    /// never mark unvisited paths as synchronized or deleted.
    private func loadVerificationCache(for connection: SyncConnection) {
        verifiedPairs.removeAll()
        verificationCacheDirty = false
        lastVerificationCheckpoint = .now
        let path = (connection.localPath as NSString).appendingPathComponent(".tethwork-verification-cache.json")
        guard let data = fm.contents(atPath: path),
              let cache = try? JSONDecoder().decode(VerificationCache.self, from: data), cache.version == 1,
              cache.remotePath == Self.canonicalPath(connection.remotePath),
              cache.localPath == Self.canonicalPath(connection.localPath) else { return }
        verifiedPairs = cache.pairs.filter { TrashStore.safeRelativePath($0.key) != nil }
    }

    private func persistVerificationCache() {
        guard verificationCacheDirty, let connection else { return }
        let path = (connection.localPath as NSString).appendingPathComponent(".tethwork-verification-cache.json")
        let cache = VerificationCache(remotePath: Self.canonicalPath(connection.remotePath),
                                      localPath: Self.canonicalPath(connection.localPath), pairs: verifiedPairs)
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            verificationCacheDirty = false
            lastVerificationCheckpoint = .now
        } catch {
            // A disposable cache must not stop reconciliation or damage its baseline.
            NSLog("Tethwork could not save verification cache: %@", error.localizedDescription)
        }
    }

    private func recordVerifiedPair(_ pair: VerifiedPair, path: String) {
        localInventory?.confirm(path: path, size: pair.localSize, modified: pair.localModified, fileID: pair.localFileID)
        inventoryCheckpoint()
        guard verifiedPairs[path] != pair else { return }
        verifiedPairs[path] = pair
        verificationCacheDirty = true
        let parent = (path as NSString).deletingLastPathComponent
        let directory = parent == "." ? "" : parent
        if storageScans[directory]?.pendingFile == true {
            // A matching link/file can be verified without copying anything,
            // so there is no transfer event to invalidate its old badge.
            storageScans.removeValue(forKey: directory)
            folderStates.removeValue(forKey: directory)
            if storageQueued.insert(directory).inserted { storageQueue.append(directory) }
            startStorageWorker()
        }
        if lastVerificationCheckpoint.duration(to: .now) >= .seconds(5) {
            persistVerificationCache()
        }
    }

    private func recordComparedPair(_ path: String, remote: String, local: String,
                                    remoteBefore: [FileAttributeKey: Any], localBefore: [FileAttributeKey: Any]) throws {
        let pair = VerifiedPair(remote: remoteBefore, local: localBefore)
        guard pair.matches(remote: try Self.readAttributes(at: remote), local: try Self.readAttributes(at: local)) else {
            throw SyncError.invalidMove("A file changed during verification: \(path). Retry synchronization.")
        }
        recordVerifiedPair(pair, path: path)
    }

    private func loadPersistedSyncState(for connection: SyncConnection) -> Set<String> {
        let path = (connection.localPath as NSString).appendingPathComponent(".tethwork-sync-state.json")
        guard let data = fm.contents(atPath: path),
              let state = try? JSONDecoder().decode(PersistedSyncState.self, from: data),
              Self.canonicalPath(state.remotePath) == Self.canonicalPath(connection.remotePath)
        else { return [] }
        return Set(state.syncedPaths.map(Self.normalize))
    }

    private func persistSyncState() {
        persistVerificationCache()
        guard let connection, let path = syncStatePath else { return }
        localInventory?.addExpected(paths: knownSyncedPaths)
        inventoryCheckpoint()
        let state = PersistedSyncState(
            remotePath: Self.canonicalPath(connection.remotePath),
            syncedPaths: knownSyncedPaths.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        // This file lives inside a watched local root. Rewriting an identical
        // baseline changes the directory and can start another reconciliation.
        guard fm.contents(atPath: path) != data else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func refreshPersistedSyncState() async throws {
        guard let connection, !initialMergePending else { return }
        let epoch = connectionEpoch
        let pins = pinnedPaths
        let refreshed = try await Self.syncedPathsOffActor(
            pins: pins,
            remoteRoot: connection.remotePath,
            localRoot: connection.localPath
        )
        guard epoch == connectionEpoch, pins == pinnedPaths, !initialMergePending else { return }
        knownSyncedPaths = refreshed
        persistSyncState()
    }

    nonisolated private static func syncedPathsOffActor(
        pins: Set<String>,
        remoteRoot: String,
        localRoot: String
    ) async throws -> Set<String> {
        try await Task.detached(priority: .background) {
            let fm = FileManager.default
            var result = Set<String>()

            var remoteIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: remoteRoot, isDirectory: &remoteIsDirectory),
                  remoteIsDirectory.boolValue else {
                throw SyncError.remoteUnavailable(remoteRoot)
            }
            var localIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: localRoot, isDirectory: &localIsDirectory),
                  localIsDirectory.boolValue else {
                throw SyncError.notFound(localRoot)
            }

            for pin in pins {
                try collectSyncedPaths(
                    pin: pin,
                    remoteRoot: remoteRoot,
                    localRoot: localRoot,
                    fileManager: fm,
                    into: &result
                )
            }
            return result
        }.value
    }

    nonisolated private static func collectSyncedPaths(
        pin: String,
        remoteRoot: String,
        localRoot: String,
        fileManager fm: FileManager,
        into result: inout Set<String>
    ) throws {
        try Task.checkCancellation()
        let remote = pin.isEmpty
            ? remoteRoot
            : (remoteRoot as NSString).appendingPathComponent(pin)
        let local = pin.isEmpty
            ? localRoot
            : (localRoot as NSString).appendingPathComponent(pin)
        guard try itemExistsWithoutFollowingLink(remote), try itemExistsWithoutFollowingLink(local) else { return }
        result.insert(pin)

        guard (try readAttributes(at: remote)[.type] as? FileAttributeType) == .typeDirectory,
              let enumerator = fm.enumerator(atPath: remote)
        else { return }

        while let suffix = enumerator.nextObject() as? String {
            try Task.checkCancellation()
            if suffix.split(separator: "/").contains(where: { isInternalImportName(String($0)) }) {
                let path = (remote as NSString).appendingPathComponent(suffix)
                if (try? fm.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            let relative = pin.isEmpty ? suffix : "\(pin)/\(suffix)"
            let localPath = (localRoot as NSString).appendingPathComponent(relative)
            if try itemExistsWithoutFollowingLink(localPath) {
                result.insert(normalize(relative))
            }
        }
    }

    // MARK: - Shared Trash awareness

    private func wasDeletedRemotely(_ path: String) async throws -> Bool {
        // A newly created file reusing an old name is not a stale synchronized copy.
        guard knownSyncedPaths.contains(path), let connection else { return false }
        let epoch = connectionEpoch
        let revision = syncRevision
        let deleted = await Task.detached(priority: .utility) {
            TrashStore.containsTrashedPath(path, remoteRoot: connection.remotePath)
        }.value
        guard epoch == connectionEpoch, revision == syncRevision else { throw CancellationError() }
        return deleted
    }

    /// Removes a stale local copy of an item deleted elsewhere, drops its pin and
    /// tells the UI why the file disappeared.
    private func forgetTrashedLocalCopy(_ localPath: String, relativePath: String) throws {
        let normalized = Self.normalize(relativePath)
        inventoryNote("local_removal_requested", message: "A shared Trash record matched a previously synchronized file", paths: [normalized])
        if fm.fileExists(atPath: localPath) {
            try fm.removeItem(atPath: localPath)
        }
        inventoryNote("local_removal_completed", message: "Shared Trash reconciliation", paths: [normalized])
        removeKnownPath(normalized)
        var pinsChanged = false
        if !normalized.isEmpty {
            if pinnedPaths.remove(normalized) != nil { pinsChanged = true }
            let pruned = pinnedPaths.filter { !$0.hasPrefix(normalized + "/") }
            if pruned.count != pinnedPaths.count {
                pinnedPaths = Set(pruned)
                pinsChanged = true
            }
        }
        persistSyncState()
        if pinsChanged { updateRemoteWatchPaths() }
        let name = (normalized as NSString).lastPathComponent
        emit(.init(kind: .trash, message: String(format: String(localized: "Deleted on another Mac: %@"), name), path: normalized))
    }

    // MARK: - Conflicts

    /// Last-write-wins is the conflict policy, but silently overwriting an edit
    /// the user just made on the other side loses data without any trace. When
    /// both copies were modified within five minutes of each other, report it.
    private func overwriteWarning(from: String, to: String, relativePath: String, direction: String) -> SyncEvent? {
        guard let fromAttrs = try? fm.attributesOfItem(atPath: from),
              let toAttrs = try? fm.attributesOfItem(atPath: to)
        else { return nil }
        let winnerDate = (fromAttrs[.modificationDate] as? Date) ?? .distantPast
        let loserDate = (toAttrs[.modificationDate] as? Date) ?? .distantPast
        // A copy left over from an older sync is usually much older than the edit
        // that replaced it. Two nearby timestamps mean a genuine concurrent edit.
        let typeCollision = (fromAttrs[.type] as? FileAttributeType) != (toAttrs[.type] as? FileAttributeType)
        guard typeCollision || abs(winnerDate.timeIntervalSince(loserDate)) < 300 else { return nil }
        let name = (relativePath as NSString).lastPathComponent
        let loser = direction == "local→remote" ? "network" : "local"
        let winner = direction == "local→remote" ? "local" : "network"
        return .init(
            kind: .conflict,
            message: String(format: String(localized: "Replaced the older %@ copy of “%@” with the newer %@ version."),
                            NSLocalizedString(loser, comment: "Copy location"), name, NSLocalizedString(winner, comment: "Copy location")),
            path: relativePath
        )
    }

    private func reportOverwrite(_ warning: SyncEvent?) {
        guard let warning else { return }
        NSLog("Tethwork last-write-wins overwrite on %@: %@", warning.path ?? "", warning.message)
        emit(warning)
    }

    // MARK: - Temporary file cleanup

    private func cleanupStaleTemporaryFiles() {
        guard let connection else { return }
        let roots = [connection.localPath]
            + Self.temporaryCleanupPaths(pins: pinnedPaths, verifiedFiles: Set(verifiedPairs.keys))
                .map { join(connection.remotePath, $0) }
        Task.detached(priority: .background) {
            Self.removeStaleTemporaryFiles(in: roots)
        }
    }

    /// Known file pins share a parent-directory scan. Folder pins need only a
    /// shallow scan of that folder, not a crawl of every known descendant.
    nonisolated static func temporaryCleanupPaths(pins: Set<String>, verifiedFiles: Set<String>) -> Set<String> {
        Set(pins.map { path in
            guard verifiedFiles.contains(path) else { return path }
            let parent = (path as NSString).deletingLastPathComponent
            return parent == "." ? "" : parent
        })
    }

    /// Deletes staging leftovers from a crashed copy (names next to the
    /// destination). Only files older than an hour are touched so a concurrent
    /// copy is never interrupted.
    nonisolated private static func removeStaleTemporaryFiles(in roots: [String]) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3_600)
        for root in roots {
            // Never recursively crawl a NAS just to look for scratch files.
            guard let children = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            ) else { continue }
            for url in children {
                let name = url.lastPathComponent
                // A backup can be the only surviving original after a crash.
                // Never delete it automatically.
                let isTemporary = name.hasPrefix(".tethwork-copy-") || name.hasPrefix(".tethwork-trash-cleanup-")
                guard isTemporary else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                guard (values?.contentModificationDate ?? .distantPast) < cutoff else { continue }
                try? fm.removeItem(at: url)
            }
        }
    }

    private func removeKnownPath(_ path: String) {
        verificationCacheDirty = true
        let normalized = Self.normalize(path)
        if normalized.isEmpty {
            knownSyncedPaths.removeAll()
            verifiedPairs.removeAll()
        } else {
            knownSyncedPaths = knownSyncedPaths.filter {
                $0 != normalized && !$0.hasPrefix(normalized + "/")
            }
            verifiedPairs = verifiedPairs.filter { $0.key != normalized && !$0.key.hasPrefix(normalized + "/") }
        }
    }

    private func remapKnownPaths(from source: String, to destination: String) {
        do { try localInventory?.remap(from: source, to: destination) }
        catch { NSLog("Tethwork inventory remap failed: %@", error.localizedDescription) }
        var updated = Set<String>()
        for path in knownSyncedPaths {
            if path == source {
                updated.insert(destination)
            } else if path.hasPrefix(source + "/") {
                updated.insert(destination + path.dropFirst(source.count))
            } else {
                updated.insert(path)
            }
        }
        knownSyncedPaths = updated
        var verified: [String: VerifiedPair] = [:]
        for (path, pair) in verifiedPairs {
            let updatedPath = path == source ? destination
                : (path.hasPrefix(source + "/") ? destination + path.dropFirst(source.count) : path)
            verified[updatedPath] = pair
        }
        verifiedPairs = verified
        verificationCacheDirty = true
    }

    private func suppress(for seconds: TimeInterval) {
        suppressUntil = Date().addingTimeInterval(seconds)
    }

    private func emit(_ event: SyncEvent) {
        var event = event
        if event.kind == .complete {
            localInventory?.addExpected(paths: knownSyncedPaths)
            inventoryCheckpoint(force: true, successfulOperation: event.message)
        } else if event.kind == .error || event.kind == .file || event.kind == .trash {
            inventoryNote("engine_\(String(describing: event.kind))", message: event.message, paths: event.path.map { [$0] })
        }
        if event.kind == .complete || event.kind == .error || event.phase == .preparing {
            lastUploadRate = nil
            lastDownloadRate = nil
            publishedUploadRate = false
            publishedDownloadRate = false
        }
        // Completion of a small file often falls inside the UI throttle window.
        // Retain its rate before throttling and attach it to the next snapshot.
        if let rate = event.bytesPerSecond {
            if event.transferDirection == .upload { lastUploadRate = rate }
            if event.transferDirection == .download { lastDownloadRate = rate }
        } else if event.kind == .progress, event.phase == .transferring {
            if event.transferDirection == .upload { event.bytesPerSecond = lastUploadRate }
            if event.transferDirection == .download { event.bytesPerSecond = lastDownloadRate }
        }
        if event.kind == .error, event.isRemoteUnavailable { remoteWasUnavailable = true }
        // A large tree can produce thousands of checking events per second.
        // Each one schedules a MainActor task and invalidates the SwiftUI window.
        // Keep the first event of each phase and periodic snapshots, not every file.
        if event.kind == .progress, let phase = event.phase {
            let now = ContinuousClock.now
            let firstInPhase = progressPhases.insert(phase).inserted
            let firstRate = (event.bytesPerSecond ?? 0) > 0 &&
                ((event.transferDirection == .upload && !publishedUploadRate) ||
                 (event.transferDirection == .download && !publishedDownloadRate))
            if !firstInPhase, !firstRate, phase != .finishing, let lastProgressEmission,
               lastProgressEmission.duration(to: now) < .milliseconds(200) {
                return
            }
            lastProgressEmission = now
        }
        if (event.bytesPerSecond ?? 0) > 0 {
            if event.transferDirection == .upload { publishedUploadRate = true }
            if event.transferDirection == .download { publishedDownloadRate = true }
        }
        if event.kind == .complete || event.kind == .file || event.kind == .trash || event.kind == .error {
            invalidateFolderStorage()
        }
        var tagged = event
        tagged.connectionID = connection?.id
        tagged.storageGeneration = storageGeneration
        eventHandler?(tagged)
    }

    private func reportRemoteRecovery(_ connection: SyncConnection) throws {
        guard remoteWasUnavailable else { return }
        // Existence alone is insufficient after changing SMB credentials.
        _ = try fm.contentsOfDirectory(atPath: connection.remotePath)
        remoteWasUnavailable = false
        emit(.init(kind: .status, message: String(localized: "Connected"), path: nil, isRemoteAvailable: true))
    }

    nonisolated private static func isRemoteUnavailableError(_ error: Error) -> Bool {
        guard let syncError = error as? SyncError else { return false }
        if case .remoteUnavailable = syncError { return true }
        return false
    }

    private func join(_ root: String, _ relative: String) -> String {
        if relative.isEmpty { return root }
        return (root as NSString).appendingPathComponent(relative)
    }

    nonisolated static func normalize(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// A folder pin already covers its descendants; do not scan all of them twice.
    nonisolated static func compactPinnedPaths(_ paths: [String]) -> [String] {
        let normalized = Set(paths.filter { $0.isEmpty || TrashStore.safeRelativePath($0) != nil }.map(normalize))
        if normalized.contains("") { return [""] }
        return normalized.filter { path in
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." {
                if normalized.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }.sorted()
    }

    /// Cloud-managed directories are authoritative user data, not disposable
    /// cache roots. Refuse them before creating directories, loading baselines,
    /// starting watchers, adopting files or allowing any mutation.
    nonisolated static func validateConnectionSafety(_ connection: SyncConnection,
                                                     homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let protected = ["Library/Mobile Documents", "Library/CloudStorage"].map {
            canonicalPath(homeDirectory.appendingPathComponent($0).path)
        }
        for path in [connection.localPath, connection.remotePath] {
            let candidate = canonicalPath(path)
            if protected.contains(where: { root in
                candidate == root || candidate.hasPrefix(root + "/") || root.hasPrefix(candidate + "/")
            }) {
                throw SyncError.cloudManagedRoot(path)
            }
            // Also catch ubiquitous Documents/Desktop folders outside the
            // conventional paths. Check an existing ancestor for new folders.
            var existing = URL(fileURLWithPath: candidate)
            while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
                existing.deleteLastPathComponent()
            }
            if try existing.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true {
                throw SyncError.cloudManagedRoot(path)
            }
        }
    }

    nonisolated private static func validateRemoteRoot(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SyncError.remoteUnavailable(path)
        }
    }

    nonisolated static func canonicalPath(_ path: String) -> String {
        // Foundation may leave a nonexistent path unresolved (e.g. /private/var
        // versus /var). Resolve its existing ancestor before restoring the suffix.
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            suffix.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in suffix.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    nonisolated private static func rootsAreDisjoint(_ first: String, _ second: String) -> Bool {
        let lhs = canonicalPath(first)
        let rhs = canonicalPath(second)
        guard !lhs.isEmpty, !rhs.isEmpty,
              lhs != "/", rhs != "/", lhs != rhs else { return false }
        return !lhs.hasPrefix(rhs + "/") && !rhs.hasPrefix(lhs + "/")
    }
}

enum SyncError: LocalizedError {
    case notConnected
    case remoteUnavailable(String)
    case notFound(String)
    case invalidMove(String)
    case overlappingRoots
    case cloudManagedRoot(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected")
        case .remoteUnavailable(let path):
            return "Remote path unavailable: \(path)"
        case .notFound(let path):
            return "Folder not found: \(path)"
        case .invalidMove(let message):
            return message
        case .overlappingRoots:
            return String(localized: "The network and local folders must not be the same or contain one another.")
        case .cloudManagedRoot(let path):
            return String(localized: "Cloud-managed folders cannot be used as sync roots. Deleting a local copy can delete it from the cloud. Choose a dedicated folder outside iCloud Drive or other cloud storage.") + "\n" + path
        }
    }
}
