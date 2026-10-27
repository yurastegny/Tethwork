import Foundation

private struct MergeFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ value: Bool, _ message: String) throws {
    if !value { throw MergeFailure(description: message) }
}

private final class MergeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SyncEvent] = []
    func add(_ event: SyncEvent) { lock.withLock { values.append(event) } }
    func snapshot() -> [SyncEvent] { lock.withLock { values } }
}

private final class MergeFixture {
    let root: URL
    let local: URL
    let remote: URL
    let engine = SyncEngine(watchesDirectories: false)
    let fm = FileManager.default
    var connection: SyncConnection {
        SyncConnection(id: "new-server", name: "New server", remotePath: remote.path, localPath: local.path)
    }

    init(base: URL) throws {
        root = base.appendingPathComponent("merge-test-\(UUID().uuidString)")
        local = root.appendingPathComponent("local")
        remote = root.appendingPathComponent("remote")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
    }

    func write(_ base: URL, _ path: String, _ contents: String) throws {
        let url = base.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func read(_ base: URL, _ path: String) throws -> String {
        try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ base: URL, _ path: String) -> Bool {
        fm.fileExists(atPath: base.appendingPathComponent(path).path)
    }

    func merge() async throws -> [String] {
        try await SyncEngine.mergeExistingLocalFiles(connection: connection)
    }

    func connectAndSync(_ paths: [String]) async throws {
        let events = MergeEvents()
        await engine.setEventHandler { events.add($0) }
        try await engine.connect(connection: connection, pinned: paths, initiallySyncedPaths: paths)
        await engine.fullSync()
        try expect(!events.snapshot().contains { $0.kind == .error }, "Normal sync failed after merging")
        try expect(!events.snapshot().contains { $0.isTransfer && $0.transferDirection == .download },
                   "Initial adoption caused a download")
    }

    func close() async {
        await engine.disconnect()
        try? fm.removeItem(at: root)
    }
}

@main
struct InitialMergeTests {
    private struct Case {
        let name: String
        let run: (MergeFixture) async throws -> Void
    }

