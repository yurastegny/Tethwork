import Darwin
import Foundation

/// Server-side trash stored on the network volume itself.
///
/// Deleted items are moved (not copied) into a hidden folder at the volume root:
///
///     .tethwork-trash/
///         index.json            metadata for every item (original path, date)
///         .index.lock           cross-process guard for read-modify-write cycles
///         <uuid>/<name>         the deleted file or folder itself
///
/// Because the payload stays on the share, every Mac connected to the same
/// volume sees the same trash. Items older than `retentionDays` are purged
/// automatically by `purgeExpired`.
enum TrashStore {
    static let folderName = ".tethwork-trash"
    static let retentionDays = 15
    static let retentionInterval: TimeInterval = TimeInterval(retentionDays) * 86_400

    private static let indexFileName = "index.json"
    private static let lockFileName = ".index.lock"
    private static let internalNames: Set<String> = [
        ".tethwork-trash",
        ".tethwork-sync-state.json",
        ".tethwork-verification-cache.json",
        ".tethwork-tombstones.json",
        ".DS_Store"
    ]

    struct RestoreResult {
        var item: TrashItem
        /// Path relative to the volume root after restore (may be renamed on conflict).
        var restoredPath: String
    }

    struct DeletionError: LocalizedError {
        let deletedIDs: Set<String>
        let failedIDs: Set<String>
        let details: [String]
        var cause: String? = nil
        var hasBusyItems: Bool = false

        var errorDescription: String? {
            let summary = deletedIDs.isEmpty
                ? "Could not delete the selected items from Trash."
                : "Deleted \(deletedIDs.count) item(s), but some Trash operations failed."
            let extra = details.count > 5 ? "\n…and \(details.count - 5) more errors." : ""
            let hint = hasBusyItems
                ? "\n" + String(localized: "The server still reports an item as busy after several attempts. Close Quick Look or other apps using it, then retry. Items that could not be removed have not been marked as deleted.")
                : ""
            return (cause.map { $0 + "\n" } ?? "") + summary + hint + "\n" + details.prefix(5).joined(separator: "\n\n") + extra
        }
    }

    private struct Index: Codable {
        var version: Int
        var items: [TrashItem]

        init(version: Int = 1, items: [TrashItem] = []) {
            self.version = version
            self.items = items
        }
    }

    // MARK: - Paths

    static func trashRoot(remoteRoot: String) -> String {
        (remoteRoot as NSString).appendingPathComponent(folderName)
    }

    static func payloadDirectory(remoteRoot: String, id: String) -> String {
        guard isValidID(id) else { return trashRoot(remoteRoot: remoteRoot) }
        return (trashRoot(remoteRoot: remoteRoot) as NSString).appendingPathComponent(id)
    }

    static func payloadPath(remoteRoot: String, item: TrashItem) -> String {
        guard isValidItem(item) else { return trashRoot(remoteRoot: remoteRoot) }
        return (payloadDirectory(remoteRoot: remoteRoot, id: item.id) as NSString)
            .appendingPathComponent(item.name)
    }

    private static func indexPath(remoteRoot: String) -> String {
        (trashRoot(remoteRoot: remoteRoot) as NSString).appendingPathComponent(indexFileName)
    }

    private static func lockPath(remoteRoot: String) -> String {
        (trashRoot(remoteRoot: remoteRoot) as NSString).appendingPathComponent(lockFileName)
    }

    static func normalize(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Validation

    /// Payload containers are UUID/directory names, never paths. Rejecting
    /// separators and dot segments prevents a damaged or malicious `index.json`
    /// from addressing files outside `.tethwork-trash`.
    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, !id.hasPrefix("."), id != "..", id != "." else { return false }
        guard !id.contains("/"), !id.contains("\\"), !id.contains(":") else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// A payload file name must be a single path component.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255, name != ".", name != ".." else { return false }
        // A colon is a legal POSIX filename character and appears on SMB shares
        // (for example "Lemon:Milk"); only real separators are unsafe here.
        guard !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return !internalNames.contains(name) && !name.hasPrefix(".tethwork-copy-")
            && !name.hasPrefix(".tethwork-trash-cleanup-")
            && !name.hasPrefix(".tethwork-backup-")
    }

