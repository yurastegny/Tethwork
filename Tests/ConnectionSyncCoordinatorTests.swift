import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}

@MainActor
private func waitFor(_ message: String, seconds: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw Failure(description: message)
}

@main
struct ConnectionSyncCoordinatorTests {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("multi-server-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func connection(_ id: String) throws -> SyncConnection {
            let remote = root.appendingPathComponent(id + "-remote")
            let local = root.appendingPathComponent(id + "-local")
            try fm.createDirectory(at: remote, withIntermediateDirectories: true)
            return SyncConnection(id: id, name: id, remotePath: remote.path, localPath: local.path)
        }
        func write(_ directory: String, _ name: String, _ text: String) throws {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        func exists(_ directory: String, _ name: String) -> Bool {
            fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name))
        }
        let coordinator = ConnectionSyncCoordinator(makeEngine: { SyncEngine(watchesDirectories: false) }, retryDelay: 50_000_000)
        var receivedEvents: [SyncEvent] = []
        coordinator.onEvent = { receivedEvents.append($0) }
        let first = try connection("first")
        let second = try connection("second")
        let offline = try connection("offline")
        try fm.removeItem(atPath: offline.remotePath)
        try write(first.remotePath, "pinned.txt", "first")
        try write(second.remotePath, "pinned.txt", "second")
        try write(second.remotePath, "online.txt", "do not download")
        let all = [first, second, offline]
        let pins = Dictionary(uniqueKeysWithValues: all.map { ($0.id, ["pinned.txt"]) })
        coordinator.synchronize(all, pins: pins)
        try await waitFor("Volumes did not sync independently of selection") {
            exists(first.localPath, "pinned.txt") && exists(second.localPath, "pinned.txt")
                && coordinator.states[offline.id]?.error != nil
        }
        try expect(!exists(second.localPath, "online.txt"), "Background sync downloaded an unpinned sibling")
        try expect(receivedEvents.allSatisfy { $0.connectionID != nil }, "A background lifecycle event lost its server identity")
        print("PASS: all volumes synchronize without selection; an offline volume does not block others")

        let firstEngine = try await coordinator.connect(first, pins: pins[first.id]!)
        let secondEngine = try await coordinator.connect(second, pins: pins[second.id]!)
        let returned = try await coordinator.connect(first, pins: pins[first.id]!)
        try expect(firstEngine === returned && firstEngine !== secondEngine, "Browsing replaced an independent engine")
        try expect(await secondEngine.connection?.id == second.id, "Selecting another volume disconnected the previous one")
        print("PASS: selection reuses engines and never disconnects another volume")

        try write(offline.remotePath, "pinned.txt", "reconnected")
        try await waitFor("An unavailable volume was not retried") { exists(offline.localPath, "pinned.txt") }
        print("PASS: unavailable volumes reconnect automatically")

        await coordinator.remove(offline.id)
        coordinator.synchronize([first, second], pins: pins)
        try expect(coordinator.states[offline.id] == nil, "Removed volume retained a status or retry")
        print("PASS: removing a volume clears only its own session")

        let adopting = try connection("adopting")
        try write(adopting.localPath, "existing.txt", "existing local contents")
        var adoptedPaths: [String]?
        coordinator.onAdopted = { id, paths in if id == adopting.id { adoptedPaths = paths } }
        coordinator.synchronize([first, second, adopting], pins: pins, pendingInitialMerges: [adopting.id])
        try await waitFor("Initial adoption required selecting the volume") {
            adoptedPaths != nil && exists(adopting.remotePath, "existing.txt")
        }
        try expect(adoptedPaths?.contains("existing.txt") == true, "Background adoption did not commit its pins")
        print("PASS: initial local files upload on unselected volumes without losing pins")

        await coordinator.setPaused(true)
        let paused = try connection("paused")
        try write(paused.remotePath, "pinned.txt", "wait for resume")
        coordinator.synchronize([first, second, paused], pins: [paused.id: ["pinned.txt"]])
        try await Task.sleep(nanoseconds: 150_000_000)
        try expect(!exists(paused.localPath, "pinned.txt"), "A new volume synchronized during global pause")
        await coordinator.setPaused(false)
        coordinator.synchronize([first, second, paused], pins: [paused.id: ["pinned.txt"]])
        try await waitFor("Global resume did not resume all volumes") { exists(paused.localPath, "pinned.txt") }
        print("PASS: global pause and resume apply to every volume")

        await coordinator.suspend(paused.id)
        coordinator.synchronize([first, second, paused], pins: pins)
        try expect(coordinator.states[paused.id] == nil, "Explicit disconnect immediately reconnected the volume")
        coordinator.resume(paused.id)
        _ = try await coordinator.connect(paused, pins: ["pinned.txt"])
        print("PASS: explicit disconnect stays disconnected until resumed")

        let replacement = try connection("replacement")
        let editedSecond = SyncConnection(id: second.id, name: second.name,
                                          remotePath: replacement.remotePath, localPath: replacement.localPath)
        try write(editedSecond.remotePath, "pinned.txt", "new roots")
        coordinator.synchronize([first, editedSecond], pins: pins)
        try await waitFor("Editing a connection kept syncing the old roots") { exists(editedSecond.localPath, "pinned.txt") }
        let oldConnection = await secondEngine.connection
        try expect(oldConnection == nil, "The old engine remained active after changing roots")
        print("PASS: editing roots retires the old engine before starting its replacement")
        await coordinator.shutdown()

        let watched = ConnectionSyncCoordinator()
        let watchedA = try connection("watched-A")
        let watchedB = try connection("watched-B")
        try write(watchedA.remotePath, "pinned.txt", "old-A")
        try write(watchedB.remotePath, "pinned.txt", "old-B")
        let watchedPins = [watchedA.id: ["pinned.txt"], watchedB.id: ["pinned.txt"]]
        watched.synchronize([watchedA, watchedB], pins: watchedPins)
        try await waitFor("Initial watched sync did not finish") {
            exists(watchedA.localPath, "pinned.txt") && exists(watchedB.localPath, "pinned.txt")
                && watched.states[watchedA.id]?.isSyncing == false && watched.states[watchedB.id]?.isSyncing == false
        }
        try write(watchedA.remotePath, "pinned.txt", "remote-A-edited")
        try write(watchedB.localPath, "pinned.txt", "local-B-edited")
        for directory in [watchedA.remotePath, watchedB.localPath] {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                 ofItemAtPath: (directory as NSString).appendingPathComponent("pinned.txt"))
        }
        try await waitFor("Unselected volumes did not observe local and remote changes", seconds: 12) {
            let a = try? String(contentsOfFile: (watchedA.localPath as NSString).appendingPathComponent("pinned.txt"), encoding: .utf8)
            let b = try? String(contentsOfFile: (watchedB.remotePath as NSString).appendingPathComponent("pinned.txt"), encoding: .utf8)
            return a == "remote-A-edited" && b == "local-B-edited"
        }
        try await waitFor("Watched synchronization did not finish") {
            watched.states[watchedA.id]?.isSyncing == false && watched.states[watchedB.id]?.isSyncing == false
        }
        await watched.setPaused(true)
        try write(watchedA.remotePath, "pinned.txt", "after-global-pause")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                             ofItemAtPath: (watchedA.remotePath as NSString).appendingPathComponent("pinned.txt"))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let duringPause = try String(contentsOfFile: (watchedA.localPath as NSString).appendingPathComponent("pinned.txt"), encoding: .utf8)
        try expect(duringPause == "remote-A-edited", "A connected volume ignored global pause")
        await watched.setPaused(false)
        watched.synchronize([watchedA, watchedB], pins: watchedPins)
        try await waitFor("A connected volume did not resume after global pause", seconds: 12) {
            (try? String(contentsOfFile: (watchedA.localPath as NSString).appendingPathComponent("pinned.txt"), encoding: .utf8)) == "after-global-pause"
        }
        await watched.shutdown()
        print("PASS: unselected volumes keep watching and synchronize edits in both directions")
        print("Connection sync coordinator: all checks passed")
    }
}
