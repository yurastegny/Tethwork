import Foundation

/// Server-side trash stored on the network volume itself.
///
/// Deleted items are moved (not copied) into a hidden folder at the volume root:
///
///     .tethwork-trash/
///         index.json            metadata for every item (original path, date)
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

        var errorDescription: String? {
            let summary = deletedIDs.isEmpty
                ? "Could not delete the selected items from Trash."
                : "Deleted \(deletedIDs.count) item(s), but some Trash operations failed."
            let extra = details.count > 5 ? "\n…and \(details.count - 5) more errors." : ""
            return (cause.map { $0 + "\n" } ?? "") + summary + "\n" + details.prefix(5).joined(separator: "\n\n") + extra
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
        (trashRoot(remoteRoot: remoteRoot) as NSString).appendingPathComponent(id)
    }

    static func payloadPath(remoteRoot: String, item: TrashItem) -> String {
        (payloadDirectory(remoteRoot: remoteRoot, id: item.id) as NSString)
            .appendingPathComponent(item.name)
    }

    private static func indexPath(remoteRoot: String) -> String {
        (trashRoot(remoteRoot: remoteRoot) as NSString).appendingPathComponent(indexFileName)
    }

    static func normalize(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Reading

    /// Items currently in the trash, newest first. Payloads that are missing
    /// from the index (another Mac, interrupted write) are recovered from disk.
    static func loadItems(remoteRoot: String, now: Date = Date()) -> [TrashItem] {
        let fm = FileManager.default
        let index = readIndex(remoteRoot: remoteRoot)
        var items: [TrashItem] = []
        var indexChanged = false

        for item in index.items {
            if fm.fileExists(atPath: payloadPath(remoteRoot: remoteRoot, item: item)) {
                items.append(item)
            } else if confirmedMissing(item.name, in: payloadDirectory(remoteRoot: remoteRoot, id: item.id)) ||
                        confirmedMissing(item.id, in: trashRoot(remoteRoot: remoteRoot)) {
                indexChanged = true
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
                let directory = (root as NSString).appendingPathComponent(id)
                guard let names = try? fm.contentsOfDirectory(atPath: directory),
                      let name = names.first(where: { !$0.hasPrefix(".") })
                else { continue }

                let payload = (directory as NSString).appendingPathComponent(name)
                let dirAttrs = try? fm.attributesOfItem(atPath: directory)
                let attrs = try? fm.attributesOfItem(atPath: payload)
                let isDirectory = (attrs?[.type] as? FileAttributeType) == .typeDirectory
                let size = isDirectory ? 0 : ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
                // Use the payload folder's creation date — the item itself keeps its
                // original modification date and would otherwise look long-expired.
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
                indexChanged = true
            }
        }

        if indexChanged {
            try? writeIndex(items, remoteRoot: remoteRoot)
        }
        return items.sorted { $0.deletedAt > $1.deletedAt }
    }

    private static func readIndex(remoteRoot: String) -> Index {
        guard let data = FileManager.default.contents(atPath: indexPath(remoteRoot: remoteRoot)) else {
            return Index()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Index.self, from: data)) ?? Index()
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

    // MARK: - Mutations

    struct MoveOutcome {
        var moved: [TrashItem] = []
        /// Relative paths that could not be moved (permissions, vanished, …).
        var failures: [String] = []
        var failureReasons: [String: String] = [:]
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
        var items = loadItems(remoteRoot: remoteRoot, now: now)
        var outcome = MoveOutcome()

        defer {
            if !outcome.moved.isEmpty {
                try? writeIndex(items, remoteRoot: remoteRoot)
            }
        }

        // Move parents first. A selected folder carries its whole tree, so its
        // selected children must not become separate trash records.
        let orderedPaths = Set(relativePaths.map(normalize).filter { !$0.isEmpty })
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
            }
        for relativePath in orderedPaths {
            let normalized = normalize(relativePath)
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
        let normalized = normalize(relativePath)
        guard !normalized.isEmpty else {
            throw SyncError.invalidMove("The volume root cannot be deleted")
        }
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

    private static func moveSingle(
        relativePath normalized: String,
        remoteRoot: String,
        wasPinned: Bool,
        origin: TrashOrigin,
        now: Date
    ) throws -> TrashItem {
        let fm = FileManager.default
        let source = (remoteRoot as NSString).appendingPathComponent(normalized)
        let attrs = try fm.attributesOfItem(atPath: source)
        let isDirectory = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let size = isDirectory ? 0 : ((attrs[.size] as? NSNumber)?.int64Value ?? 0)
        let name = (normalized as NSString).lastPathComponent
        let id = UUID().uuidString

        let directory = payloadDirectory(remoteRoot: remoteRoot, id: id)
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let destination = (directory as NSString).appendingPathComponent(name)

        do {
            try fm.moveItem(atPath: source, toPath: destination)
        } catch {
            try? fm.removeItem(atPath: directory)
            throw error
        }

        return TrashItem(
            id: id,
            name: name,
            originalPath: normalized,
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
        let fm = FileManager.default
        var items = loadItems(remoteRoot: remoteRoot, now: now)
        var results: [RestoreResult] = []
        var restoredFolders: [(original: String, restored: String)] = []

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
            let payload = payloadPath(remoteRoot: remoteRoot, item: item)
            guard fm.fileExists(atPath: payload) else {
                items.remove(at: index)
                continue
            }

            let ancestor = restoredFolders
                .filter { item.originalPath.hasPrefix($0.original + "/") }
                .max { $0.original.count < $1.original.count }
            let requestedPath = ancestor.map {
                $0.restored + String(item.originalPath.dropFirst($0.original.count))
            } ?? item.originalPath
            let restoredPath = restoreDestination(for: item, remoteRoot: remoteRoot, requestedPath: requestedPath)
            let destination = (remoteRoot as NSString).appendingPathComponent(restoredPath)
            try fm.createDirectory(
                atPath: (destination as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try fm.moveItem(atPath: payload, toPath: destination)
            try? fm.removeItem(atPath: payloadDirectory(remoteRoot: remoteRoot, id: id))

            items.remove(at: index)
            results.append(RestoreResult(item: item, restoredPath: restoredPath))
            if item.isDirectory {
                restoredFolders.append((original: item.originalPath, restored: restoredPath))
            }
        }

        try writeIndex(items, remoteRoot: remoteRoot)
        return results
    }

    /// Permanently deletes the given items from the trash.
    static func deletePermanently(ids: Set<String>, remoteRoot: String, now: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        // Validate the entire batch before deleting anything. IDs name direct
        // payload containers, never arbitrary paths from a damaged index.
        for id in ids {
            guard !id.isEmpty, !id.hasPrefix("."), id != indexFileName,
                  !id.contains("/"), !id.contains("\\") else {
                throw SyncError.invalidMove("Invalid Trash item ID: \(id)")
            }
        }
        try requireRemoteRoot(remoteRoot)
        let root = trashRoot(remoteRoot: remoteRoot)
        if confirmedMissing(folderName, in: remoteRoot) { return }
        try requireTrashDirectory(root)
        // Reading the index directly preserves records for unreadable payloads.
        // Requested orphan IDs can still be deleted even if the index is missing.
        let items = readIndex(remoteRoot: remoteRoot).items
        var outcome = removeTrashChildren(ids, root: root, items: items)
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
                                        details: outcome.details, cause: outcome.cause)
            NSLog("Trash deletion failed on %@: %@", remoteRoot, failure.localizedDescription)
            throw failure
        }
    }

    /// Empty the contents, including hidden/orphaned payloads, but preserve the
    /// service directory: a server may allow writing inside it but forbid unlinking it.
    static func empty(remoteRoot: String) throws {
        try requireRemoteRoot(remoteRoot)
        let fm = FileManager.default
        let root = trashRoot(remoteRoot: remoteRoot)
        if confirmedMissing(folderName, in: remoteRoot) { return }
        try requireTrashDirectory(root)
        let items = readIndex(remoteRoot: remoteRoot).items
        let children = try fm.contentsOfDirectory(atPath: root)
        let indexAttributes = try? fm.attributesOfItem(atPath: indexPath(remoteRoot: remoteRoot))
        let regularIndex = indexAttributes?[.type] as? FileAttributeType == .typeRegular
        let targets = Set(children.filter { $0 != indexFileName || !regularIndex })
        var outcome = removeTrashChildren(targets, root: root, items: items)
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
                                        details: outcome.details, cause: outcome.cause)
            NSLog("Trash empty failed on %@: %@", remoteRoot, failure.localizedDescription)
            throw failure
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
    }

    /// Callers supply validated IDs or direct child names returned by the filesystem.
    /// FileManager removes symbolic links themselves, never their external targets.
    private static func removeTrashChildren(_ ids: Set<String>, root: String, items: [TrashItem]) -> RemovalOutcome {
        var outcome = RemovalOutcome()
        for id in ids.sorted() {
            let path = (root as NSString).appendingPathComponent(id)
            do {
                try FileManager.default.removeItem(atPath: path)
                outcome.deletedIDs.insert(id)
            } catch {
                if confirmedMissing(id, in: root) {
                    outcome.deletedIDs.insert(id)
                } else {
                    outcome.failedIDs.insert(id)
                    let name = items.first { $0.id == id }?.name ?? id
                    let diagnostic = fileErrorDiagnostic(error)
                    if outcome.cause == nil { outcome.cause = diagnostic.cause }
                    outcome.details.append("\(name)\n\(path)\n\(diagnostic.details)")
                }
            }
        }
        return outcome
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

    /// A failed stat is not proof of deletion; only a readable parent listing is.
    private static func confirmedMissing(_ name: String, in directory: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return false }
        return !names.contains(name)
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