    /// Returns a normalized relative path only when it cannot escape the volume
    /// root or address Tethwork's own state.
    static func safeRelativePath(_ raw: String) -> String? {
        guard !raw.contains("\0"),
              !raw.split(separator: "/").contains(where: {
                  $0.hasPrefix(".tethwork-copy-") || $0.hasPrefix(".tethwork-backup-") || $0.hasPrefix(".tethwork-trash-cleanup-")
              }) else { return nil }
        let normalized = normalize(raw)
        guard !normalized.isEmpty, normalized.count <= 4096 else { return nil }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        guard !components.contains(where: { internalNames.contains(String($0)) }) else { return nil }
        guard !normalized.hasPrefix(".tethwork-copy-"), !normalized.hasPrefix(".tethwork-backup-") else { return nil }
        // A normalised path is relative by construction; reject absolute input.
        guard !raw.hasPrefix("/"), !raw.hasPrefix("\\") else { return nil }
        return normalized
    }

    static func isValidItem(_ item: TrashItem) -> Bool {
        isValidID(item.id)
            && isValidName(item.name)
            && safeRelativePath(item.originalPath) != nil
            && item.size >= 0
    }

    /// True when the volume root still contains (or is) the candidate path after
    /// resolving existing symlinked ancestors. Used before every destructive write.
    static func isContained(_ candidate: String, in root: String) -> Bool {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        var candidateURL = URL(fileURLWithPath: candidate).standardizedFileURL
        guard candidateURL.path == rootURL.path || candidateURL.path.hasPrefix(rootURL.path + "/") else {
            return false
        }
        // Resolve the nearest existing ancestor: a symlink inside the volume must
        // not redirect payloads or restores outside of it.
        let fm = FileManager.default
        var guardCount = 0
        while !fm.fileExists(atPath: candidateURL.path), candidateURL.path != "/", guardCount < 512 {
            candidateURL.deleteLastPathComponent()
            guardCount += 1
        }
        let resolved = candidateURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        return resolved.path == resolvedRoot.path || resolved.path.hasPrefix(resolvedRoot.path + "/")
    }

    // MARK: - Reading

