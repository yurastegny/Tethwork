import Foundation

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

    static func main() async throws {
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
    }
}
