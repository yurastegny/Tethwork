import Foundation
import CryptoKit
import Darwin

/// Diagnostic evidence, never a deletion baseline or authority to repair files.
/// All files live outside the application and outside both synchronization roots.
final class LocalFileInventory: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        var size: Int64?
        var modified: Date?
        var fileID: UInt64?
        var lastConfirmed: Date?
    }

    struct Snapshot: Codable {
        var schema = 1
        var connectionID: String
        var localRoot: String
        var remoteRoot: String
        var selectedPaths: [String]
        var expected: [String: Entry] = [:]
        var lastSuccessfulOperation: Date?
    }

    struct Event: Codable {
        var time = Date()
        var kind: String
        var message: String?
        var paths: [String]?
        var selectedPaths: [String]?
        var expectedCount: Int?
        var missing: [String]?
        var cloudOnly: [String]?
        var inaccessible: [String: Int]?
        var rootAvailable: Bool?
        var retired: [String: Entry]?
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tethwork/LocalInventory", isDirectory: true)
    }

    let manifestURL: URL
    let journalURL: URL
    private let directory: URL
    private let lock = NSLock()
    private var snapshot: Snapshot
    private var ready = false
    private var dirty = false
    private var lastCheckpoint = Date.distantPast

    init(directory: URL, connection: SyncConnection) {
        self.directory = directory
        let local = SyncEngine.canonicalPath(connection.localPath)
        let remote = SyncEngine.canonicalPath(connection.remotePath)
        let identity = [connection.id, local, remote].joined(separator: "\0")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        manifestURL = directory.appendingPathComponent(key + ".json")
        journalURL = directory.appendingPathComponent(key + ".events.jsonl")
        snapshot = Snapshot(connectionID: connection.id, localRoot: local, remoteRoot: remote, selectedPaths: [])
    }

    /// May be used even for a rejected connection: it only reads local metadata
    /// and writes diagnostic files to Application Support, never into the roots.
    func beginSession(selectedPaths: [String]) throws {
        try lock.withLock {
            let fm = FileManager.default
            let metadataRoot = SyncEngine.canonicalPath(directory.path)
            for root in [snapshot.localRoot, snapshot.remoteRoot] {
                guard root != "/", metadataRoot != root, !metadataRoot.hasPrefix(root + "/"), !root.hasPrefix(metadataRoot + "/") else {
                    throw SyncError.invalidMove("File inventory must be stored outside synchronization roots.")
                }
            }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: manifestURL.path) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let loaded = try decoder.decode(Snapshot.self, from: Data(contentsOf: manifestURL))
                guard loaded.schema == 1, loaded.connectionID == snapshot.connectionID,
                      loaded.localRoot == snapshot.localRoot, loaded.remoteRoot == snapshot.remoteRoot,
                      loaded.expected.keys.allSatisfy(Self.validPath) else {
                    throw SyncError.invalidMove("Local file inventory does not match this connection; it was not overwritten.")
                }
                snapshot = loaded
            } else {
                try importLegacyMetadata()
            }
            if ready || snapshot.selectedPaths != selectedPaths.sorted() {
                try append(Event(kind: "selection_loaded", selectedPaths: selectedPaths.sorted(), expectedCount: snapshot.expected.count))
            }
            snapshot.selectedPaths = selectedPaths.sorted()
            ready = true
            dirty = true
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "test"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "test"
            try append(Event(kind: "session_started", message: "\(version) (\(build))", expectedCount: snapshot.expected.count))
            try save()
        }
    }

    func confirm(path: String, size: Int64, modified: Date, fileID: UInt64?) {
        lock.withLock {
            guard ready, Self.validPath(path) else { return }
            snapshot.expected[path] = Entry(size: size, modified: modified, fileID: fileID, lastConfirmed: Date())
            dirty = true
        }
    }

    func addExpected(paths: Set<String>) {
        lock.withLock {
            guard ready else { return }
            for path in paths where Self.validPath(path) && snapshot.expected[path] == nil {
                snapshot.expected[path] = Entry()
                dirty = true
            }
        }
    }

    func checkpoint(force: Bool = false, successfulOperation: String? = nil, selectedPaths: [String]? = nil) throws {
        try lock.withLock {
            guard ready else { return }
            if let selectedPaths, selectedPaths.sorted() != snapshot.selectedPaths {
                snapshot.selectedPaths = selectedPaths.sorted()
                dirty = true
                try append(Event(kind: "selection_changed", selectedPaths: snapshot.selectedPaths, expectedCount: snapshot.expected.count))
            }
            if let successfulOperation {
                snapshot.lastSuccessfulOperation = Date()
                dirty = true
                try append(Event(kind: "operation_completed", message: successfulOperation, expectedCount: snapshot.expected.count))
            }
            if force || Date().timeIntervalSince(lastCheckpoint) >= 5 { try save() }
        }
    }

    func note(kind: String, message: String? = nil, paths: [String]? = nil) throws {
        try lock.withLock {
            guard ready else { return }
            if kind.hasSuffix("requested") || Date().timeIntervalSince(lastCheckpoint) >= 5 { try save() }
            try append(Event(kind: kind, message: message, paths: paths, expectedCount: snapshot.expected.count))
        }
    }

    /// Only explicit completed removals retire expectations. A missing file,
    /// changed preference or failed scan never silently empties the registry.
    func retire(scope: String, reason: String, remainingSelections: [String] = []) throws {
        try lock.withLock {
            guard ready, scope.isEmpty || Self.validPath(scope) else { return }
            let removed = snapshot.expected.filter { path, _ in
                (scope.isEmpty || path == scope || path.hasPrefix(scope + "/")) &&
                    !remainingSelections.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
            }
            guard !removed.isEmpty else { return }
            try append(Event(kind: "expected_paths_retired", message: reason, paths: [scope], retired: removed))
            for path in removed.keys { snapshot.expected.removeValue(forKey: path) }
            dirty = true
            try save()
        }
    }

    func remap(from source: String, to destination: String) throws {
        try lock.withLock {
            guard ready, Self.validPath(source), Self.validPath(destination) else { return }
            let moved = snapshot.expected.filter { $0.key == source || $0.key.hasPrefix(source + "/") }
            try append(Event(kind: "expected_paths_moved", paths: [source, destination]))
            for (path, entry) in moved {
                snapshot.expected.removeValue(forKey: path)
                snapshot.expected[destination + path.dropFirst(source.count)] = entry
            }
            dirty = true
            try save()
        }
    }

    func auditBeforeSync() throws {
        try lock.withLock {
            guard ready else { return }
            let fm = FileManager.default
            let root = URL(fileURLWithPath: snapshot.localRoot)
            let available = (try? fm.contentsOfDirectory(atPath: root.path)) != nil
            var missing: [String] = [], cloudOnly: [String] = []
            var inaccessible: [String: Int] = [:]
            if available {
                for path in snapshot.expected.keys.sorted() {
                    let url = root.appendingPathComponent(path)
                    guard TrashStore.isContained(url.path, in: root.path) else {
                        inaccessible[path] = Int(ELOOP)
                        continue
                    }
                    var info = stat()
                    if Darwin.lstat(url.path, &info) == 0 {
                        // Modern File Provider placeholders can exist as dataless
                        // inodes, without the legacy .filename.icloud sibling.
                        if info.st_flags & UInt32(SF_DATALESS) != 0 { cloudOnly.append(path) }
                        continue
                    }
                    let code = errno
                    if code == ENOENT {
                        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
                        if fm.fileExists(atPath: placeholder.path) || fm.isUbiquitousItem(at: url) { cloudOnly.append(path) }
                        else { missing.append(path) }
                    } else { inaccessible[path] = Int(code) }
                }
            }
            try append(Event(kind: "pre_sync_audit", expectedCount: snapshot.expected.count,
                             missing: missing, cloudOnly: cloudOnly, inaccessible: inaccessible, rootAvailable: available))
        }
    }

    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && TrashStore.safeRelativePath(path) != nil
    }

    private func importLegacyMetadata() throws {
        let root = URL(fileURLWithPath: snapshot.localRoot)
        let baseline = root.appendingPathComponent(".tethwork-sync-state.json")
        if let data = try? Data(contentsOf: baseline),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let remote = value["remotePath"] as? String, SyncEngine.canonicalPath(remote) == snapshot.remoteRoot {
            for path in value["syncedPaths"] as? [String] ?? [] where Self.validPath(path) { snapshot.expected[path] = Entry() }
        }
        let cache = root.appendingPathComponent(".tethwork-verification-cache.json")
        if let data = try? Data(contentsOf: cache),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           value["version"] as? Int == 1,
           let local = value["localPath"] as? String, let remote = value["remotePath"] as? String,
           SyncEngine.canonicalPath(local) == snapshot.localRoot, SyncEngine.canonicalPath(remote) == snapshot.remoteRoot {
            for (path, pair) in value["pairs"] as? [String: [String: Any]] ?? [:] where Self.validPath(path) {
                snapshot.expected[path] = Entry(size: (pair["localSize"] as? NSNumber)?.int64Value,
                    modified: (pair["localModified"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) },
                    fileID: (pair["localFileID"] as? NSNumber)?.uint64Value)
            }
        }
    }

    private func save() throws {
        guard dirty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        // Keep the immediately preceding complete snapshot as an extra safeguard.
        if let previous = try? Data(contentsOf: manifestURL) {
            try previous.write(to: manifestURL.deletingPathExtension().appendingPathExtension("previous.json"), options: .atomic)
        }
        try data.write(to: manifestURL, options: .atomic)
        dirty = false
        lastCheckpoint = Date()
    }

    private func append(_ event: Event) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A)
        let fd = Darwin.open(journalURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