    /// Items currently in the trash, newest first. Payloads that are missing
    /// from the index (another Mac, interrupted write) are recovered from disk.
    ///
    /// This method is intentionally read-only. Recovery happens on every read so
    /// a lost index never hides recoverable files, but `loadItems` never rewrites
    /// the shared index (which could race another client).
    static func loadItems(remoteRoot: String, now: Date = Date()) -> [TrashItem] {
        guard isContained(trashRoot(remoteRoot: remoteRoot), in: remoteRoot) else { return [] }
        let fm = FileManager.default
        let index = readIndex(remoteRoot: remoteRoot)
        var items: [TrashItem] = []
        var seenIDs = Set<String>()

        for item in index.items where isValidItem(item) {
            guard seenIDs.insert(item.id).inserted else { continue }
            let payload = payloadPath(remoteRoot: remoteRoot, item: item)
            let directory = payloadDirectory(remoteRoot: remoteRoot, id: item.id)
            guard isContained(payload, in: trashRoot(remoteRoot: remoteRoot)) else { continue }

            if fm.fileExists(atPath: payload) {
                items.append(item)
            } else if confirmedMissing(item.name, in: directory) ||
                        confirmedMissing(item.id, in: trashRoot(remoteRoot: remoteRoot)) {
                // Drop stale metadata from the in-memory result only. A later
                // mutation persists the pruned index.
            } else {
                // fileExists also returns false on access errors. Do not discard
                // the original path/pin/date of an item we cannot currently inspect.
                items.append(item)
            }
        }

        // Recover payload folders that are not described by the index.
        let knownIDs = Set(items.map(\.id))
        let root = trashRoot(remoteRoot: remoteRoot)
        if let children = try? fm.contentsOfDirectory(atPath: root) {
            for id in children where !id.hasPrefix(".") && !knownIDs.contains(id) {
                guard isValidID(id) else { continue }
                let directory = (root as NSString).appendingPathComponent(id)
                guard let names = try? fm.contentsOfDirectory(atPath: directory),
                      let name = names.first(where: { isValidName($0) }),
                      isValidName(name)
                else { continue }

                let payload = (directory as NSString).appendingPathComponent(name)
                guard isContained(payload, in: root),
                      let attrs = try? fm.attributesOfItem(atPath: payload)
                else { continue }
                let isDirectory = (attrs[.type] as? FileAttributeType) == .typeDirectory
                let size = isDirectory ? 0 : ((attrs[.size] as? NSNumber)?.int64Value ?? 0)
                // Use the payload folder's creation date — the item itself keeps its
                // original modification date and would otherwise look long-expired.
                let dirAttrs = try? fm.attributesOfItem(atPath: directory)
                let deletedAt = (dirAttrs?[.creationDate] as? Date) ?? now
                items.append(
                    TrashItem(
                        id: id,
                        name: name,
                        originalPath: name,
                        isDirectory: isDirectory,
                        size: size,
                        deletedAt: deletedAt,
                        wasPinned: false
                    )
                )
            }
        }

        return items.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Checks the shared index before a local-only file is uploaded. A path that
    /// was deleted on another Mac (and is still recoverable in Trash) must not be
    /// resurrected by this Mac's stale copy.
    static func containsTrashedPath(_ relativePath: String, remoteRoot: String, now: Date = Date()) -> Bool {
        guard let normalized = safeRelativePath(relativePath) else { return false }
        return loadItems(remoteRoot: remoteRoot, now: now).contains { item in
            if item.originalPath == normalized { return true }
            return item.isDirectory && normalized.hasPrefix(item.originalPath + "/")
        }
    }

    private static func readIndex(remoteRoot: String) -> Index {
        guard let data = FileManager.default.contents(atPath: indexPath(remoteRoot: remoteRoot)) else {
            return Index()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let index = try decoder.decode(Index.self, from: data)
            let valid = index.items.filter(isValidItem)
            if valid.count != index.items.count {
                quarantineIndex(remoteRoot: remoteRoot, reason: "contains invalid entries")
            }
            return Index(version: index.version, items: valid)
        } catch {
            quarantineIndex(remoteRoot: remoteRoot, reason: error.localizedDescription)
            return Index()
        }
    }

    /// Keeps a copy of a corrupt index for diagnosis instead of silently
    /// overwriting data that another Mac may still understand.
    private static func quarantineIndex(remoteRoot: String, reason: String) {
        let source = indexPath(remoteRoot: remoteRoot)
        guard FileManager.default.fileExists(atPath: source) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let name = ".index.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json"
        let destination = (trashRoot(remoteRoot: remoteRoot) as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(atPath: source, toPath: destination)
            NSLog("Tethwork Trash index quarantined at %@: %@", destination, reason)
        } catch {
            NSLog("Tethwork could not quarantine a damaged Trash index at %@: %@", source, error.localizedDescription)
        }
    }

    private static func writeIndex(_ items: [TrashItem], remoteRoot: String) throws {
        try requireRemoteRoot(remoteRoot)
        let fm = FileManager.default
        try fm.createDirectory(atPath: trashRoot(remoteRoot: remoteRoot), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Index(items: items.sorted { $0.deletedAt > $1.deletedAt }))

        // Atomic write: Foundation writes a sibling temp file and renames it over
        // the target, so a failed write never truncates the existing index.
        try data.write(
            to: URL(fileURLWithPath: indexPath(remoteRoot: remoteRoot)),
            options: .atomic
        )
    }

    // MARK: - Cross-process index lock

    private static let indexLock = NSRecursiveLock()
    private static let lockDepthKey = "app.tethwork.trash.index-lock-depth"

    /// Serializes read-modify-write cycles between threads and, via `flock`, other
    /// Tethwork instances on the same Mac. SMB flock support is best-effort: the
    /// in-process lock still prevents the common same-app race.
    private static func withIndexLock<T>(remoteRoot: String, _ body: () throws -> T) throws -> T {
        indexLock.lock()
        defer { indexLock.unlock() }

        let depth = Thread.current.threadDictionary[lockDepthKey] as? Int ?? 0
        if depth > 0 {
            Thread.current.threadDictionary[lockDepthKey] = depth + 1
            defer { Thread.current.threadDictionary[lockDepthKey] = depth }
            return try body()
        }

        try requireRemoteRoot(remoteRoot)
        guard isContained(trashRoot(remoteRoot: remoteRoot), in: remoteRoot) else {
            throw SyncError.invalidMove("Trash directory points outside the network volume")
        }
        try FileManager.default.createDirectory(atPath: trashRoot(remoteRoot: remoteRoot),
                                                 withIntermediateDirectories: true)
        try requireTrashDirectory(trashRoot(remoteRoot: remoteRoot))
        let fd = open(lockPath(remoteRoot: remoteRoot), O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        // Nonblocking acquisition avoids hanging the engine forever on a stale NAS lock.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        Thread.current.threadDictionary[lockDepthKey] = 1
        defer {
            Thread.current.threadDictionary[lockDepthKey] = 0
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try body()
    }

    // MARK: - Mutations

    struct MoveOutcome {
        var moved: [TrashItem] = []
        /// Relative paths that could not be moved (permissions, vanished, …).
        var failures: [String] = []
        var failureReasons: [String: String] = [:]
        /// Payloads moved successfully but the shared index could not be updated.
        /// They remain recoverable from disk, but the caller must surface this.
        var indexError: String? = nil
    }

    /// Moves several items into the trash in one batch. The index is read and
    /// written once, which matters when deleting hundreds of files over SMB.
    static func moveToTrash(
        relativePaths: [String],
        remoteRoot: String,
        wasPinned: (String) -> Bool,
        origin: TrashOrigin = .app,
        now: Date = Date()
    ) -> MoveOutcome {
        let orderedPaths = Set(relativePaths.compactMap(safeRelativePath))
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
            }
        var outcome = MoveOutcome()
        guard !orderedPaths.isEmpty else { return outcome }

        do { try withIndexLock(remoteRoot: remoteRoot) {
            var items = readIndex(remoteRoot: remoteRoot).items

            // Move parents first. A selected folder carries its whole tree, so its
            // selected children must not become separate trash records.
            for normalized in orderedPaths {
                if outcome.moved.contains(where: {
                    $0.isDirectory && normalized.hasPrefix($0.originalPath + "/")
                }) { continue }
                do {
                    let item = try moveSingle(
                        relativePath: normalized,
                        remoteRoot: remoteRoot,
                        wasPinned: wasPinned(normalized),
                        origin: origin,
                        now: now
                    )
                    items.append(item)
                    outcome.moved.append(item)
                } catch {
                    outcome.failures.append(normalized)
                    outcome.failureReasons[normalized] = error.localizedDescription
                }
            }

            if !outcome.moved.isEmpty {
                do {
                    try writeIndex(items, remoteRoot: remoteRoot)
                } catch {
                    outcome.indexError = fileErrorDiagnostic(error).details
                    NSLog("Tethwork moved %d item(s) to Trash but could not update %@: %@",
                          outcome.moved.count, indexPath(remoteRoot: remoteRoot), error.localizedDescription)
                }
            }
        } } catch {
            outcome.failures += orderedPaths
            for path in orderedPaths { outcome.failureReasons[path] = error.localizedDescription }
        }
        return outcome
    }

    /// Moves a single item from the volume into the trash. Returns the record.
    @discardableResult
    static func moveToTrash(
        relativePath: String,
        remoteRoot: String,
        wasPinned: Bool,
        origin: TrashOrigin = .app,
        now: Date = Date()
    ) throws -> TrashItem {
        guard let normalized = safeRelativePath(relativePath) else {
            throw SyncError.invalidMove("The volume root or an internal path cannot be deleted")
        }
        return try withIndexLock(remoteRoot: remoteRoot) {
            let item = try moveSingle(
                relativePath: normalized,
                remoteRoot: remoteRoot,
                wasPinned: wasPinned,
                origin: origin,
                now: now
            )
            // Append without a full trash scan: local Finder deletions can arrive
            // one by one and each extra directory walk would hit the network again.
            var items = readIndex(remoteRoot: remoteRoot).items
            items.removeAll { $0.id == item.id }
            items.append(item)
            try writeIndex(items, remoteRoot: remoteRoot)
            return item
        }
    }

    private static func moveSingle(
        relativePath normalized: String,
        remoteRoot: String,
        wasPinned: Bool,
        origin: TrashOrigin,
        now: Date
    ) throws -> TrashItem {
        let fm = FileManager.default
        guard let safe = safeRelativePath(normalized) else {
            throw SyncError.invalidMove("Invalid item path: \(normalized)")
        }
        let source = (remoteRoot as NSString).appendingPathComponent(safe)
        guard source != remoteRoot, isContained(source, in: remoteRoot) else {
            throw SyncError.invalidMove("Refusing to delete outside the network volume: \(normalized)")
        }
        let attrs = try fm.attributesOfItem(atPath: source)
        let isDirectory = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let size = isDirectory ? 0 : ((attrs[.size] as? NSNumber)?.int64Value ?? 0)
        let name = (safe as NSString).lastPathComponent
        guard isValidName(name) else {
            throw SyncError.invalidMove("Invalid item name: \(name)")
        }
        let id = UUID().uuidString

        let directory = payloadDirectory(remoteRoot: remoteRoot, id: id)
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let destination = (directory as NSString).appendingPathComponent(name)
        guard isContained(destination, in: trashRoot(remoteRoot: remoteRoot)) else {
            try? fm.removeItem(atPath: directory)
            throw SyncError.invalidMove("Refusing to write outside the Trash container: \(name)")
        }

        do {
            // One server-side rename, without a recursive copy fallback.
            guard Darwin.rename(source, destination) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSFilePathErrorKey: source])
            }
        } catch {
            try? fm.removeItem(atPath: directory)
            throw error
        }

