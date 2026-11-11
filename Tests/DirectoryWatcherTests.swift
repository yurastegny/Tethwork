import Foundation
import CoreServices

private final class WatcherEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() { lock.withLock { count += 1 } }
    func total() -> Int { lock.withLock { count } }
}

private struct WatcherFailure: Error {
    let message: String
}

/// Exercise the same cross-queue start/update/stop calls used by SyncEngine.
@main
struct DirectoryWatcherTests {
    private static func stopAndWait(_ watcher: DirectoryWatcher) async {
        await withCheckedContinuation { continuation in
            watcher.stop { continuation.resume() }
        }
    }

    private static func descriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    static func main() async throws {
        let modified = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        for path in ["/local/.tethwork-sync-state.json", "/local/.tethwork-verification-cache.json",
                     "/local/.tethwork-trash/item/data", "/local/sub/.tethwork-copy-123", "/local/.DS_Store"] {
            guard !DirectoryWatcher.isRelevantFileEvent(path: path, flags: modified) else {
                throw WatcherFailure(message: "Internal write triggered synchronization: \(path)")
            }
        }
        guard DirectoryWatcher.isRelevantFileEvent(path: "/local/sub/user.txt", flags: modified),
              !DirectoryWatcher.isRelevantFileEvent(path: "/local", flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified)),
              DirectoryWatcher.isRelevantFileEvent(path: "/local/new-folder", flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)),
              DirectoryWatcher.isRelevantFileEvent(path: "/local", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)) else {
            throw WatcherFailure(message: "File event filtering dropped a user change or recovery event")
        }
        print("PASS: internal checkpoints do not feed back into synchronization")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
            .appendingPathComponent("watcher-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for _ in 0..<30 {
            let watcher = DirectoryWatcher { _ in }
            DispatchQueue.concurrentPerform(iterations: 12) { index in
                switch index % 3 {
                case 0: watcher.start(watching: [root], interval: 1)
                case 1: watcher.setWatchedURLs([root])
                default: watcher.stop()
                }
            }
            await stopAndWait(watcher)
        }
        print("PASS: concurrent watcher start/update/stop")

        let events = WatcherEvents()
        let watcher = DirectoryWatcher { _ in events.record() }
        defer { watcher.stop() }
        watcher.start(watching: [root], interval: 0.4)
        // A queued update must not resurrect a stopped watcher.
        await stopAndWait(watcher)
        watcher.setWatchedURLs([root])
        try Data("stopped".utf8).write(to: root.appendingPathComponent("stopped.txt"))
        try await Task.sleep(nanoseconds: 700_000_000)
        guard events.total() == 0 else {
            throw WatcherFailure(message: "Stopped watcher was reactivated by a path update")
        }
        print("PASS: path updates cannot restart a stopped watcher")

        watcher.start(watching: [root], interval: 0.4)
        // Wait for queued setup without assuming a particular disk/CPU speed.
        await withCheckedContinuation { continuation in
            watcher.setWatchedURLs([root], completion: { continuation.resume() })
        }
        try Data("changed".utf8).write(to: root.appendingPathComponent("changed.txt"))
        let deadline = Date().addingTimeInterval(5)
        while events.total() == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard events.total() > 0 else {
            throw WatcherFailure(message: "Running watcher did not report a file change")
        }
        await stopAndWait(watcher)
        let stoppedCount = events.total()
        try Data("after stop".utf8).write(to: root.appendingPathComponent("after-stop.txt"))
        try await Task.sleep(nanoseconds: 700_000_000)
        guard events.total() == stoppedCount else {
            throw WatcherFailure(message: "Watcher delivered a callback after stop completed")
        }
        print("PASS: file changes are reported while running, never after stop")

        // Thousands of synchronized folders must not translate into thousands
        // of open directory descriptors. The old implementation opened one FD
        // per watch target and failed with EMFILE during synchronization.
        let tree = root.appendingPathComponent("many-folders")
        for index in 0..<250 {
            try FileManager.default.createDirectory(
                at: tree.appendingPathComponent("level-\(index)"),
                withIntermediateDirectories: true
            )
        }
        let deepest = tree.appendingPathComponent("level-249")

        let baseline = descriptorCount()
        let recursiveEvents = WatcherEvents()
        let recursive = DirectoryWatcher(mode: .recursiveFileEvents) { _ in recursiveEvents.record() }
        recursive.start(watching: [tree], interval: 30)
        await withCheckedContinuation { continuation in
            recursive.setWatchedURLs([tree], completion: { continuation.resume() })
        }
        let recursiveDescriptors = descriptorCount() - baseline
        guard recursiveDescriptors < 20 else {
            throw WatcherFailure(message: "Recursive watcher opened \(recursiveDescriptors) descriptors")
        }
        let deepFile = deepest.appendingPathComponent("change.txt")
        try Data("deep change".utf8).write(to: deepFile)
        let deepDeadline = Date().addingTimeInterval(5)
        while recursiveEvents.total() == 0, Date() < deepDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard recursiveEvents.total() > 0 else {
            throw WatcherFailure(message: "Recursive watcher missed a nested file change")
        }
        // Let the real user-write burst drain, then write the same checkpoints
        // as a completed sync. Neither file nor parent-directory events should
        // cause another pass.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let beforeCheckpoint = recursiveEvents.total()
        for name in [".tethwork-sync-state.json", ".tethwork-verification-cache.json"] {
            try Data("checkpoint".utf8).write(to: tree.appendingPathComponent(name), options: .atomic)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        guard recursiveEvents.total() == beforeCheckpoint else {
            throw WatcherFailure(message: "Checkpoint writes triggered the recursive watcher")
        }
        print("PASS: real FSEvents checkpoint writes do not restart synchronization")
        await stopAndWait(recursive)
        print("PASS: recursive local watcher uses a constant number of descriptors")

        let pollEvents = WatcherEvents()
        let polling = DirectoryWatcher(mode: .polling) { _ in pollEvents.record() }
        polling.start(watching: [tree, deepest], interval: 30)
        await withCheckedContinuation { continuation in
            polling.setWatchedURLs([tree, deepest], completion: { continuation.resume() })
        }
        let pollingDescriptors = descriptorCount() - baseline
        guard pollingDescriptors < 20 else {
            throw WatcherFailure(message: "Polling watcher opened \(pollingDescriptors) descriptors")
        }
        await stopAndWait(polling)
        print("PASS: polling watchers do not hold a descriptor per directory")
    }
}
