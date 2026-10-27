import Foundation
import Darwin

/// Bidirectional selective sync between a network (or any remote) folder
/// and a local folder. Only pinned paths are kept locally.
actor SyncEngine {
    private struct PersistedSyncState: Codable {
        var remotePath: String
        var syncedPaths: [String]
    }

    private(set) var connection: SyncConnection?
    private var pinnedPaths: Set<String> = []
    /// Paths known to have existed on both sides after the last successful sync.
    /// This is the baseline that lets us distinguish a deletion from a new file.
    private var knownSyncedPaths: Set<String> = []
    private var initialMergePending = false
    private var connectionEpoch: UInt64 = 0
    private var syncRevision: UInt64 = 0
    private var automaticSyncSuspended = false
    private var copyTasks: [UUID: Task<Void, Error>] = [:]
    private var countingTask: (id: UUID, task: Task<Int, Error>)?
    private var remoteWatcher: DirectoryWatcher?
    private var localWatcher: DirectoryWatcher?
    private var syncing = false
    private var paused = false
    private var suppressUntil: Date = .distantPast
    private var eventHandler: (@Sendable (SyncEvent) -> Void)?
    private var syncProgressDone = 0
    private var syncProgressTotal = 0
    /// Files actually copied this sync (mismatches only).
    private var syncTransferDone = 0
    private var syncTransferTotal = 0
    private var transferTotalKnown = true
    /// >0 while UI is listing/navigating — background sync waits so SMB stays responsive.
    private var uiHoldCount = 0

    private let fm = FileManager.default
    /// Deterministic sync tests can drive reconciliation without filesystem callbacks.
    private let watchesDirectories: Bool
    /// Pause between file copies so Finder-style browsing can use the share.
    private let syncTransferGapNs: UInt64 = 150_000_000
    private let syncMetadataGapNs: UInt64 = 25_000_000

    init(watchesDirectories: Bool = true) {
        self.watchesDirectories = watchesDirectories
    }

    func setEventHandler(_ handler: @escaping @Sendable (SyncEvent) -> Void) {
        eventHandler = handler
    }

    func getPinnedPaths() -> [String] {
        pinnedPaths.sorted()
    }

    func shouldKeepLocal(_ relativePath: String) -> Bool {
        let normalized = Self.normalize(relativePath)
        if pinnedPaths.contains("") { return true }
        for pin in pinnedPaths where !pin.isEmpty {
            if normalized == pin || normalized.hasPrefix(pin + "/") {
                return true
            }
        }
        return false
    }

    func syncMode(for relativePath: String) -> SyncMode {
        shouldKeepLocal(relativePath) ? .offline : .onlineOnly
    }

    func connect(connection: SyncConnection, pinned: [String], initiallySyncedPaths: [String]? = nil,
                 deferInitialMerge: Bool = false) async throws {
        await disconnect()

        guard Self.rootsAreDisjoint(connection.remotePath, connection.localPath) else {
            throw SyncError.overlappingRoots
        }
        self.connection = connection
        self.initialMergePending = deferInitialMerge
        self.pinnedPaths = deferInitialMerge ? [] : Set(Self.compactPinnedPaths(pinned))

        try fm.createDirectory(atPath: connection.localPath, withIntermediateDirectories: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: connection.remotePath, isDirectory: &isDir), isDir.boolValue else {
            throw SyncError.remoteUnavailable(connection.remotePath)
        }

        knownSyncedPaths = deferInitialMerge ? [] : (initiallySyncedPaths.map(Set.init) ?? loadPersistedSyncState(for: connection))
        if initiallySyncedPaths != nil {
            persistSyncState()
        }

        // Sync pinned content in the background after connect so the UI stays usable.
        if watchesDirectories && !initialMergePending {
            startWatchers()
        }
        emit(.init(kind: .status, message: "Connected"))
    }

    func disconnect() async {
        connectionEpoch &+= 1
        await stopTransfers()
        stopWatchers()
        persistSyncState()
        connection = nil
        initialMergePending = false
        pinnedPaths.removeAll()
        knownSyncedPaths.removeAll()
        automaticSyncSuspended = false
        syncing = false
        paused = false
        emit(.init(kind: .status, message: "Disconnected"))
    }

    @discardableResult
    func setPinned(relativePath: String, pinned: Bool) async throws -> [String] {
        let connection = try writableConnection()
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
                emit(.init(kind: .status, message: "Freeing local space: \(normalized.isEmpty ? "/" : normalized)", path: normalized))
                try await removeLocalTree(normalized)
            }

            guard epoch == connectionEpoch, revision == syncRevision else { throw CancellationError() }
            if pinned {
                emit(.init(kind: .progress, message: "Finishing download…", path: normalized,
                           progressDone: syncTransferDone, isTransfer: true,
                           transferDirection: .download, phase: .finishing))
                // materialize records matching/copied paths as it goes. Do not make
                // the user wait for another scan of every pinned tree on the NAS.
                persistSyncState()
            }
            updateRemoteWatchPaths()
            let paths = getPinnedPaths()
            if pinned {
                automaticSyncSuspended = false
                emit(.init(kind: .complete, message: "Download complete", isTransfer: false))
            }
            return paths
        } catch {
            guard epoch == connectionEpoch, revision == syncRevision, !(error is CancellationError) else {
                throw CancellationError()
            }
            automaticSyncSuspended = true
            persistSyncState()
            emit(.init(kind: .error, message: error.localizedDescription,
                       isRemoteUnavailable: Self.isRemoteUnavailableError(error)))
            throw error
        }
    }

    func fullSync() async {
        guard let connection, !syncing, !initialMergePending else { return }
        let epoch = connectionEpoch
        let revision = syncRevision
        automaticSyncSuspended = false
        syncing = true
        paused = true
        suppress(for: 2)

        defer {
            if revision == syncRevision {
                syncing = false
                paused = false
                syncProgressDone = 0
                syncProgressTotal = 0
                syncTransferDone = 0
                syncTransferTotal = 0
            }
        }

        do {
            let pins = pinnedPaths.sorted()
            let remoteRoot = connection.remotePath
            let localRoot = connection.localPath
            let pinSet = pinnedPaths
            try Self.validateRemoteRoot(remoteRoot)

            emit(.init(kind: .progress, message: "Checking files to synchronize…", path: pins.count == 1 ? pins.first : nil,
                       progressDone: 0, isTransfer: true, phase: .preparing))
            syncTransferTotal = try await countTransferFiles(
                pins: pins,
                remoteRoot: remoteRoot,
                localRoot: localRoot,
                pinnedPaths: pinSet
            )
            guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
            syncTransferDone = 0
            syncProgressDone = 0
            syncProgressTotal = syncTransferTotal

            // Empty directories can have pending deletions even with no file transfers.
            emit(.init(kind: .status, message: "Syncing \(syncTransferTotal) files…"))

            for pin in pins {
                guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
                try await syncTree(pin)
            }
            guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
            try await pruneUnpinnedLocal()
            try await refreshPersistedSyncState()
            emit(.init(
                kind: .complete,
                message: "Sync complete",
                progressDone: syncTransferDone,
                progressTotal: syncTransferTotal,
                isTransfer: true
            ))
        } catch {
            guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending,
                  !(error is CancellationError) else { return }
            automaticSyncSuspended = true
            emit(.init(
                kind: .error,
                message: error.localizedDescription,
                isRemoteUnavailable: Self.isRemoteUnavailableError(error)
            ))
        }
    }

    /// Moves items from the network drive into the server-side trash and removes
    /// local copies; updates pins. Trashed items can be restored for 15 days.
    func trashItems(relativePaths: [String]) async throws {
        let connection = try writableConnection()
        await stopTransfers()
        guard self.connection?.id == connection.id else { throw SyncError.notConnected }
        suppress(for: 1.5)
        paused = true
        defer { paused = false }

        var failures: [String] = []

        let pins = pinnedPaths
        let outcome = TrashStore.moveToTrash(
            relativePaths: relativePaths,
            remoteRoot: connection.remotePath,
            wasPinned: { Self.shouldKeepLocal($0, pins: pins) }
        )

        for item in outcome.moved {
            let normalized = item.originalPath
            let local = join(connection.localPath, normalized)

            if fm.fileExists(atPath: local) {
                do {
                    try fm.removeItem(atPath: local)
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

        try? await refreshPersistedSyncState()
        persistSyncState()
        updateRemoteWatchPaths()

        if !failures.isEmpty {
            automaticSyncSuspended = true
            let list = failures.prefix(3).joined(separator: ", ")
            let suffix = failures.count > 3 ? " and \(failures.count - 3) more" : ""
            throw SyncError.invalidMove("Could not move to Trash: \(list)\(suffix)")
        }
    }

    // MARK: - Trash

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
        defer { paused = false }

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
        let destDir = Self.normalize(destinationDir)
        suppress(for: 1.5)
        paused = true
        defer { paused = false }

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

            if fm.fileExists(atPath: localFrom) {
                try fm.createDirectory(
                    atPath: (localTo as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: localTo) {
                    try? fm.removeItem(atPath: localTo)
                }
                try? fm.moveItem(atPath: localFrom, toPath: localTo)
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

            emit(.init(kind: .file, message: "Moved: \(name)", path: destination))
        }
        persistSyncState()
    }

    /// Renames a single item on the remote volume and its local copy if present.
    /// Returns the new relative path.
    func renameItem(relativePath: String, newName: String) async throws -> String {
        let connection = try writableConnection()
        let source = Self.normalize(relativePath)
        guard !source.isEmpty else {
            throw SyncError.invalidMove("Cannot rename the root")
        }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SyncError.invalidMove("Name cannot be empty")
        }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), trimmed != ".", trimmed != ".." else {
            throw SyncError.invalidMove("Invalid name")
        }
        guard !trimmed.hasPrefix(".") else {
            throw SyncError.invalidMove("Name cannot start with a period")
        }

        let parent = (source as NSString).deletingLastPathComponent
        let parentNorm = (parent == "." || parent.isEmpty) ? "" : Self.normalize(parent)
        let destination = parentNorm.isEmpty ? trimmed : "\(parentNorm)/\(trimmed)"
        if source == destination { return destination }

        suppress(for: 1.5)
        paused = true
        defer { paused = false }

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

        if caseOnlyRename {
            let tempSuffix = "__tethwork_rename_\(UUID().uuidString.prefix(8))"
            try fm.moveItem(atPath: remoteFrom, toPath: remoteFrom + tempSuffix)
            try fm.moveItem(atPath: remoteFrom + tempSuffix, toPath: remoteTo)

            if fm.fileExists(atPath: localFrom) {
                try? fm.moveItem(atPath: localFrom, toPath: localFrom + tempSuffix)
                try? fm.moveItem(atPath: localFrom + tempSuffix, toPath: localTo)
            }
        } else {
            if fm.fileExists(atPath: remoteTo) {
                throw SyncError.invalidMove("“\(trimmed)” already exists")
            }

            try fm.moveItem(atPath: remoteFrom, toPath: remoteTo)

            if fm.fileExists(atPath: localFrom) {
                if fm.fileExists(atPath: localTo) {
                    try? fm.removeItem(atPath: localTo)
                }
                try? fm.moveItem(atPath: localFrom, toPath: localTo)
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

        emit(.init(kind: .file, message: "Renamed: \(trimmed)", path: destination))
        return destination
    }

    /// Publish the final local paths only after the additive background upload finishes.
    /// Reading/listing is available throughout; reconciliation and mutations wait.
    @discardableResult
    func finishInitialMerge(connectionID: String, paths: [String]) throws -> [String] {
        guard connection?.id == connectionID, initialMergePending else { throw SyncError.notConnected }
        pinnedPaths = Set(paths.map(Self.normalize))
        knownSyncedPaths = pinnedPaths
        persistSyncState()
        initialMergePending = false
        if watchesDirectories { startWatchers() }
        return getPinnedPaths()
    }

    func prepareInitialMerge(connectionID: String) throws {
        guard connection?.id == connectionID, !syncing else { throw SyncError.notConnected }
        stopWatchers()
        initialMergePending = true
        pinnedPaths = []
        knownSyncedPaths = []
    }

    private func writableConnection() throws -> SyncConnection {
        guard let connection else { throw SyncError.notConnected }
        guard !initialMergePending else {
            throw SyncError.invalidMove("Local files are still being merged. Please wait before changing files or local storage.")
        }
        return connection
    }

    private struct InitialMergePlan {
        let localRoot: URL
        var directories: [URL] = []
        var uploads: [(source: URL, destination: URL, relativePath: String)] = []
        var renames: [(source: URL, destination: URL)] = []
        var matchingFiles: [(source: URL, remote: URL, finalLocal: URL)] = []
        var localPaths = Set<String>()
        var reservedPaths = Set<String>()
    }

    /// Adopt only existing local content. Never download or overwrite server content.
    /// Conflicting local names are changed only after every upload succeeds.
    nonisolated static func mergeExistingLocalFiles(
        connection: SyncConnection,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> [String] {
        let task = Task.detached(priority: .utility) {
            guard rootsAreDisjoint(connection.remotePath, connection.localPath) else {
                throw SyncError.overlappingRoots
            }
            try validateRemoteRoot(connection.remotePath)
            let fm = FileManager.default
            let localRoot = URL(fileURLWithPath: connection.localPath)
            let remoteRoot = URL(fileURLWithPath: connection.remotePath)
            guard try mergeItemType(at: localRoot, fm: fm) != nil else { return [String]() }
            var plan = InitialMergePlan(localRoot: localRoot)
            try planInitialMerge(local: localRoot, remote: remoteRoot, relativePath: "", fm: fm, plan: &plan)

            for directory in plan.directories {
                try Task.checkCancellation()
                try validateRemoteRoot(connection.remotePath)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            onProgress?(0, plan.uploads.count, "")
            for (index, upload) in plan.uploads.enumerated() {
                try Task.checkCancellation()
                try validateRemoteRoot(connection.remotePath)
                let temporary = upload.destination.deletingLastPathComponent()
                    .appendingPathComponent(".tethwork-copy-\(UUID().uuidString)")
                // Unlike ordinary sync, initial adoption must never replace a destination,
                // even if another client creates it after the plan was made.
                do {
                    defer { try? fm.removeItem(at: temporary) }
                    try fm.copyItem(at: upload.source, to: temporary)
                    try Task.checkCancellation()
                    try validateRemoteRoot(connection.remotePath)
                    try fm.moveItem(at: temporary, to: upload.destination)
                }
                onProgress?(index + 1, plan.uploads.count, upload.relativePath)
            }

            try Task.checkCancellation()
            for match in plan.matchingFiles {
                guard try mergeItemType(at: match.source, fm: fm) == .typeRegular,
                      try mergeItemType(at: match.remote, fm: fm) == .typeRegular,
                      fm.contentsEqual(atPath: match.source.path, andPath: match.remote.path) else {
                    throw SyncError.invalidMove("A file changed during the initial merge. Retry to preserve both versions: \(match.source.path)")
                }
            }
            // Nested renames must happen before their parent folder is renamed.
            for rename in plan.renames.sorted(by: { $0.source.pathComponents.count > $1.source.pathComponents.count }) {
                try fm.moveItem(at: rename.source, to: rename.destination)
            }
            // Equal contents with different mtimes should not cause an immediate
            // redundant download when normal synchronization starts.
            for match in plan.matchingFiles {
                let attributes = try? fm.attributesOfItem(atPath: match.remote.path)
                if let date = attributes?[.modificationDate] as? Date {
                    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: match.finalLocal.path)
                }
            }
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
            throw error
        }
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

    nonisolated private static func planInitialMerge(
        local: URL, remote: URL, relativePath: String, fm: FileManager, plan: inout InitialMergePlan
    ) throws {
        let children = try fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            // Internal state is not user content. Other dotfiles are deliberately included.
            if name == ".DS_Store" || name.hasPrefix(".tethwork-copy-") ||
                (relativePath.isEmpty && [".tethwork-sync-state.json", ".tethwork-trash"].contains(name)) {
                continue
            }
            let type = try mergeItemType(at: child, fm: fm)
            guard type == .typeDirectory || type == .typeRegular else {
                throw SyncError.invalidMove("Cannot safely merge this local item (links and special files are not followed): \(child.path)")
            }
            let isDirectory = type == .typeDirectory
            var destination = remote.appendingPathComponent(name)
            let remoteType = try mergeItemType(at: destination, fm: fm)
            let reserved = plan.reservedPaths.contains(destination.path.lowercased())
            let matchingFile = !isDirectory && remoteType == .typeRegular && !reserved &&
                fm.contentsEqual(atPath: child.path, andPath: destination.path)
            if reserved || (remoteType != nil && !(isDirectory && remoteType == .typeDirectory) && !matchingFile) {
                let unique = try initialMergeName(preferred: name, isDirectory: isDirectory,
                                                  localParent: local, remoteParent: remote,
                                                  fm: fm, reserved: plan.reservedPaths)
                destination = remote.appendingPathComponent(unique)
                plan.renames.append((child, local.appendingPathComponent(unique)))
            }
            plan.reservedPaths.insert(destination.path.lowercased())
            let destinationPath = relativePath.isEmpty ? destination.lastPathComponent : "\(relativePath)/\(destination.lastPathComponent)"
            if isDirectory {
                plan.directories.append(destination)
                let countBefore = plan.localPaths.count
                try planInitialMerge(local: child, remote: destination, relativePath: destinationPath, fm: fm, plan: &plan)
                if plan.localPaths.count == countBefore {
                    // Pin an empty directory only if it will not pull existing online files down.
                    let serverChildren = (remoteType == .typeDirectory && destination.lastPathComponent == name)
                        ? try fm.contentsOfDirectory(atPath: destination.path) : []
                    if serverChildren.isEmpty { plan.localPaths.insert(destinationPath) }
                }
            } else {
                plan.localPaths.insert(destinationPath)
                if matchingFile {
                    plan.matchingFiles.append((child, destination, plan.localRoot.appendingPathComponent(destinationPath)))
                } else {
                    plan.uploads.append((child, destination, destinationPath))
                }
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
        let destDir = Self.normalize(destinationDir)
        suppress(for: 2.0)
        paused = true
        defer { paused = false }

        let remoteDestDir = join(connection.remotePath, destDir)
        try fm.createDirectory(atPath: remoteDestDir, withIntermediateDirectories: true)

        // Plan file-level jobs so a big folder reports real progress.
        var jobs: [(sourcePath: String, destRel: String, displayName: String)] = []

        for sourceURL in sourceURLs {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }

            let sourcePath = sourceURL.path
            guard fm.fileExists(atPath: sourcePath) else { continue }

            let preferredName = sourceURL.lastPathComponent
            guard !preferredName.isEmpty, !preferredName.hasPrefix(".") else { continue }

            let uniqueName = Self.uniqueChildName(preferred: preferredName, inDirectory: remoteDestDir, fm: fm)
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

    /// Flat list of files under `root` as (absolutePath, pathRelativeToRoot).
    nonisolated private static func enumerateFiles(
        at root: String,
        relativeTo base: String
    ) throws -> [(String, String)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [(String, String)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }
            let abs = url.path
            var rel = abs
            if abs.hasPrefix(base + "/") {
                rel = String(abs.dropFirst(base.count + 1))
            } else if abs == base {
                continue
            }
            result.append((abs, rel))
        }
        return result
    }

    /// Avoids overwriting: `file.txt` → `file 2.txt` → `file 3.txt`…
    nonisolated private static func uniqueChildName(
        preferred: String,
        inDirectory directory: String,
        fm: FileManager
    ) -> String {
        let candidate = (directory as NSString).appendingPathComponent(preferred)
        guard fm.fileExists(atPath: candidate) else { return preferred }

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
            if !fm.fileExists(atPath: path) { return name }
            index += 1
        }
    }

    func listDirectory(relativePath: String) async throws -> DirectoryListing {
        guard let connection else { throw SyncError.notConnected }
        uiHoldCount += 1
        defer { uiHoldCount = max(0, uiHoldCount - 1) }

        let normalized = Self.normalize(relativePath)
        let remoteRoot = connection.remotePath
        let localRoot = connection.localPath
        let pins = pinnedPaths

        // High-priority listing off the actor so it can run while a sync copy is in flight,
        // and uiHoldCount makes sync wait before starting the next transfer.
        return try await Task.detached(priority: .userInitiated) {
            try Self.buildListing(
                relativePath: normalized,
                remoteRoot: remoteRoot,
                localRoot: localRoot,
                pinnedPaths: pins
            )
        }.value
    }

    nonisolated private static func buildListing(
        relativePath normalized: String,
        remoteRoot: String,
        localRoot: String,
        pinnedPaths: Set<String>
    ) throws -> DirectoryListing {
        let fm = FileManager.default
        let remoteDir = normalized.isEmpty ? remoteRoot : (remoteRoot as NSString).appendingPathComponent(normalized)
        let localDir = normalized.isEmpty ? localRoot : (localRoot as NSString).appendingPathComponent(normalized)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: remoteDir, isDirectory: &isDir), isDir.boolValue else {
            throw SyncError.notFound(normalized.isEmpty ? "/" : normalized)
        }

        let names = try fm.contentsOfDirectory(atPath: remoteDir)
            .filter { !$0.hasPrefix(".") }

        var entries: [FileEntry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            let rel = normalized.isEmpty ? name : "\(normalized)/\(name)"
            let remoteAbs = (remoteDir as NSString).appendingPathComponent(name)
            let localAbs = (localDir as NSString).appendingPathComponent(name)
            let attrs = try fm.attributesOfItem(atPath: remoteAbs)
            let isDirectory = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date) ?? Date()
            let locallyAvailable = fm.fileExists(atPath: localAbs)
            let mode: SyncMode = Self.shouldKeepLocal(rel, pins: pinnedPaths) ? .offline : .onlineOnly
            let syncStatus: SyncStatus
            if mode == .onlineOnly {
                syncStatus = .onlineOnly
            } else if !locallyAvailable {
                // Pinned but missing locally — discrepancy that should be fixed.
                syncStatus = .pending
            } else if isDirectory {
                syncStatus = .synced
            } else if let localAttrs = try? fm.attributesOfItem(atPath: localAbs) {
                let localSize = (localAttrs[.size] as? NSNumber)?.int64Value ?? 0
                let localM = (localAttrs[.modificationDate] as? Date) ?? .distantPast
                if abs(mtime.timeIntervalSince(localM)) < 0.001, size == localSize {
                    syncStatus = .synced
                } else {
                    syncStatus = .pending
                }
            } else {
                syncStatus = .pending
            }

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
                    syncStatus: syncStatus
                )
            )
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

        return DirectoryListing(relativePath: normalized, entries: entries, breadcrumbs: breadcrumbs)
    }

    /// Recursive name search under `relativePath` (includes nested folders).
    /// Calls `onPartial` with growing results so the UI can update before the walk finishes.
    func search(
        query: String,
        under relativePath: String,
        limit: Int = 1000,
        onPartial: (@Sendable ([FileEntry]) -> Void)? = nil
    ) async throws -> [FileEntry] {
        guard let connection else { throw SyncError.notConnected }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Pause background sync so the share isn't saturated during search.
        uiHoldCount += 1
        defer { uiHoldCount = max(0, uiHoldCount - 1) }

        let normalized = Self.normalize(relativePath)
        let remoteRoot = connection.remotePath
        let pins = pinnedPaths

        return try await Task.detached(priority: .userInitiated) {
            try Self.searchWithEnumerator(
                query: trimmed,
                under: normalized,
                remoteRoot: remoteRoot,
                pinnedPaths: pins,
                limit: limit,
                onPartial: onPartial
            )
        }.value
    }

    nonisolated private static func searchWithEnumerator(
        query: String,
        under rootRelative: String,
        remoteRoot: String,
        pinnedPaths: Set<String>,
        limit: Int,
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
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootPrefix = remoteDir.hasSuffix("/") ? remoteDir : remoteDir + "/"
        var results: [FileEntry] = []
        results.reserveCapacity(min(limit, 256))
        var sincePartial = 0

        for case let url as URL in enumerator {
            if results.count >= limit { break }

            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }

            // Name-only match first — no extra SMB round-trip for misses.
            guard name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { continue }

            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            let isDirectory = values.isDirectory == true
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? Date()

            let absPath = url.path
            let relSuffix: String
            if absPath == remoteDir {
                continue
            } else if absPath.hasPrefix(rootPrefix) {
                relSuffix = String(absPath.dropFirst(rootPrefix.count))
            } else {
                continue
            }

            let rel = rootRelative.isEmpty
                ? relSuffix
                : "\(rootRelative)/\(relSuffix)"
            let displayName = relSuffix

            // Skip local disk probes during search — they double SMB/local I/O.
            let mode: SyncMode = shouldKeepLocal(rel, pins: pinnedPaths) ? .offline : .onlineOnly

            results.append(
                FileEntry(
                    name: displayName,
                    absolutePath: absPath,
                    relativePath: rel,
                    isDirectory: isDirectory,
                    size: isDirectory ? 0 : size,
                    modified: mtime,
                    syncMode: mode,
                    isLocallyAvailable: mode == .offline,
                    syncStatus: mode == .offline ? .synced : .onlineOnly
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
        let normalized = normalize(relativePath)
        if pins.contains("") { return true }
        for pin in pins where !pin.isEmpty {
            if normalized == pin || normalized.hasPrefix(pin + "/") {
                return true
            }
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
        let remote = join(connection.remotePath, relativePath)
        let local = join(connection.localPath, relativePath)

        let remoteExists = fm.fileExists(atPath: remote)
        let localExists = fm.fileExists(atPath: local)

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
                try TrashStore.moveToTrash(
                    relativePath: relativePath,
                    remoteRoot: connection.remotePath,
                    wasPinned: shouldKeepLocal(relativePath),
                    origin: .local
                )
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
            try await materialize(from: local, to: remote, relativePath: relativePath, direction: "local→remote")
            return
        }

        let rAttrs = try fm.attributesOfItem(atPath: remote)
        let lAttrs = try fm.attributesOfItem(atPath: local)
        let rIsDir = (rAttrs[.type] as? FileAttributeType) == .typeDirectory
        let lIsDir = (lAttrs[.type] as? FileAttributeType) == .typeDirectory

        if rIsDir && lIsDir {
            let remoteNames = Set(try fm.contentsOfDirectory(atPath: remote).filter { !$0.hasPrefix(".") })
            let localNames = Set(try fm.contentsOfDirectory(atPath: local).filter { !$0.hasPrefix(".") })
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
            emit(.init(kind: .progress, message: "Checking: \((relativePath as NSString).lastPathComponent)",
                       path: relativePath, progressDone: syncTransferDone, progressTotal: syncTransferTotal,
                       isTransfer: true, phase: .checking))
            let rSize = (rAttrs[.size] as? NSNumber)?.int64Value ?? 0
            let lSize = (lAttrs[.size] as? NSNumber)?.int64Value ?? 0
            let rM = (rAttrs[.modificationDate] as? Date) ?? .distantPast
            let lM = (lAttrs[.modificationDate] as? Date) ?? .distantPast
            if rSize == lSize {
                let timestampsClose = abs(rM.timeIntervalSince(lM)) < 3
                if timestampsClose,
                   try await Self.filesHaveEqualContents(remote, local) {
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
        let epoch = connectionEpoch
        let revision = syncRevision
        await cooperateWithUI(transferGap: false)
        guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
        if direction == "local→remote", let connection {
            try Self.validateRemoteRoot(connection.remotePath)
        }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: from, isDirectory: &isDir)
        if isDir.boolValue {
            try fm.createDirectory(atPath: to, withIntermediateDirectories: true)
            knownSyncedPaths.insert(relativePath)
            if !transferTotalKnown {
                emit(.init(kind: .progress, message: "Opening folder: \(relativePath.isEmpty ? "/" : relativePath)",
                           path: relativePath, progressDone: syncTransferDone, isTransfer: true,
                           transferDirection: direction == "local→remote" ? .upload : .download, phase: .preparing))
            }
            let names = try await Task.detached(priority: .utility) {
                try FileManager.default.contentsOfDirectory(atPath: from)
                    .filter { !$0.hasPrefix(".") }.sorted()
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
                    .filter { !$0.hasPrefix(".") && !remoteNames.contains($0) }.sorted()
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

            if fromSize == toSize,
               abs(fromM.timeIntervalSince(toM)) < 3,
                try await Self.filesHaveEqualContents(from, to) {
                guard epoch == connectionEpoch, revision == syncRevision else { return }
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
        let byteCount = Self.fileSize(at: from)
        let startedAt = ContinuousClock.now
        try await copyPath(from: from, to: to, direction: direction, emitFile: false)
        guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
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
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        return pinnedPaths.contains { $0.hasPrefix(prefix) && $0 != relativePath }
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
        // Stream the first files immediately. Counting the whole NAS tree first
        // can take minutes and used to leave the UI showing only "Downloading".
        try await materialize(from: remote, to: local, relativePath: relativePath, direction: "remote→local")
    }

    private func countPinnedFiles() throws -> Int {
        guard let connection else { return 0 }
        var total = 0
        for pin in pinnedPaths {
            let remote = join(connection.remotePath, pin)
            let local = join(connection.localPath, pin)
            if fm.fileExists(atPath: remote) {
                total += try countFiles(at: remote)
            } else if fm.fileExists(atPath: local) {
                total += try countFiles(at: local)
            }
        }
        return total
    }

    /// Count files that need a copy under pinned paths (missing or size/mtime mismatch).
    private func countTransferFiles(pins: [String], remoteRoot: String, localRoot: String,
                                    pinnedPaths: Set<String>) async throws -> Int {
        let id = UUID()
        let task = Task {
            try await Self.countDiscrepanciesOffActor(pins: pins, remoteRoot: remoteRoot,
                                                      localRoot: localRoot, pinnedPaths: pinnedPaths)
        }
        countingTask = (id, task)
        defer {
            if countingTask?.id == id { countingTask = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func countDiscrepanciesOffActor(
        pins: [String],
        remoteRoot: String,
        localRoot: String,
        pinnedPaths: Set<String>
    ) async throws -> Int {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let fm = FileManager.default
            var total = 0
            for pin in pins {
                total += try Self.countDiscrepancies(
                    relativePath: pin,
                    remoteRoot: remoteRoot,
                    localRoot: localRoot,
                    pins: pinnedPaths,
                    fm: fm
                )
            }
            return total
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func countDiscrepancies(
        relativePath: String,
        remoteRoot: String,
        localRoot: String,
        pins: Set<String>,
        fm: FileManager
    ) throws -> Int {
        try Task.checkCancellation()
        let remote = relativePath.isEmpty ? remoteRoot : (remoteRoot as NSString).appendingPathComponent(relativePath)
        let local = relativePath.isEmpty ? localRoot : (localRoot as NSString).appendingPathComponent(relativePath)
        let remoteExists = fm.fileExists(atPath: remote)
        let localExists = fm.fileExists(atPath: local)

        if !remoteExists && !localExists { return 0 }

        if remoteExists && !localExists {
            return try countFilesStatic(at: remote, fm: fm)
        }
        if localExists && !remoteExists {
            return try countFilesStatic(at: local, fm: fm)
        }

        let rAttrs = try fm.attributesOfItem(atPath: remote)
        let lAttrs = try fm.attributesOfItem(atPath: local)
        let rIsDir = (rAttrs[.type] as? FileAttributeType) == .typeDirectory
        let lIsDir = (lAttrs[.type] as? FileAttributeType) == .typeDirectory

        if rIsDir && lIsDir {
            let remoteNames = Set(try fm.contentsOfDirectory(atPath: remote).filter { !$0.hasPrefix(".") })
            let localNames = Set(try fm.contentsOfDirectory(atPath: local).filter { !$0.hasPrefix(".") })
            var total = 0
            for name in remoteNames.union(localNames) {
                let child = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                if shouldKeepLocal(relativePath, pins: pins)
                    || shouldKeepLocal(child, pins: pins)
                    || hasPinnedDescendantStatic(child, pins: pins) {
                    total += try countDiscrepancies(
                        relativePath: child,
                        remoteRoot: remoteRoot,
                        localRoot: localRoot,
                        pins: pins,
                        fm: fm
                    )
                }
            }
            return total
        }

        if !rIsDir && !lIsDir {
            let rSize = (rAttrs[.size] as? NSNumber)?.int64Value ?? 0
            let lSize = (lAttrs[.size] as? NSNumber)?.int64Value ?? 0
            let rM = (rAttrs[.modificationDate] as? Date) ?? .distantPast
            let lM = (lAttrs[.modificationDate] as? Date) ?? .distantPast
            if abs(rM.timeIntervalSince(lM)) < 0.001, rSize == lSize { return 0 }
            return 1
        }

        // Type mismatch (file vs folder) is one atomic replacement operation.
        return 1
    }

    nonisolated private static func hasPinnedDescendantStatic(_ relativePath: String, pins: Set<String>) -> Bool {
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        return pins.contains { $0.hasPrefix(prefix) && $0 != relativePath }
    }

    /// Slow tree walk off the actor so browsing can continue during sync.
    nonisolated private static func countPinnedFilesOffActor(
        pins: [String],
        remoteRoot: String,
        localRoot: String
    ) async throws -> Int {
        try await Task.detached(priority: .background) {
            let fm = FileManager.default
            var total = 0
            for pin in pins {
                let remote = pin.isEmpty ? remoteRoot : (remoteRoot as NSString).appendingPathComponent(pin)
                let local = pin.isEmpty ? localRoot : (localRoot as NSString).appendingPathComponent(pin)
                if fm.fileExists(atPath: remote) {
                    total += try Self.countFilesStatic(at: remote, fm: fm)
                } else if fm.fileExists(atPath: local) {
                    total += try Self.countFilesStatic(at: local, fm: fm)
                }
            }
            return total
        }.value
    }

    nonisolated private static func countFilesStaticOffActor(at absPath: String) async throws -> Int {
        try await Task.detached(priority: .background) {
            try Self.countFilesStatic(at: absPath, fm: .default)
        }.value
    }

    nonisolated private static func countFilesStatic(at absPath: String, fm: FileManager) throws -> Int {
        try Task.checkCancellation()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: absPath, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return 1 }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: absPath),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    private func countFiles(at absPath: String) throws -> Int {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: absPath, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return 1 }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: absPath),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                count += 1
            }
        }
        return count
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
            let entries = (try? fm.contentsOfDirectory(atPath: local)) ?? []
            for name in entries where !name.hasPrefix(".") {
                if !shouldKeepLocal(name) && !hasPinnedDescendant(name) {
                    try? fm.removeItem(atPath: join(local, name))
                }
            }
            return
        }

        guard fm.fileExists(atPath: local) else { return }

        if hasPinnedDescendant(relativePath) {
            let entries = (try? fm.contentsOfDirectory(atPath: local)) ?? []
            for name in entries {
                let child = "\(relativePath)/\(name)"
                if !shouldKeepLocal(child) && !hasPinnedDescendant(child) {
                    try? fm.removeItem(atPath: join(local, name))
                }
            }
            return
        }

        try fm.removeItem(atPath: local)
    }

    private func pruneUnpinnedLocal() async throws {
        guard let connection else { return }
        try walkAndPrune(absPath: connection.localPath, relativePath: "")
    }

    private func walkAndPrune(absPath: String, relativePath: String) throws {
        guard fm.fileExists(atPath: absPath) else { return }
        let attrs = try fm.attributesOfItem(atPath: absPath)
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory

        if !isDir {
            // Untracked local files may have appeared during initial adoption.
            // Never treat them as disposable cached copies.
            if !shouldKeepLocal(relativePath), knownSyncedPaths.contains(relativePath) {
                try fm.removeItem(atPath: absPath)
            }
            return
        }

        let entries = try fm.contentsOfDirectory(atPath: absPath).filter { !$0.hasPrefix(".") }
        for name in entries {
            let childRel = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            try walkAndPrune(absPath: join(absPath, name), relativePath: childRel)
        }
        if !relativePath.isEmpty, !shouldKeepLocal(relativePath), !hasPinnedDescendant(relativePath),
           knownSyncedPaths.contains(relativePath), try fm.contentsOfDirectory(atPath: absPath).isEmpty {
            try fm.removeItem(atPath: absPath)
        }
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
        // Leave the actor while copying so listDirectory / navigation stay responsive.
        try await performCopy(from: from, to: to)
        if emitFile {
            let name = (from as NSString).lastPathComponent
            let transferDirection: SyncEvent.TransferDirection? = direction.contains("→remote") ? .upload
                : (direction.contains("remote→") ? .download : nil)
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
        emit(.init(kind: .file, message: "\(direction): \((from as NSString).lastPathComponent)", path: relativePath))
        try await performCopy(from: from, to: to)
        syncTransferDone += 1
        syncProgressDone += 1
    }

    private func stopTransfers() async {
        syncRevision &+= 1
        transferTotalKnown = true
        countingTask?.task.cancel()
        paused = true
        syncing = false
        let tasks = Array(copyTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.result }
    }

    private func performCopy(from: String, to: String) async throws {
        let id = UUID()
        let revision = syncRevision
        let remoteRoot = connection?.remotePath
        let task = Task { try await Self.copyItemOffActor(from: from, to: to, remoteRoot: remoteRoot) }
        copyTasks[id] = task
        defer { copyTasks.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard revision == syncRevision else { throw CancellationError() }
    }

    nonisolated private static func copyItemOffActor(from: String, to: String, remoteRoot: String?) async throws {
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

            try fm.copyItem(atPath: from, toPath: temporary)
            try Task.checkCancellation()
            if let attrs = try? fm.attributesOfItem(atPath: from),
               let mtime = attrs[.modificationDate] as? Date {
                try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: temporary)
            }

            let temporaryURL = URL(fileURLWithPath: temporary)
            let destinationURL = URL(fileURLWithPath: to)
            if let remoteRoot { try validateRemoteRoot(remoteRoot) }
            if fm.fileExists(atPath: to) {
                let sourceType = try fm.attributesOfItem(atPath: temporary)[.type] as? FileAttributeType
                let destinationType = try fm.attributesOfItem(atPath: to)[.type] as? FileAttributeType
                if sourceType != .typeDirectory && destinationType != .typeDirectory {
                    // Sibling POSIX rename is atomic and does not require the metadata
                    // exchange / replacement-directory support often missing on SMB.
                    if Darwin.rename(temporary, to) != 0 {
                        let code = errno
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                                      userInfo: [NSFilePathErrorKey: to])
                    }
                } else {
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
                }
            } else {
                try fm.moveItem(at: temporaryURL, to: destinationURL)
            }
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
            let original = error as NSError
            var details = original.userInfo
            details[NSUnderlyingErrorKey] = original
            details[NSLocalizedDescriptionKey] = "\(error.localizedDescription)\nSource: \(from)\nDestination: \(to)\n\(original.domain) (\(original.code))"
            throw NSError(domain: original.domain, code: original.code, userInfo: details)
        }
    }

    nonisolated private static func filesHaveEqualContents(_ lhs: String, _ rhs: String) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            let lhsHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: lhs))
            let rhsHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: rhs))
            defer {
                try? lhsHandle.close()
                try? rhsHandle.close()
            }

            let chunkSize = 1024 * 1024
            while true {
                try Task.checkCancellation()
                let left = try lhsHandle.read(upToCount: chunkSize) ?? Data()
                let right = try rhsHandle.read(upToCount: chunkSize) ?? Data()
                if left != right { return false }
                if left.isEmpty { return true }
            }
        }.value
    }

    // MARK: - Watchers

    private func startWatchers() {
        guard let connection else { return }
        stopWatchers()

        let localRoot = URL(fileURLWithPath: connection.localPath)
        let remoteURLs = remoteWatchURLs(connection: connection)
        let localURLs = localWatchURLs(connection: connection)

        let remote = DirectoryWatcher { [weak self] _ in
            Task { await self?.handleRemoteRootChange() }
        }
        let local = DirectoryWatcher { [weak self] _ in
            Task { await self?.handleLocalRootChange() }
        }

        // Watchers enqueue their own setup, preserving start/stop order without
        // blocking this actor on a slow NAS listing.
        remoteWatcher = remote
        localWatcher = local
        // Faster poll on network volumes — SMB rarely delivers kernel events.
        remote.start(watching: remoteURLs, interval: 1.0)
        local.start(watching: localURLs.isEmpty ? [localRoot] : localURLs, interval: 1.0)
    }

    private func stopWatchers() {
        remoteWatcher?.stop()
        localWatcher?.stop()
        remoteWatcher = nil
        localWatcher = nil
    }

    /// Re-target remote/local watchers when pins change (nested folders need their own shallow poll).
    private func updateRemoteWatchPaths() {
        guard let connection, let remoteWatcher else { return }
        let remoteURLs = remoteWatchURLs(connection: connection)
        let localURLs = localWatchURLs(connection: connection)
        remoteWatcher.setWatchedURLs(remoteURLs)
        localWatcher?.setWatchedURLs(localURLs.isEmpty
            ? [URL(fileURLWithPath: connection.localPath)]
            : localURLs)
    }

    private func remoteWatchURLs(connection: SyncConnection) -> [URL] {
        watchURLs(root: connection.remotePath)
    }

    private func localWatchURLs(connection: SyncConnection) -> [URL] {
        watchURLs(root: connection.localPath)
    }

    private func watchURLs(root: String) -> [URL] {
        var urls = [URL(fileURLWithPath: root)]
        for pin in pinnedPaths where !pin.isEmpty {
            urls.append(URL(fileURLWithPath: join(root, pin)))
        }
        return urls
    }

    private func handleRemoteRootChange() async {
        await reconcileWatcherChange()
    }

    private func handleLocalRootChange() async {
        await reconcileWatcherChange()
    }

    private func reconcileWatcherChange() async {
        guard !paused, !syncing, !automaticSyncSuspended, !initialMergePending,
              connection != nil, Date() >= suppressUntil else { return }
        let epoch = connectionEpoch
        let revision = syncRevision
        syncing = true
        paused = true
        defer {
            if revision == syncRevision {
                syncing = false
                paused = false
            }
        }
        suppress(for: 0.8)
        syncTransferDone = 0
        syncTransferTotal = 0
        do {
            for pin in pinnedPaths.sorted() {
                guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
                try await syncTree(pin)
            }
            guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending else { return }
            try await refreshPersistedSyncState()
            emit(.init(kind: .complete, message: "Ready", isTransfer: false))
        } catch {
            guard epoch == connectionEpoch, revision == syncRevision, !initialMergePending,
                  !(error is CancellationError) else { return }
            automaticSyncSuspended = true
            emit(.init(kind: .error, message: error.localizedDescription,
                       isRemoteUnavailable: Self.isRemoteUnavailableError(error)))
        }
    }

    // MARK: - Helpers

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

    private func loadPersistedSyncState(for connection: SyncConnection) -> Set<String> {
        let path = (connection.localPath as NSString).appendingPathComponent(".tethwork-sync-state.json")
        guard let data = fm.contents(atPath: path),
              let state = try? JSONDecoder().decode(PersistedSyncState.self, from: data),
              Self.canonicalPath(state.remotePath) == Self.canonicalPath(connection.remotePath)
        else { return [] }
        return Set(state.syncedPaths.map(Self.normalize))
    }

    private func persistSyncState() {
        guard let connection, let path = syncStatePath else { return }
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
        guard fm.fileExists(atPath: remote), fm.fileExists(atPath: local) else { return }
        result.insert(pin)

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: remote, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = fm.enumerator(atPath: remote)
        else { return }

        while let suffix = enumerator.nextObject() as? String {
            try Task.checkCancellation()
            if suffix.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                enumerator.skipDescendants()
                continue
            }
            let relative = pin.isEmpty ? suffix : "\(pin)/\(suffix)"
            let localPath = (localRoot as NSString).appendingPathComponent(relative)
            if fm.fileExists(atPath: localPath) {
                result.insert(normalize(relative))
            }
        }
    }

    private func removeKnownPath(_ path: String) {
        let normalized = Self.normalize(path)
        if normalized.isEmpty {
            knownSyncedPaths.removeAll()
        } else {
            knownSyncedPaths = knownSyncedPaths.filter {
                $0 != normalized && !$0.hasPrefix(normalized + "/")
            }
        }
    }

    private func remapKnownPaths(from source: String, to destination: String) {
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
    }

    private func suppress(for seconds: TimeInterval) {
        suppressUntil = Date().addingTimeInterval(seconds)
    }

    private func emit(_ event: SyncEvent) {
        eventHandler?(event)
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
        let normalized = Set(paths.map(normalize))
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

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected"
        case .remoteUnavailable(let path):
            return "Remote path unavailable: \(path)"
        case .notFound(let path):
            return "Folder not found: \(path)"
        case .invalidMove(let message):
            return message
        case .overlappingRoots:
            return "The network and local folders must not be the same or contain one another."
        }
    }
}