    static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let cases: [Case] = [
            Case(name: "deferred connection is browsable before any local upload completes") { f in
                try f.write(f.local, "local.txt", "waiting to upload")
                try f.write(f.remote, "online.txt", "available now")
                try await f.engine.connect(connection: f.connection, pinned: [], deferInitialMerge: true)
                let listing = try await f.engine.listDirectory(relativePath: "")
                try expect(listing.entries.contains { $0.name == "online.txt" }, "Connected server cannot be browsed")
                try expect(!f.exists(f.remote, "local.txt"), "Connection waited for a file upload")
                await f.engine.fullSync()
                try expect(!f.exists(f.local, "online.txt"), "Normal sync ran before adoption finished")
                do {
                    _ = try await f.engine.setPinned(relativePath: "online.txt", pinned: true)
                    throw MergeFailure(description: "A competing download was allowed during adoption")
                } catch SyncError.invalidMove {
                    // Storage changes wait, but reads and navigation remain usable.
                }
                let paths = try await f.merge()
                _ = try await f.engine.finishInitialMerge(connectionID: f.connection.id, paths: paths)
                await f.engine.fullSync()
                try expect(try f.read(f.remote, "local.txt") == "waiting to upload", "Background adoption failed")
                try expect(!f.exists(f.local, "online.txt"), "Background adoption downloaded an online-only file")
            },
            Case(name: "a failed background merge can be retried on the existing connection") { f in
                try f.write(f.local, "local.txt", "retry me")
                try await f.engine.connect(connection: f.connection, pinned: [], deferInitialMerge: true)
                _ = try await f.engine.finishInitialMerge(connectionID: f.connection.id, paths: [])
                try await f.engine.prepareInitialMerge(connectionID: f.connection.id)
                let paths = try await f.merge()
                let adopted = try await f.engine.finishInitialMerge(connectionID: f.connection.id, paths: paths)
                try expect(adopted == ["local.txt"], "Retry did not adopt local files")
                try expect(try f.read(f.remote, "local.txt") == "retry me", "Retry failed to upload")
            },
            Case(name: "delete can stop initial adoption and resume without recreating deleted files") { f in
                try f.write(f.local, "Work/file.txt", "local Work")
                try f.write(f.remote, "Work/file.txt", "server Work")
                try f.write(f.local, "Other/file.txt", "keep uploading this")
                try await f.engine.connect(connection: f.connection, pinned: [], deferInitialMerge: true)
                do {
                    _ = try await SyncEngine.mergeExistingLocalFiles(connection: f.connection) { _, _, _ in
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    throw MergeFailure(description: "Initial upload did not stop")
                } catch is CancellationError {
                    // Await cancellation before releasing the merge guard for deletion.
                }
                _ = try await f.engine.finishInitialMerge(connectionID: f.connection.id, paths: [])
                try await f.engine.trashItems(relativePaths: ["Work"])
                try await f.engine.prepareInitialMerge(connectionID: f.connection.id)
                let paths = try await f.merge()
                _ = try await f.engine.finishInitialMerge(connectionID: f.connection.id, paths: paths)
                await f.engine.fullSync()
                try expect(!f.exists(f.local, "Work") && !f.exists(f.remote, "Work"), "Resuming adoption restored deleted content")
                try expect(try f.read(f.remote, "Other/file.txt") == "keep uploading this", "Remaining upload did not resume")
                let trash = await f.engine.listTrashItems()
                try expect(trash.count == 1, "Deleted content was not recoverable")
            },
            Case(name: "a stale background upload cannot commit to another server") { f in
                try await f.engine.connect(connection: f.connection, pinned: [], deferInitialMerge: true)
                let secondRemote = f.root.appendingPathComponent("second-remote")
                let secondLocal = f.root.appendingPathComponent("second-local")
                try f.fm.createDirectory(at: secondRemote, withIntermediateDirectories: true)
                let second = SyncConnection(id: "other", name: "Other", remotePath: secondRemote.path, localPath: secondLocal.path)
                try await f.engine.connect(connection: second, pinned: [])
                do {
                    _ = try await f.engine.finishInitialMerge(connectionID: f.connection.id, paths: ["stale.txt"])
                    throw MergeFailure(description: "A stale upload changed the new connection")
                } catch SyncError.notConnected {
                    // The old connection's completion must be ignored.
                }
                let pins = await f.engine.getPinnedPaths()
                try expect(pins.isEmpty, "Stale background paths were adopted on the wrong server")
            },
            Case(name: "merge shared folders without downloading online-only siblings") { f in
                try f.write(f.local, "Docs/local.txt", "local")
                try f.write(f.remote, "Docs/online.txt", "online")
                try f.write(f.remote, "OnlyOnline/file.txt", "not downloaded")
                let paths = try await f.merge()
                try expect(paths == ["Docs/local.txt"], "Entire shared folder was incorrectly pinned")
                try expect(try f.read(f.remote, "Docs/local.txt") == "local", "Local file was not uploaded")
                try await f.connectAndSync(paths)
                try expect(f.exists(f.local, "Docs/local.txt"), "Local file was pruned")
                try expect(!f.exists(f.local, "Docs/online.txt") && !f.exists(f.local, "OnlyOnline"), "Online-only files were downloaded")
                try expect(!f.exists(f.remote, "Docs 2"), "Shared folder was duplicated instead of merged")
            },
            Case(name: "different contents keep both versions, including after normal sync") { f in
                try f.write(f.local, "same.txt", "local version")
                try f.write(f.remote, "same.txt", "server version")
                let paths = try await f.merge()
                try expect(paths == ["same (Local).txt"], "Conflict did not receive a distinct local path")
                try expect(try f.read(f.local, "same (Local).txt") == "local version", "Local version lost")
                try await f.connectAndSync(paths)
                try expect(try f.read(f.remote, "same.txt") == "server version", "Server original was overwritten")
                try expect(try f.read(f.remote, "same (Local).txt") == "local version", "Conflicting version was not uploaded")
                try expect(!f.exists(f.local, "same.txt"), "Online version was downloaded over the old local name")
            },
            Case(name: "identical contents do not create duplicates or redundant downloads") { f in
                try f.write(f.local, "same.txt", "identical")
                try f.write(f.remote, "same.txt", "identical")
                try f.fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                       ofItemAtPath: f.remote.appendingPathComponent("same.txt").path)
                let paths = try await f.merge()
                try expect(paths == ["same.txt"], "Identical file got a conflict name")
                try expect(!f.exists(f.remote, "same (Local).txt"), "Identical contents were duplicated")
                try await f.connectAndSync(paths)
                try expect(try f.read(f.local, "same.txt") == "identical", "Identical file changed")
            },
            Case(name: "conflict names avoid existing names on both sides") { f in
                try f.write(f.local, "same.txt", "incoming")
                try f.write(f.local, "same (Local 2).txt", "existing local")
                try f.write(f.remote, "same.txt", "original")
                try f.write(f.remote, "same (Local).txt", "existing server")
                let paths = try await f.merge()
                try expect(paths.contains("same (Local 3).txt"), "Conflict name collided with an existing file")
                try await f.connectAndSync(paths)
                try expect(try f.read(f.remote, "same (Local).txt") == "existing server", "Existing conflict copy overwritten")
                try expect(try f.read(f.remote, "same (Local 2).txt") == "existing local", "Existing local file was lost")
                try expect(try f.read(f.remote, "same (Local 3).txt") == "incoming", "New conflict copy missing")
            },
            Case(name: "file/directory collisions preserve both trees") { f in
                try f.write(f.remote, "Folder", "server file")
                try f.write(f.local, "Folder/child.txt", "local directory")
                try f.write(f.remote, "Node/online.txt", "server directory")
                try f.write(f.local, "Node", "local file")
                let paths = try await f.merge()
                try await f.connectAndSync(paths)
                try expect(try f.read(f.remote, "Folder") == "server file", "Server file replaced by a directory")
                try expect(try f.read(f.remote, "Folder (Local)/child.txt") == "local directory", "Local tree lost")
                try expect(try f.read(f.local, "Folder (Local)/child.txt") == "local directory", "Local directory rename failed")
                try expect(try f.read(f.remote, "Node/online.txt") == "server directory", "Server directory replaced by a file")
                try expect(try f.read(f.remote, "Node (Local)") == "local file", "Local file conflict lost")
            },
            Case(name: "empty local folders upload without pinning the volume") { f in
                try f.fm.createDirectory(at: f.local.appendingPathComponent("Empty/sub"), withIntermediateDirectories: true)
                try f.write(f.remote, "online.txt", "online")
                let paths = try await f.merge()
                try expect(paths == ["Empty/sub"], "Wrong empty directory pins")
                try await f.connectAndSync(paths)
                try expect(f.exists(f.local, "Empty/sub") && f.exists(f.remote, "Empty/sub"), "Empty directory lost")
                try expect(!f.exists(f.local, "online.txt"), "Volume content downloaded for an empty local folder")
            },
            Case(name: "an empty local placeholder does not download its online-only contents") { f in
                try f.fm.createDirectory(at: f.local.appendingPathComponent("Online"), withIntermediateDirectories: true)
                try f.write(f.local, "tracked.txt", "tracked")
                try f.write(f.remote, "Online/server.txt", "server only")
                let paths = try await f.merge()
                try expect(paths == ["tracked.txt"], "Populated online directory was pinned")
                try await f.connectAndSync(paths)
                try expect(f.exists(f.local, "Online"), "Existing empty local directory was deleted")
                try expect(!f.exists(f.local, "Online/server.txt"), "Placeholder caused an online-only file to download")
            },
            Case(name: "files appearing during adoption survive the first normal sync") { f in
                try f.write(f.local, "tracked.txt", "original")
                let appeared = f.local.appendingPathComponent("new-file.txt")
                let paths = try await SyncEngine.mergeExistingLocalFiles(connection: f.connection) { done, _, _ in
                    if done == 0 { try? Data("created while uploading".utf8).write(to: appeared) }
                }
                try await f.connectAndSync(paths)
                try expect(try f.read(f.local, "new-file.txt") == "created while uploading", "Untracked local file was pruned")
            },
            Case(name: "user dotfiles upload, internal sync state does not") { f in
                try f.write(f.local, ".settings", "user settings")
                try f.write(f.local, ".tethwork-sync-state.json", "old internal state")
                try f.write(f.local, ".DS_Store", "finder metadata")
                let paths = try await f.merge()
                try expect(paths == [".settings"], "User or internal dotfile classification is wrong")
                try expect(try f.read(f.remote, ".settings") == "user settings", "User dotfile omitted")
                try expect(!f.exists(f.remote, ".tethwork-sync-state.json") && !f.exists(f.remote, ".DS_Store"),
                           "Internal metadata uploaded")
            },
            Case(name: "a destination appearing during upload is never overwritten") { f in
                try f.write(f.local, "same.txt", "local")
                try f.write(f.remote, "same.txt", "server")
                let collision = f.remote.appendingPathComponent("same (Local).txt")
                do {
                    _ = try await SyncEngine.mergeExistingLocalFiles(connection: f.connection) { done, _, _ in
                        if done == 0 { try? Data("other client".utf8).write(to: collision) }
                    }
                    throw MergeFailure(description: "A concurrent destination was overwritten")
                } catch let error as MergeFailure {
                    throw error
                } catch {
                    // The concurrent writer wins its own new path; adoption must fail safely.
                }
                try expect(try f.read(f.local, "same.txt") == "local", "Failed upload renamed or lost local data")
                try expect(try f.read(f.remote, "same.txt") == "server", "Original server file overwritten")
                try expect(try f.read(f.remote, "same (Local).txt") == "other client", "Concurrent file overwritten")
                let names = try f.fm.contentsOfDirectory(atPath: f.remote.path)
                try expect(!names.contains { $0.hasPrefix(".tethwork-copy-") }, "Temporary upload was not cleaned up")
            },
            Case(name: "cancelled adoption leaves local conflicts untouched") { f in
                try f.write(f.local, "same.txt", "local")
                try f.write(f.remote, "same.txt", "server")
                do {
                    _ = try await SyncEngine.mergeExistingLocalFiles(connection: f.connection) { _, _, _ in
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    throw MergeFailure(description: "Cancelled merge did not stop")
                } catch is CancellationError {
                    // Expected before any file upload or local rename.
                }
                try expect(try f.read(f.local, "same.txt") == "local", "Cancellation changed local file")
                try expect(!f.exists(f.remote, "same (Local).txt"), "Cancellation finalized an upload")
            },
            Case(name: "a formerly identical file changing during merge fails without overwriting") { f in
                try f.write(f.local, "same.txt", "identical")
                try f.write(f.remote, "same.txt", "identical")
                let changed = f.local.appendingPathComponent("same.txt")
                do {
                    _ = try await SyncEngine.mergeExistingLocalFiles(connection: f.connection) { done, _, _ in
                        if done == 0 { try? Data("new local edit".utf8).write(to: changed) }
                    }
                    throw MergeFailure(description: "A changed file was adopted as identical")
                } catch SyncError.invalidMove {
                    // Retry must re-plan this as a conflict instead of overwriting the server.
                }
                try expect(try f.read(f.remote, "same.txt") == "identical", "Server copy was overwritten")
                try expect(try f.read(f.local, "same.txt") == "new local edit", "Local edit was lost")
            },
            Case(name: "symbolic links cannot upload data from outside the chosen folder") { f in
                let outside = f.root.appendingPathComponent("outside.txt")
                try Data("private".utf8).write(to: outside)
                try f.fm.createSymbolicLink(at: f.local.appendingPathComponent("link"), withDestinationURL: outside)
                do {
                    _ = try await f.merge()
                    throw MergeFailure(description: "Unsafe symbolic link was followed")
                } catch SyncError.invalidMove {
                    // Unsupported links must fail visibly rather than silently lose or upload data.
                }
                try expect(!f.exists(f.remote, "link"), "Link escaped the selected folder")
                try expect(try String(contentsOf: outside, encoding: .utf8) == "private", "External file changed")
            },
            Case(name: "adoption rejects overlapping roots before writing anything") { f in
                let invalid = SyncConnection(name: "Invalid", remotePath: f.remote.path,
                                             localPath: f.remote.appendingPathComponent("nested").path)
                do {
                    _ = try await SyncEngine.mergeExistingLocalFiles(connection: invalid)
                    throw MergeFailure(description: "Overlapping adoption roots accepted")
                } catch SyncError.overlappingRoots {
                    // Expected.
                }
                try expect(!f.exists(f.remote, "nested"), "Invalid adoption wrote to the server")
            }
        ]
        var failures = 0
        for test in cases {
            let fixture = try MergeFixture(base: base)
            do {
                try await test.run(fixture)
                print("PASS: \(test.name)")
            } catch {
                failures += 1
                print("FAIL: \(test.name): \(error)")
            }
            await fixture.close()
        }
        print("Initial merge: \(cases.count - failures)/\(cases.count) passed")
        if failures > 0 { exit(1) }
    }
}