        return TrashItem(
            id: id,
            name: name,
            originalPath: safe,
            isDirectory: isDirectory,
            size: size,
            deletedAt: now,
            wasPinned: wasPinned,
            origin: origin
        )
    }

    /// Restores the given items. A name that is already taken gets a Finder-style
    /// `name 2` suffix instead of overwriting existing data.
    static func restore(
        ids: Set<String>,
        remoteRoot: String,
        now: Date = Date()
    ) throws -> [RestoreResult] {
        guard !ids.isEmpty else { return [] }
        try requireRemoteRoot(remoteRoot)
        return try withIndexLock(remoteRoot: remoteRoot) {
            let fm = FileManager.default
            var items = loadItems(remoteRoot: remoteRoot, now: now)
            var results: [RestoreResult] = []
            var restoredFolders: [(original: String, restored: String)] = []
            var failure: Error?

            // Restore enclosing folders first so independently trashed descendants
            // go back inside them, including when the folder needed a new name.
            let orderedIDs = items.filter { ids.contains($0.id) }
                .sorted { lhs, rhs in
                    lhs.originalPath.count == rhs.originalPath.count
                        ? lhs.originalPath < rhs.originalPath
                        : lhs.originalPath.count < rhs.originalPath.count
                }
                .map(\.id)
            for id in orderedIDs {
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                let item = items[index]
                guard isValidItem(item), let safeOriginal = safeRelativePath(item.originalPath) else {
                    // Corrupted metadata must never address a path outside the volume.
                    items.remove(at: index)
                    continue
                }
                let payload = payloadPath(remoteRoot: remoteRoot, item: item)
                let payloadRoot = trashRoot(remoteRoot: remoteRoot)
                guard isContained(payload, in: payloadRoot) else {
                    failure = failure ?? SyncError.invalidMove("Trash payload points outside the container: \(item.name)")
                    continue
                }
                guard fm.fileExists(atPath: payload) else {
                    items.remove(at: index)
                    continue
                }

                let ancestor = restoredFolders
                    .filter { safeOriginal.hasPrefix($0.original + "/") }
                    .max { $0.original.count < $1.original.count }
                let requestedPath = ancestor.map {
                    $0.restored + String(safeOriginal.dropFirst($0.original.count))
                } ?? safeOriginal
                guard let safeRequested = safeRelativePath(requestedPath) else {
                    items.remove(at: index)
                    continue
                }
                let restoredPath = restoreDestination(
                    for: item,
                    remoteRoot: remoteRoot,
                    requestedPath: safeRequested
                )
                guard let safeRestored = safeRelativePath(restoredPath),
                      isContained((remoteRoot as NSString).appendingPathComponent(safeRestored), in: remoteRoot)
                else {
                    failure = failure ?? SyncError.invalidMove("Refusing to restore outside the network volume: \(restoredPath)")
                    continue
                }
                let destination = (remoteRoot as NSString).appendingPathComponent(safeRestored)
                do {
                    try fm.createDirectory(
                        atPath: (destination as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true
                    )
                    // Re-check after creating parents: a pre-existing symlinked
                    // folder could otherwise redirect the restore outside the share.
                    guard isContained(destination, in: remoteRoot) else {
                        throw SyncError.invalidMove("Refusing to restore outside the network volume: \(safeRestored)")
                    }
                    try fm.moveItem(atPath: payload, toPath: destination)
                    try? fm.removeItem(atPath: payloadDirectory(remoteRoot: remoteRoot, id: id))

                    items.remove(at: index)
                    results.append(RestoreResult(item: item, restoredPath: safeRestored))
                    if item.isDirectory {
                        restoredFolders.append((original: safeOriginal, restored: safeRestored))
                    }
                } catch {
                    failure = failure ?? error
                    // Keep processing the rest of the batch so one bad item does
                    // not block recovering everything else.
                }
            }

            do {
                try writeIndex(items, remoteRoot: remoteRoot)
            } catch {
                failure = failure ?? error
            }
            if let failure { throw failure }
            return results
        }
    }

    /// Permanently deletes the given items from the trash.
    static func deletePermanently(ids: Set<String>, remoteRoot: String, now: Date = Date(),
                                  remove: (String) throws -> Void = { try FileManager.default.removeItem(atPath: $0) }) throws {
        guard !ids.isEmpty else { return }
        // Validate the entire batch before deleting anything. IDs name direct
        // payload containers, never arbitrary paths from a damaged index.
        for id in ids where !isValidID(id) {
            throw SyncError.invalidMove("Invalid Trash item ID: \(id)")
        }
        try requireRemoteRoot(remoteRoot)
        try withIndexLock(remoteRoot: remoteRoot) {
            let root = trashRoot(remoteRoot: remoteRoot)
            if confirmedMissing(folderName, in: remoteRoot) { return }
            try requireTrashDirectory(root)
            // Reading the index directly preserves records for unreadable payloads.
            // Requested orphan IDs can still be deleted even if the index is missing.
            let items = readIndex(remoteRoot: remoteRoot).items
            var outcome = removeTrashChildren(ids, root: root, items: items, remove: remove)
            let remaining = items.filter { !outcome.deletedIDs.contains($0.id) }
            if remaining != items {
                do {
                    try writeIndex(remaining, remoteRoot: remoteRoot)
                } catch {
                    let diagnostic = fileErrorDiagnostic(error)
                    if outcome.cause == nil { outcome.cause = diagnostic.cause }
                    outcome.details.append("Could not update Trash index: \(indexPath(remoteRoot: remoteRoot))\n\(diagnostic.details)")
                }
            }
            if !outcome.details.isEmpty {
                let failure = DeletionError(deletedIDs: outcome.deletedIDs, failedIDs: outcome.failedIDs,
                                            details: outcome.details, cause: outcome.cause, hasBusyItems: outcome.hasBusyItems)
                NSLog("Trash deletion failed on %@: %@", remoteRoot, failure.localizedDescription)
                throw failure
            }
        }
    }

    /// Empty the contents, including hidden/orphaned payloads, but preserve the
    /// service directory: a server may allow writing inside it but forbid unlinking it.
    static func empty(remoteRoot: String,
                      remove: (String) throws -> Void = { try FileManager.default.removeItem(atPath: $0) }) throws {
        try requireRemoteRoot(remoteRoot)
        try withIndexLock(remoteRoot: remoteRoot) {
            let fm = FileManager.default
            let root = trashRoot(remoteRoot: remoteRoot)
            if confirmedMissing(folderName, in: remoteRoot) { return }
            try requireTrashDirectory(root)
            let items = readIndex(remoteRoot: remoteRoot).items
            let children = try fm.contentsOfDirectory(atPath: root)
            let indexAttributes = try? fm.attributesOfItem(atPath: indexPath(remoteRoot: remoteRoot))
            let regularIndex = indexAttributes?[.type] as? FileAttributeType == .typeRegular
            let targets = Set(children.filter { child in
                if child == lockFileName { return false }
                return child != indexFileName || !regularIndex
            })
            var outcome = removeTrashChildren(targets, root: root, items: items, remove: remove)
            let remaining = items.filter { outcome.failedIDs.contains($0.id) }
            // Keep the old index until payload removals have finished. On partial
            // failure, retain the original metadata for everything still in Trash.
            if outcome.failedIDs.isEmpty || remaining != items {
                do {
                    try writeIndex(remaining, remoteRoot: remoteRoot)
                } catch {
                    let diagnostic = fileErrorDiagnostic(error)
                    if outcome.cause == nil { outcome.cause = diagnostic.cause }
                    outcome.details.append("Could not update Trash index: \(indexPath(remoteRoot: remoteRoot))\n\(diagnostic.details)")
                }
            }
            if !outcome.details.isEmpty {
                let failure = DeletionError(deletedIDs: outcome.deletedIDs, failedIDs: outcome.failedIDs,
                                            details: outcome.details, cause: outcome.cause, hasBusyItems: outcome.hasBusyItems)
                NSLog("Trash empty failed on %@: %@", remoteRoot, failure.localizedDescription)
                throw failure
            }
        }
    }

    /// Removes items whose 15-day retention has elapsed. Returns how many were purged.
    @discardableResult
    static func purgeExpired(remoteRoot: String, now: Date = Date()) -> Int {
        let items = loadItems(remoteRoot: remoteRoot, now: now)
        let expired = items.filter { now.timeIntervalSince($0.deletedAt) >= retentionInterval }
        guard !expired.isEmpty else { return 0 }

        let expiredIDs = Set(expired.map(\.id))
        do {
            try deletePermanently(ids: expiredIDs, remoteRoot: remoteRoot, now: now)
            return expiredIDs.count
        } catch let error as DeletionError {
            return error.deletedIDs.count
        } catch {
            return 0
        }
    }

    // MARK: - Helpers

    private struct RemovalOutcome {
        var deletedIDs = Set<String>()
        var failedIDs = Set<String>()
        var details: [String] = []
        var cause: String?
        var hasBusyItems = false
    }

    /// SMB can briefly retain a handle after a thumbnail is cancelled. Retry only
    /// EBUSY, never permission failures, and never change flags or force-unmount.
    /// These synchronous waits run on the caller's background Trash worker.
    static func removeWithBusyRetry(atPath path: String,
                                    remove: (String) throws -> Void,
                                    pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        let delays: [TimeInterval] = [0.15, 0.35, 0.75]
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            do {
                try remove(path)
                return
            } catch {
                guard isBusyError(error), attempt < delays.count else { throw error }
                pause(delays[attempt])
            }
        }
    }

    static func isBusyError(_ error: Error) -> Bool {
        var current = error as NSError
        var seen = Set<ObjectIdentifier>()
        for _ in 0..<8 {
            guard seen.insert(ObjectIdentifier(current)).inserted else { return false }
            if current.domain == NSPOSIXErrorDomain && current.code == Int(EBUSY) { return true }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }

    /// Callers supply validated IDs or direct child names returned by the filesystem.
    /// FileManager removes symbolic links themselves, never their external targets.
    private static func removeTrashChildren(_ ids: Set<String>, root: String, items: [TrashItem],
                                            remove: (String) throws -> Void) -> RemovalOutcome {
        var outcome = RemovalOutcome()
        for id in ids.sorted() {
            guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"), !id.contains("\0") else {
                outcome.failedIDs.insert(id)
                outcome.details.append("Invalid Trash item name: \(id)")
                continue
            }
            let path = (root as NSString).appendingPathComponent(id)
            // Unlink a direct child symlink itself, but never follow a symlinked parent.
            guard isContained((path as NSString).deletingLastPathComponent, in: root) else {
                outcome.failedIDs.insert(id)
                outcome.details.append("Refusing to delete outside Trash: \(path)")
                continue
            }
            do {
                try removeWithBusyRetry(atPath: path, remove: remove)
                outcome.deletedIDs.insert(id)
            } catch {
                // Finder metadata is not a Trash payload. Some SMB servers keep
                // this name visible even to stat after unlink reports ENOENT.
                // Do not turn that harmless inconsistency into a batch failure.
                if id == ".DS_Store", isMissingItemError(error) { continue }
                if confirmedMissing(id, in: root) {
                    outcome.deletedIDs.insert(id)
                } else {
                    outcome.failedIDs.insert(id)
                    outcome.hasBusyItems = outcome.hasBusyItems || isBusyError(error)
                    let name = items.first { $0.id == id }?.name ?? id
                    let diagnostic = fileErrorDiagnostic(error)
                    if outcome.cause == nil { outcome.cause = diagnostic.cause }
                    outcome.details.append("\(name)\n\(path)\n\(diagnostic.details)")
                }
            }
        }
        return outcome
    }

    /// Use the underlying cause, not a potentially misleading outer Cocoa code.
    private static func isMissingItemError(_ error: Error) -> Bool {
        var current = error as NSError
        var seen = Set<ObjectIdentifier>()
        for _ in 0..<8 {
            guard seen.insert(ObjectIdentifier(current)).inserted else { return false }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                current = underlying
                continue
            }
            return (current.domain == NSPOSIXErrorDomain && current.code == Int(ENOENT)) ||
                (current.domain == NSCocoaErrorDomain && current.code == NSFileNoSuchFileError)
        }
        return false
    }

    /// Cocoa often wraps the useful server/POSIX error in NSUnderlyingErrorKey.
    /// Put that cause first instead of making the UI show only a generic summary.
    static func fileErrorDiagnostic(_ error: Error) -> (cause: String, details: String) {
        var current = error as NSError
        var lines: [String] = []
        var seen = Set<ObjectIdentifier>()
        for _ in 0..<8 {
            guard seen.insert(ObjectIdentifier(current)).inserted else { break }
            lines.append("\(current.domain) (\(current.code)): \(current.localizedDescription)")
            if let reason = current.localizedFailureReason { lines.append(reason) }
            if let path = current.userInfo[NSFilePathErrorKey] as? String { lines.append("Path: \(path)") }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return ("\(current.domain) (\(current.code)): \(current.localizedDescription)", lines.joined(separator: "\n"))
    }

    /// Require a readable parent so an offline share/permission failure is not
    /// mistaken for deletion. SMB can retain deleted names in its listing cache;
    /// in that case an explicit ENOENT from lstat also confirms absence. Do not
    /// follow symlinks: a dangling link still needs to be deleted.
    static func confirmedMissing(_ name: String, in directory: String,
                                 list: (String) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0) }) -> Bool {
        guard let names = try? list(directory) else { return false }
        if !names.contains(name) { return true }
        let path = (directory as NSString).appendingPathComponent(name)
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }

    private static func requireRemoteRoot(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SyncError.remoteUnavailable(path)
        }
    }

    private static func requireTrashDirectory(_ path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw SyncError.invalidMove("Trash is not a regular directory; refusing to follow a link: \(path)")
        }
    }

    private static func restoreDestination(for item: TrashItem, remoteRoot: String, requestedPath: String) -> String {
        let fm = FileManager.default
        let original = normalize(requestedPath)
        let absolute = (remoteRoot as NSString).appendingPathComponent(original)
        if !fm.fileExists(atPath: absolute) { return original }

        let parent = (original as NSString).deletingLastPathComponent
        let parentPath = parent == "." ? "" : parent
        let name = item.name
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let stem = base.isEmpty ? name : base

        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = parentPath.isEmpty ? candidateName : "\(parentPath)/\(candidateName)"
            let candidateAbsolute = (remoteRoot as NSString).appendingPathComponent(candidate)
            if !fm.fileExists(atPath: candidateAbsolute) {
                return candidate
            }
            index += 1
        }
    }
}
