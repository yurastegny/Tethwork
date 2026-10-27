import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(description: message) }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SyncEvent] = []

    func append(_ event: SyncEvent) { lock.withLock { events.append(event) } }
    func snapshot() -> [SyncEvent] { lock.withLock { events } }
    func clear() { lock.withLock { events.removeAll() } }
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func take() -> Bool {
        lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
    }
}

private final class Fixture {
    let root: URL
    let remote: URL
    let local: URL
    let engine: SyncEngine
    let events = EventLog()
    let fm = FileManager.default
    var connection: SyncConnection {
        SyncConnection(id: "test", name: "Test", remotePath: remote.path, localPath: local.path)
    }

    init(base: URL, watchChanges: Bool = false) throws {
        root = base.appendingPathComponent("sync-test-\(UUID().uuidString)")
        remote = root.appendingPathComponent("remote")
        local = root.appendingPathComponent("local")
        engine = SyncEngine(watchesDirectories: watchChanges)
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
    }

    func write(_ base: URL, _ path: String, _ text: String, date: Date? = nil) throws {
        let url = base.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    func read(_ base: URL, _ path: String) throws -> String {
        try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ base: URL, _ path: String) -> Bool {
        fm.fileExists(atPath: base.appendingPathComponent(path).path)
    }

    func connect(pins: [String]) async throws {
        let log = events
        await engine.setEventHandler { log.append($0) }
        try await engine.connect(connection: connection, pinned: pins)
        events.clear()
    }

    func sync() async throws {
        events.clear()
        await engine.fullSync()
        let errors = events.snapshot().filter { $0.kind == .error }
        try expect(errors.isEmpty, errors.map(\.message).joined(separator: "; "))
        try expect(events.snapshot().contains { $0.kind == .complete }, "Sync did not complete")
    }

    func close() async {
        await engine.disconnect()
        try? fm.removeItem(at: root)
    }
}

@main
struct SyncEngineTests {
    private struct Case {
        let name: String
        var watchChanges = false
        let run: (Fixture) async throws -> Void
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw TestFailure(description: "Usage: sync-engine-tests TEMP_DIRECTORY")
        }
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let cases: [Case] = [
            Case(name: "unchanged reconciliation does not rewrite watched sync state") { f in
                try f.write(f.remote, "Work/file.txt", "unchanged")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                let state = f.local.appendingPathComponent(".tethwork-sync-state.json").path
                let before = try f.fm.attributesOfItem(atPath: state)
                try await Task.sleep(nanoseconds: 100_000_000)
                try await f.sync()
                let after = try f.fm.attributesOfItem(atPath: state)
                try expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                           "An unchanged baseline was written again, generating another watcher event")
            },
            Case(name: "watchers settle after a slow deletion instead of checking forever", watchChanges: true) { f in
                try f.write(f.remote, "Delete/file.txt", "delete")
                try f.write(f.remote, "Keep/file.txt", "keep")
                try await f.connect(pins: ["Delete", "Keep"])
                try await f.sync()
                try await Task.sleep(nanoseconds: 2_200_000_000)
                f.events.clear()
                let log = f.events
                let delay = OneShot()
                await f.engine.setEventHandler { event in
                    log.append(event)
                    if event.kind == .file && event.message.hasPrefix("Moved to Trash:") && delay.take() {
                        // A real NAS trash operation can outlast the fixed suppression window.
                        Thread.sleep(forTimeInterval: 1.7)
                    }
                }
                try await f.engine.trashItems(relativePaths: ["Delete"])
                try await Task.sleep(nanoseconds: 2_400_000_000)
                let settledCount = log.snapshot().filter { $0.phase == .checking && $0.path == "Keep/file.txt" }.count
                try await Task.sleep(nanoseconds: 2_200_000_000)
                let finalCount = log.snapshot().filter { $0.phase == .checking && $0.path == "Keep/file.txt" }.count
                try expect(finalCount == settledCount, "Unchanged files kept being checked after deletion")
                try expect(!f.exists(f.remote, "Delete"), "Deleted directory was recreated")
                try expect(try f.read(f.remote, "Keep/file.txt") == "keep", "Unrelated data changed")
                // Settling must not mean the watchers were simply disabled.
                try f.write(f.remote, "Keep/file.txt", "real remote edit", date: Date().addingTimeInterval(60))
                let deadline = Date().addingTimeInterval(6)
                while (try? f.read(f.local, "Keep/file.txt")) != "real remote edit", Date() < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try expect(try f.read(f.local, "Keep/file.txt") == "real remote edit", "Real changes stopped synchronizing")
            },
            Case(name: "pin merges local-only files immediately without rescanning unrelated pins") { f in
                try f.write(f.remote, "Work/online.txt", "download")
                try f.write(f.local, "Work/local.txt", "upload")
                try f.write(f.remote, "Other/file.txt", "other")
                try f.write(f.local, "Other/file.txt", "other")
                try f.write(f.remote, "Other/stays-online.txt", "not requested")
                try await f.connect(pins: ["Work/local.txt", "Other/file.txt"])
                let pins = try await f.engine.setPinned(relativePath: "Work", pinned: true)
                try expect(pins == ["Other/file.txt", "Work"], "A parent pin retained redundant child pins")
                try expect(try f.read(f.remote, "Work/local.txt") == "upload", "Local-only file was not reconciled")
                try expect(try f.read(f.local, "Work/online.txt") == "download", "Online file was not downloaded")
                try expect(!f.exists(f.local, "Other/stays-online.txt"), "An unrelated folder was downloaded")
                try expect(!f.events.snapshot().contains { $0.message == "Checking files to synchronize…" },
                           "Pinning scheduled another global counting pass")
            },
            Case(name: "pin reports preparation immediately and streams without a guessed total") { f in
                try f.write(f.remote, "Work/a.txt", "first")
                try f.write(f.remote, "Work/b.txt", "second")
                try await f.connect(pins: [])
                _ = try await f.engine.setPinned(relativePath: "Work", pinned: true)
                let events = f.events.snapshot()
                let firstProgress = events.first { $0.kind == .progress }
                try expect(firstProgress?.phase == .preparing && firstProgress?.progressDone == 0,
                           "No immediate preparation event")
                try expect(firstProgress?.progressTotal == nil, "Preparation invented a file total")
                let copying = events.filter { $0.phase == .transferring }
                try expect(!copying.isEmpty && copying.allSatisfy { $0.progressTotal == nil },
                           "Streaming download reported a misleading percentage")
                try expect(events.contains { $0.phase == .finishing && $0.progressDone == 2 },
                           "Download did not report both completed files")
                try expect(try f.read(f.local, "Work/a.txt") == "first", "First file not downloaded")
                try expect(try f.read(f.local, "Work/b.txt") == "second", "Second file not downloaded")
            },
            Case(name: "pin checking existing content reports its current file and persists the baseline") { f in
                try f.write(f.remote, "Work/file.txt", "already local")
                try f.write(f.local, "Work/file.txt", "already local")
                try await f.connect(pins: [])
                _ = try await f.engine.setPinned(relativePath: "Work", pinned: true)
                let events = f.events.snapshot()
                try expect(events.contains { $0.phase == .checking && $0.path == "Work/file.txt" },
                           "Long content comparison was invisible")
                try expect(events.contains { $0.phase == .finishing && $0.progressDone == 0 },
                           "An unchanged local file was downloaded again")
                let data = try Data(contentsOf: f.local.appendingPathComponent(".tethwork-sync-state.json"))
                let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                try expect((state["syncedPaths"] as! [String]).contains("Work/file.txt"),
                           "Incremental download forgot the deletion baseline")
            },
            Case(name: "pinning a missing folder reports failure instead of a false completion") { f in
                try await f.connect(pins: [])
                do {
                    _ = try await f.engine.setPinned(relativePath: "Missing", pinned: true)
                    throw TestFailure(description: "Missing folder was reported as downloaded")
                } catch SyncError.notFound {
                    // Expected and must clear the visible operation through an error event.
                }
                try expect(f.events.snapshot().contains { $0.kind == .error }, "Missing folder produced no error")
                try expect(!f.events.snapshot().contains { $0.kind == .complete }, "Missing folder produced false success")
            },
            Case(name: "a write failure pauses automatic retries until manual Sync", watchChanges: true) { f in
                try f.write(f.remote, "Protected/a.txt", "original A")
                try f.write(f.remote, "Protected/b.txt", "original B")
                try f.write(f.local, "Protected/a.txt", "new A", date: Date().addingTimeInterval(60))
                try f.write(f.local, "Protected/b.txt", "new B", date: Date().addingTimeInterval(60))
                try await f.connect(pins: ["Protected/a.txt", "Protected/b.txt"])
                let protected = f.remote.appendingPathComponent("Protected").path
                try f.fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protected)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected) }
                await f.engine.fullSync()
                try expect(f.events.snapshot().filter { $0.kind == .error }.count == 1, "Failure did not stop at the first error")
                try expect(!f.events.snapshot().contains { $0.kind == .complete }, "A failed sync was reported as complete")
                try expect(try f.read(f.remote, "Protected/a.txt") == "original A", "Failed save destroyed the original")
                try expect(try f.read(f.remote, "Protected/b.txt") == "original B", "Sync continued to another file after failure")
                try await Task.sleep(nanoseconds: 2_100_000_000)
                try f.write(f.local, "trigger.txt", "a real watcher event")
                try await Task.sleep(nanoseconds: 1_100_000_000)
                try expect(f.events.snapshot().filter { $0.kind == .error }.count == 1, "Watcher repeated the failed transfer")
                try f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected)
                try await f.sync()
                try expect(try f.read(f.remote, "Protected/a.txt") == "new A", "Manual retry did not resume synchronization")
                try expect(try f.read(f.remote, "Protected/b.txt") == "new B", "Manual retry omitted remaining files")
            },
            Case(name: "delete interrupts a transfer and the file is not resurrected") { f in
                try f.write(f.remote, "Work/file.txt", String(repeating: "a", count: 2 * 1024 * 1024))
                try f.write(f.local, "Work/file.txt", String(repeating: "b", count: 2 * 1024 * 1024),
                            date: Date().addingTimeInterval(60))
                try await f.connect(pins: ["Work"])
                let trigger = OneShot()
                let engine = f.engine
                let log = f.events
                await engine.setEventHandler { event in
                    log.append(event)
                    if event.kind == .progress && event.phase == .transferring && trigger.take() {
                        Task {
                            do {
                                try await engine.trashItems(relativePaths: ["Work"])
                            } catch {
                                log.append(.init(kind: .error, message: "Deletion failed: \(error)"))
                            }
                        }
                    }
                }
                await engine.fullSync()
                let deadline = Date().addingTimeInterval(5)
                while (f.exists(f.remote, "Work") || f.exists(f.local, "Work")), Date() < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try expect(!f.exists(f.remote, "Work") && !f.exists(f.local, "Work"), "Delete did not take priority over copying")
                try await Task.sleep(nanoseconds: 200_000_000)
                try expect(!f.exists(f.remote, "Work"), "A late copy recreated the deleted folder")
                let trash = await engine.listTrashItems()
                try expect(trash.count == 1 && trash[0].originalPath == "Work", "Deleted folder was not recoverable")
                try expect(!log.snapshot().contains { $0.kind == .error }, "Cancellation became an error or deletion failed")
            },
            Case(name: "pin downloads a nested tree, not unrelated folders") { f in
                try f.write(f.remote, "Work/sub/file.txt", "download")
                try f.write(f.remote, "Other/file.txt", "online only")
                try await f.connect(pins: [])
                let pins = try await f.engine.setPinned(relativePath: "Work", pinned: true)
                try expect(pins == ["Work"], "Wrong pin set")
                try expect(f.events.snapshot().contains { $0.kind == .complete }, "Pin download did not complete")
                try expect(!f.events.snapshot().contains { $0.kind == .error }, "Pin reconciliation failed")
                try expect(try f.read(f.local, "Work/sub/file.txt") == "download", "Missing download")
                try expect(!f.exists(f.local, "Other"), "Unpinned folder was downloaded")
            },
            Case(name: "new local file uploads without deleting its sibling") { f in
                try f.write(f.remote, "Work/remote.txt", "remote")
                try f.write(f.local, "Work/local.txt", "local")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try expect(try f.read(f.remote, "Work/local.txt") == "local", "Upload failed")
                try expect(try f.read(f.local, "Work/remote.txt") == "remote", "Download failed")
            },
            Case(name: "newer remote contents replace local contents") { f in
                try f.write(f.remote, "Work/file.txt", "before")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try f.write(f.remote, "Work/file.txt", "remote edit", date: Date().addingTimeInterval(60))
                try await f.sync()
                try expect(try f.read(f.local, "Work/file.txt") == "remote edit", "Remote edit lost")
            },
            Case(name: "newer local contents replace remote contents") { f in
                try f.write(f.remote, "Work/file.txt", "before")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try f.write(f.local, "Work/file.txt", "local edit", date: Date().addingTimeInterval(60))
                try await f.sync()
                try expect(try f.read(f.remote, "Work/file.txt") == "local edit", "Local edit lost")
            },
            Case(name: "same size and timestamp do not hide a content change") { f in
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                try f.write(f.remote, "Work/file.txt", "AAAA", date: date)
                try f.write(f.local, "Work/file.txt", "BBBB", date: date)
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try expect(try f.read(f.remote, "Work/file.txt") == f.read(f.local, "Work/file.txt"),
                           "Different contents were incorrectly treated as synchronized")
            },
            Case(name: "repeated sync does not transfer unchanged files") { f in
                try f.write(f.remote, "Work/file.txt", "unchanged")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try await f.sync()
                try expect(!f.events.snapshot().contains {
                    $0.isTransfer && ($0.phase == .transferring || $0.kind == .file)
                }, "An unchanged file was transferred again")
            },
            Case(name: "local Finder deletion goes to recoverable server trash") { f in
                try f.write(f.remote, "Work/file.txt", "recover me")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try f.fm.removeItem(at: f.local.appendingPathComponent("Work/file.txt"))
                try await f.sync()
                let items = await f.engine.listTrashItems()
                try expect(items.count == 1 && items[0].wasDeletedLocally, "Deletion was not recorded in trash")
                try expect(!f.exists(f.remote, "Work/file.txt"), "Deleted item remains in original location")
                let payload = TrashStore.payloadPath(remoteRoot: f.remote.path, item: items[0])
                try expect(try String(contentsOfFile: payload, encoding: .utf8) == "recover me", "Trash lost data")
            },
            Case(name: "deletion baseline survives reconnect") { f in
                try f.write(f.remote, "Work/file.txt", "baseline")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                await f.engine.disconnect()
                try f.fm.removeItem(at: f.local.appendingPathComponent("Work/file.txt"))
                try await f.connect(pins: ["Work"])
                try await f.sync()
                let items = await f.engine.listTrashItems()
                try expect(items.count == 1 && items[0].wasDeletedLocally, "Reconnect forgot the deletion baseline")
            },
            Case(name: "a new connection does not inherit another server's deletion baseline") { f in
                try f.write(f.remote, "Work/file.txt", "first server")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                await f.engine.disconnect()
                try f.fm.removeItem(at: f.local.appendingPathComponent("Work"))
                let secondRemote = f.root.appendingPathComponent("second-remote")
                try f.write(secondRemote, "Work/file.txt", "second server")
                let second = SyncConnection(id: "second", name: "Second", remotePath: secondRemote.path,
                                            localPath: f.local.path)
                try await f.engine.connect(connection: second, pinned: ["Work"])
                try await f.sync()
                try expect(try f.read(f.local, "Work/file.txt") == "second server", "Stale deletion baseline affected a new server")
                try expect(f.exists(secondRemote, "Work/file.txt"), "New server content was deleted")
                let trash = await f.engine.listTrashItems()
                try expect(trash.isEmpty, "New server content was moved to trash")
            },
            Case(name: "empty folder downloads and its deletion is recoverable") { f in
                try f.fm.createDirectory(at: f.remote.appendingPathComponent("Work/empty"), withIntermediateDirectories: true)
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try expect(f.exists(f.local, "Work/empty"), "Empty directory was not downloaded")
                try f.fm.removeItem(at: f.local.appendingPathComponent("Work/empty"))
                try await f.sync()
                let items = await f.engine.listTrashItems()
                try expect(items.count == 1 && items[0].isDirectory, "Empty directory deletion was lost")
            },
            Case(name: "online-only eviction never trashes remote contents") { f in
                try f.write(f.remote, "Work/file.txt", "keep remotely")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                _ = try await f.engine.setPinned(relativePath: "Work", pinned: false)
                try await f.sync()
                let items = await f.engine.listTrashItems()
                try expect(items.isEmpty, "Eviction was treated as a user deletion")
                try expect(!f.exists(f.local, "Work"), "Local copy was not evicted")
                try expect(try f.read(f.remote, "Work/file.txt") == "keep remotely", "Eviction changed remote data")
            },
            Case(name: "rename and move preserve nested pins and both copies") { f in
                try f.write(f.remote, "Work/sub/file.txt", "move me")
                try await f.connect(pins: ["Work/sub"])
                try await f.sync()
                let renamed = try await f.engine.renameItem(relativePath: "Work", newName: "Renamed")
                try expect(renamed == "Renamed", "Wrong rename result")
                try await f.engine.moveItems(relativePaths: ["Renamed"], toDirectory: "Destination")
                let pins = await f.engine.getPinnedPaths()
                try expect(pins == ["Destination/Renamed/sub"], "Nested pin was not remapped")
                try expect(try f.read(f.remote, "Destination/Renamed/sub/file.txt") == "move me", "Remote move failed")
                try expect(try f.read(f.local, "Destination/Renamed/sub/file.txt") == "move me", "Local move failed")
                try expect(!f.exists(f.remote, "Work") && !f.exists(f.local, "Work"), "Old path remains")
                try await f.sync()
            },
            Case(name: "case-only rename preserves file contents") { f in
                try f.write(f.remote, "Work/file.txt", "case")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                _ = try await f.engine.renameItem(relativePath: "Work/file.txt", newName: "FILE.txt")
                try expect(try f.read(f.remote, "Work/FILE.txt") == "case", "Remote case-only rename lost data")
                try expect(try f.read(f.local, "Work/FILE.txt") == "case", "Local case-only rename lost data")
            },
            Case(name: "file-to-directory replacement preserves the newer remote tree") { f in
                try f.write(f.remote, "Work/node/child.txt", "new directory")
                try f.write(f.local, "Work/node", "old file", date: Date(timeIntervalSince1970: 1_700_000_000))
                try f.fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                       ofItemAtPath: f.remote.appendingPathComponent("Work/node").path)
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try expect(try f.read(f.local, "Work/node/child.txt") == "new directory", "Replacement lost the newer directory")
                try expect(try f.read(f.remote, "Work/node/child.txt") == "new directory", "Replacement changed the source")
            },
            Case(name: "directory-to-file replacement preserves the newer remote file") { f in
                try f.write(f.remote, "Work/node", "new remote file")
                try f.write(f.local, "Work/node/old-child.txt", "old directory")
                try f.fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                       ofItemAtPath: f.local.appendingPathComponent("Work/node").path)
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try expect(try f.read(f.local, "Work/node") == "new remote file", "Directory-to-file replacement failed")
                try expect(try f.read(f.remote, "Work/node") == "new remote file", "Source file changed")
            },
            Case(name: "trash restore recovers a pinned folder and its local copy") { f in
                try f.write(f.remote, "Work/file.txt", "restore me")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try await f.engine.trashItems(relativePaths: ["Work"])
                let items = await f.engine.listTrashItems()
                try expect(items.count == 1, "Expected one trashed folder")
                try expect(!f.exists(f.local, "Work"), "Trash left a local copy")
                _ = try await f.engine.restoreTrashItems(ids: [items[0].id])
                try await f.sync()
                try expect(try f.read(f.local, "Work/file.txt") == "restore me", "Restored pin did not download")
                try expect(try f.read(f.remote, "Work/file.txt") == "restore me", "Restore lost remote data")
            },
            Case(name: "missing network root does not recreate a fake server folder") { f in
                try f.write(f.remote, "Work/file.txt", "safe local copy")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try f.fm.moveItem(at: f.remote, to: f.root.appendingPathComponent("unmounted"))
                f.events.clear()
                await f.engine.fullSync()
                try expect(try f.read(f.local, "Work/file.txt") == "safe local copy", "Missing server damaged local data")
                try expect(!f.fm.fileExists(atPath: f.remote.path), "Sync recreated the missing network root")
                try expect(f.events.snapshot().contains { $0.kind == .error && $0.isRemoteUnavailable },
                           "Missing server did not report unavailability")
            },
            Case(name: "overlapping sync roots are rejected") { f in
                let invalid = SyncConnection(name: "Invalid", remotePath: f.remote.path,
                                             localPath: f.remote.appendingPathComponent("nested").path)
                do {
                    try await f.engine.connect(connection: invalid, pinned: [])
                    throw TestFailure(description: "Overlapping roots were accepted")
                } catch SyncError.overlappingRoots {
                    // Expected; no nested local folder should have been created.
                }
                try expect(!f.exists(f.remote, "nested"), "Invalid connect modified the remote root")
            },
            Case(name: "network loss after counting cannot recreate the remote root") { f in
                try f.fm.createDirectory(at: f.remote.appendingPathComponent("Work"), withIntermediateDirectories: true)
                try f.write(f.local, "Work/new.txt", "pending upload")
                try await f.connect(pins: ["Work"])
                let remote = f.remote
                let unavailable = f.root.appendingPathComponent("unmounted-during-sync")
                let log = f.events
                await f.engine.setEventHandler { event in
                    log.append(event)
                    if event.kind == .status && event.message.hasPrefix("Syncing ") {
                        try? FileManager.default.moveItem(at: remote, to: unavailable)
                    }
                }
                await f.engine.fullSync()
                try expect(!f.fm.fileExists(atPath: remote.path), "Upload recreated a root lost during sync")
                try expect(try f.read(f.local, "Work/new.txt") == "pending upload", "Failed upload damaged local file")
                try expect(f.events.snapshot().contains { $0.kind == .error && $0.isRemoteUnavailable },
                           "Network loss during sync was not reported")
            },
            Case(name: "nonexistent local root through a symlink cannot overlap the remote") { f in
                let alias = f.root.appendingPathComponent("remote-alias")
                try f.fm.createSymbolicLink(at: alias, withDestinationURL: f.remote)
                let invalid = SyncConnection(name: "Invalid", remotePath: f.remote.path,
                                             localPath: alias.appendingPathComponent("new/nested").path)
                do {
                    try await f.engine.connect(connection: invalid, pinned: [])
                    throw TestFailure(description: "A symlink bypassed root overlap validation")
                } catch SyncError.overlappingRoots {
                    // Expected before creating any local directories.
                }
                try expect(!f.exists(f.remote, "new"), "Invalid symlink root modified remote contents")
            },
            Case(name: "a disjoint nonexistent local root can still be created") { f in
                let newLocal = f.root.appendingPathComponent("new/local")
                let valid = SyncConnection(name: "Valid", remotePath: f.remote.path, localPath: newLocal.path)
                try await f.engine.connect(connection: valid, pinned: [])
                try expect(f.fm.fileExists(atPath: newLocal.path), "Valid local root was not created")
            },
            Case(name: "existing overlapping and identical roots are rejected") { f in
                let nested = f.remote.appendingPathComponent("nested")
                try f.fm.createDirectory(at: nested, withIntermediateDirectories: true)
                for local in [f.remote, nested] {
                    let invalid = SyncConnection(name: "Invalid", remotePath: f.remote.path, localPath: local.path)
                    do {
                        try await f.engine.connect(connection: invalid, pinned: [])
                        throw TestFailure(description: "Existing overlapping roots were accepted")
                    } catch SyncError.overlappingRoots {
                        // Expected.
                    }
                }
            },
            Case(name: "a multi-directory batch keeps every file intact") { f in
                for index in 0..<128 {
                    try f.write(f.remote, "Work/dir\(index % 4)/file\(index).txt", "payload-\(index)")
                }
                try await f.connect(pins: ["Work"])
                try await f.sync()
                for index in 0..<128 {
                    try expect(try f.read(f.local, "Work/dir\(index % 4)/file\(index).txt") == "payload-\(index)",
                               "Missing or corrupted file \(index)")
                }
                try await f.sync()
            }
        ]

        var failures = 0
        for test in cases {
            let fixture = try Fixture(base: base, watchChanges: test.watchChanges)
            do {
                try await test.run(fixture)
                print("PASS: \(test.name)")
            } catch {
                failures += 1
                print("FAIL: \(test.name): \(error)")
            }
            await fixture.close()
        }
        print("Sync engine: \(cases.count - failures)/\(cases.count) passed")
        if failures > 0 { exit(1) }
    }
}
