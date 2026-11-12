import Foundation
import Darwin

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

    func seedVerifiedPair(_ path: String) throws {
        let r = try fm.attributesOfItem(atPath: remote.appendingPathComponent(path).path)
        let l = try fm.attributesOfItem(atPath: local.appendingPathComponent(path).path)
        let pair: [String: Any] = [
            "remoteSize": r[.size]!, "localSize": l[.size]!,
            "remoteModified": (r[.modificationDate] as! Date).timeIntervalSinceReferenceDate,
            "localModified": (l[.modificationDate] as! Date).timeIntervalSinceReferenceDate,
            "remoteFileID": r[.systemFileNumber]!, "localFileID": l[.systemFileNumber]!
        ]
        let cache: [String: Any] = ["version": 1,
            "remotePath": remote.resolvingSymlinksInPath().path,
            "localPath": local.resolvingSymlinksInPath().path, "pairs": [path: pair]]
        try JSONSerialization.data(withJSONObject: cache).write(to: local.appendingPathComponent(".tethwork-verification-cache.json"))
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

    func waitForFolder(_ path: String, state: FolderStorageState, includeHidden: Bool = false) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let listing = try await engine.listDirectory(relativePath: parent == "." ? "" : parent, includeHidden: includeHidden)
            if listing.entries.first(where: { $0.relativePath == path })?.folderStorageState == state { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestFailure(description: "Folder \(path) did not reach \(state)")
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
            Case(name: "remaining time warms up and includes small-file overhead") { _ in
                var estimate = TransferTimeEstimator()
                _ = estimate.estimate(bytesDone: 0, filesDone: 0, bytesTotal: 100_000, filesTotal: 100, elapsed: 0)
                try expect(estimate.estimate(bytesDone: 40_000, filesDone: 4, bytesTotal: 100_000, filesTotal: 100, elapsed: 5) == nil,
                           "An ETA was guessed before enough measurements")
                let remaining = estimate.estimate(bytesDone: 95_000, filesDone: 10, bytesTotal: 100_000, filesTotal: 100, elapsed: 10)
                try expect(remaining == 90, "Byte speed hid the remaining per-file metadata work")
                var largeFile = TransferTimeEstimator()
                _ = largeFile.estimate(bytesDone: 0, filesDone: 0, bytesTotal: 10_000, filesTotal: 1, elapsed: 0)
                try expect(largeFile.estimate(bytesDone: 5_000, filesDone: 0, bytesTotal: 10_000, filesTotal: 1, elapsed: 10) == 10,
                           "An in-flight large file required a completed-file sample")
                var emptyFiles = TransferTimeEstimator()
                _ = emptyFiles.estimate(bytesDone: 0, filesDone: 0, bytesTotal: 0, filesTotal: 100, elapsed: 0)
                try expect(emptyFiles.estimate(bytesDone: 0, filesDone: 50, bytesTotal: 0, filesTotal: 100, elapsed: 10) == 10,
                           "Zero-byte files could not be estimated")
            },
            Case(name: "remaining time follows the recent window instead of the initial burst") { _ in
                var estimate = TransferTimeEstimator()
                _ = estimate.estimate(bytesDone: 0, filesDone: 0, bytesTotal: 10_000, filesTotal: 100, elapsed: 0)
                _ = estimate.estimate(bytesDone: 9_000, filesDone: 90, bytesTotal: 10_000, filesTotal: 100, elapsed: 10)
                _ = estimate.estimate(bytesDone: 9_400, filesDone: 94, bytesTotal: 10_000, filesTotal: 100, elapsed: 50)
                let remaining = estimate.estimate(bytesDone: 9_500, filesDone: 95, bytesTotal: 10_000, filesTotal: 100, elapsed: 60)
                try expect(remaining == 50, "An old fast burst made the current ETA overoptimistic")
            },
            Case(name: "byte-rate windows accumulate across small chunks and flush the final sample") { _ in
                let start = ContinuousClock.now
                var meter = SyncEngine.TransferRateMeter(startedAt: start)
                try expect(meter.record(bytes: 100, at: start.advanced(by: .milliseconds(100))) == nil,
                           "A sub-window sample should accumulate")
                let rate = meter.record(bytes: 100, at: start.advanced(by: .milliseconds(200)))
                try expect(rate == 1000, "The rate did not include all bytes in the window")
                try expect(meter.record(bytes: 50, at: start.advanced(by: .milliseconds(250))) == nil,
                           "The next sample did not start a new window")
                try expect(meter.flush(at: start.advanced(by: .milliseconds(300))) == 500,
                           "The final short window lost its bytes")
                try expect(meter.flush(at: start.advanced(by: .milliseconds(400))) == nil,
                           "An empty window fabricated a rate")
            },
            Case(name: "small-file transfer speeds survive progress throttling") { f in
                for index in 0..<40 {
                    try f.write(f.remote, "Work/\(index).txt", String(repeating: "x", count: 4096))
                }
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try expect(f.events.snapshot().contains {
                    $0.kind == .progress && $0.phase == .transferring && $0.transferDirection == .download && ($0.bytesPerSecond ?? 0) > 0
                }, "All measured rates were dropped by the UI throttle")
            },
            Case(name: "short reads and EINTR are filled to EOF without comparing mismatched chunk lengths") { _ in
                let expected = Data(repeating: 0x5A, count: 12_345)
                var offset = 0
                var calls = 0
                let actual = try SyncEngine.readFileChunk(descriptor: -1, path: "/test/short-reads", maximumCount: 32_768) { _, buffer, count in
                    calls += 1
                    if calls == 1 { errno = EINTR; return -1 }
                    let amount = min(17, min(count, expected.count - offset))
                    if amount == 0 { return 0 }
                    expected.withUnsafeBytes { bytes in
                        buffer.copyMemory(from: bytes.baseAddress!.advanced(by: offset), byteCount: amount)
                    }
                    offset += amount
                    return amount
                }
                try expect(actual == expected && calls > 3, "A short read/EINTR lost bytes or was mistaken for EOF")
            },
            Case(name: "read errors retain the actual POSIX code and source path instead of Cocoa 256") { _ in
                var failure: NSError?
                do { _ = try SyncEngine.readFileChunk(descriptor: -1, path: "/test/client.log") }
                catch { failure = error as NSError }
                try expect(failure?.domain == NSPOSIXErrorDomain && failure?.code == Int(EBADF), "The underlying read error was lost")
                try expect(failure?.userInfo[NSFilePathErrorKey] as? String == "/test/client.log", "The failing read path was lost")
            },
            Case(name: "synchronization read failures name the exact comparison files") { f in
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                try f.write(f.remote, "Work/client.log", "preserve", date: date)
                try f.write(f.local, "Work/client.log", "preserve", date: date)
                try await f.connect(pins: ["Work/client.log"])
                let path = f.remote.appendingPathComponent("Work/client.log").path
                try f.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
                await f.engine.fullSync()
                let failures = f.events.snapshot().filter { $0.kind == .error }
                try expect(failures.count == 1 && !f.events.snapshot().contains { $0.kind == .complete }, "Read failure was reported as Sync complete")
                let message = failures[0].message
                try expect(message.contains("Compare synchronized files") && message.contains("Source:") &&
                           message.contains("Destination:") && message.contains("Work/client.log") && message.contains("NSPOSIXErrorDomain (13)"),
                           "Comparison failure did not retain its path, operation and errno")
                try expect(try f.read(f.local, "Work/client.log") == "preserve", "Failed verification changed local contents")
            },
            Case(name: "comparison rejects FIFO and symbolic links without hanging or following their targets") { f in
                try f.write(f.remote, "file.txt", "safe")
                let fifo = f.local.appendingPathComponent("pipe").path
                try expect(mkfifo(fifo, 0o600) == 0, "Could not create FIFO fixture")
                var failures = 0
                do { _ = try await SyncEngine.filesHaveEqualContents(fifo, f.remote.appendingPathComponent("file.txt").path) }
                catch {
                    failures += 1
                    try expect(error.localizedDescription.contains("non-regular"), "FIFO was not identified")
                }
                let link = f.local.appendingPathComponent("link")
                try f.fm.createSymbolicLink(at: link, withDestinationURL: f.remote.appendingPathComponent("file.txt"))
                do { _ = try await SyncEngine.filesHaveEqualContents(link.path, f.remote.appendingPathComponent("file.txt").path) }
                catch {
                    failures += 1
                    try expect((error as NSError).code == Int(ELOOP), "Symbolic link failure lost its actual errno")
                }
                try expect(failures == 2, "Unsafe comparison source was accepted")
            },
            Case(name: "comparison checks all bytes across chunk boundaries") { f in
                let prefix = String(repeating: "x", count: 1024 * 1024 + 18)
                try f.write(f.remote, "file.txt", prefix + "x")
                try f.write(f.local, "file.txt", prefix + "x")
                let lhs = f.remote.appendingPathComponent("file.txt").path
                let rhs = f.local.appendingPathComponent("file.txt").path
                let equal = try await SyncEngine.filesHaveEqualContents(lhs, rhs)
                try expect(equal, "Equal multi-chunk files differ")
                try f.write(f.local, "file.txt", prefix + "y")
                let different = try await SyncEngine.filesHaveEqualContents(lhs, rhs)
                try expect(!different, "A difference after the first chunk was ignored")
            },
            Case(name: "failed folder checks recover after access returns without reopening or Sync Now") { f in
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                for base in [f.remote, f.local] {
                    try f.write(base, "Work/Sub/file.txt", "local", date: date)
                }
                try await f.connect(pins: ["Work"])
                let locked = f.remote.appendingPathComponent("Work/Sub").path
                try f.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
                _ = try await f.engine.listDirectory(relativePath: "")
                let failedDeadline = Date().addingTimeInterval(3)
                while !f.events.snapshot().contains(where: { $0.kind == .storage && $0.path == "Work/Sub" && $0.folderStorageState == .unavailable }),
                      Date() < failedDeadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try expect(f.events.snapshot().contains { $0.kind == .storage && $0.path == "Work/Sub" && $0.folderStorageState == .unavailable },
                           "Fixture did not produce a failed folder check")
                try f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked)
                let recoveredDeadline = Date().addingTimeInterval(8)
                while Date() < recoveredDeadline {
                    if f.events.snapshot().contains(where: { $0.kind == .storage && $0.path == "Work" && $0.folderStorageState == .local }) { return }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw TestFailure(description: "A transient access failure left a permanent Could not check badge")
            },
            Case(name: "failed folder checks recover when the failed child is renamed") { f in
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                for base in [f.remote, f.local] {
                    try f.write(base, "Work/Sub/file.txt", "local", date: date)
                }
                try await f.connect(pins: ["Work"])
                let locked = f.remote.appendingPathComponent("Work/Sub")
                try f.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
                _ = try await f.engine.listDirectory(relativePath: "")
                let failedDeadline = Date().addingTimeInterval(3)
                while !f.events.snapshot().contains(where: { $0.path == "Work/Sub" && $0.folderStorageState == .unavailable }),
                      Date() < failedDeadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try expect(f.events.snapshot().contains { $0.path == "Work/Sub" && $0.folderStorageState == .unavailable },
                           "Fixture did not produce a failed folder check")
                try f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
                // Simulate an external rename while the failed scan waits to retry.
                for base in [f.remote, f.local] {
                    try f.fm.moveItem(at: base.appendingPathComponent("Work/Sub"),
                                      to: base.appendingPathComponent("Work/Renamed"))
                }
                let recoveredDeadline = Date().addingTimeInterval(8)
                while Date() < recoveredDeadline {
                    if f.events.snapshot().contains(where: { $0.path == "Work" && $0.folderStorageState == .local }) { return }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw TestFailure(description: "A vanished child left its parent permanently Could not check")
            },
            Case(name: "failed folder checks recover when the failed child is deleted") { f in
                for base in [f.remote, f.local] {
                    try f.write(base, "Work/Sub/file.txt", "local")
                }
                try await f.connect(pins: ["Work"])
                let locked = f.remote.appendingPathComponent("Work/Sub").path
                try f.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
                _ = try await f.engine.listDirectory(relativePath: "")
                let failedDeadline = Date().addingTimeInterval(3)
                while !f.events.snapshot().contains(where: { $0.path == "Work/Sub" && $0.folderStorageState == .unavailable }),
                      Date() < failedDeadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try expect(f.events.snapshot().contains { $0.path == "Work/Sub" && $0.folderStorageState == .unavailable },
                           "Fixture did not produce a failed folder check")
                try f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked)
                for base in [f.remote, f.local] {
                    try f.fm.removeItem(at: base.appendingPathComponent("Work/Sub"))
                }
                let recoveredDeadline = Date().addingTimeInterval(8)
                while Date() < recoveredDeadline {
                    if f.events.snapshot().contains(where: { $0.path == "Work" && $0.folderStorageState == .local }) { return }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw TestFailure(description: "A deleted child left its parent permanently Could not check")
            },
            Case(name: "remote recovery is reported before the complete synchronization finishes") { f in
                try f.write(f.remote, "Work/file.txt", "local")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                let detached = f.root.appendingPathComponent("unmounted")
                try f.fm.moveItem(at: f.remote, to: detached)
                defer { try? f.fm.moveItem(at: detached, to: f.remote) }
                await f.engine.fullSync()
                try expect(f.events.snapshot().contains { $0.kind == .error && $0.isRemoteUnavailable }, "Missing root was not reported")
                try f.fm.moveItem(at: detached, to: f.remote)
                try await f.sync()
                let events = f.events.snapshot()
                let recovered = events.firstIndex { $0.isRemoteAvailable }
                let complete = events.firstIndex { $0.kind == .complete }
                try expect(recovered != nil && complete != nil && recovered! < complete!, "Recovery waited for the entire tree")
            },
            Case(name: "unreadable nested contents cannot establish a Local parent badge") { f in
                try f.write(f.remote, "Work/Locked/file.txt", "local")
                try await f.connect(pins: ["Work/Locked/file.txt"])
                try await f.sync()
                await f.engine.disconnect()
                let locked = f.remote.appendingPathComponent("Work/Locked").path
                try f.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
                try await f.connect(pins: ["Work/Locked/file.txt"])
                try await f.waitForFolder("Work", state: .unavailable)
            },
            Case(name: "switching volumes retains last-known folder badges without mixing roots") { f in
                try f.write(f.remote, "Work/file.txt", "local")
                try await f.connect(pins: ["Work/file.txt"])
                try await f.sync()
                try await f.waitForFolder("Work", state: .local)
                let otherRemote = f.root.appendingPathComponent("other-remote")
                let otherLocal = f.root.appendingPathComponent("other-local")
                try f.write(otherRemote, "Work/file.txt", "local")
                try f.write(otherLocal, "Work/file.txt", "local")
                try f.write(otherRemote, "Work/online.txt", "online")
                let other = SyncConnection(id: "other", name: "Other", remotePath: otherRemote.path, localPath: otherLocal.path)
                try await f.engine.connect(connection: other, pinned: ["Work/file.txt"])
                let initial = try await f.engine.listDirectory(relativePath: "")
                try expect(initial.entries.first?.folderStorageState != .local, "Another server inherited Local")
                try await f.waitForFolder("Work", state: .partial)
                try await f.connect(pins: ["Work/file.txt"])
                let returned = try await f.engine.listDirectory(relativePath: "")
                try expect(returned.entries.first?.folderStorageState == .local, "Returning to a volume reset its badge")
                try await f.engine.connect(connection: other, pinned: ["Work/file.txt"])
                let otherReturned = try await f.engine.listDirectory(relativePath: "")
                try expect(otherReturned.entries.first?.folderStorageState == .partial, "Partial badge was not retained")
            },
            Case(name: "cached folder badges still refresh changes made while disconnected") { f in
                try f.write(f.remote, "Work/file.txt", "local")
                try await f.connect(pins: ["Work/file.txt"])
                try await f.sync()
                try await f.waitForFolder("Work", state: .local)
                await f.engine.disconnect()
                try f.write(f.remote, "Work/online.txt", "new online file")
                try await f.connect(pins: ["Work/file.txt"])
                let returned = try await f.engine.listDirectory(relativePath: "")
                try expect(returned.entries.first?.folderStorageState == .local, "Last-known badge disappeared")
                try await f.waitForFolder("Work", state: .partial)
                try expect(!f.exists(f.local, "Work/online.txt"), "Display cache changed pin policy")
            },
            Case(name: "cached folder badges never hide missing local folders or changed pins") { f in
                try f.write(f.remote, "Work/file.txt", "local")
                try await f.connect(pins: ["Work/file.txt"])
                try await f.sync()
                try await f.waitForFolder("Work", state: .local)
                await f.engine.disconnect()
                try f.fm.removeItem(at: f.local.appendingPathComponent("Work"))
                try await f.connect(pins: ["Work/file.txt"])
                let missing = try await f.engine.listDirectory(relativePath: "")
                try expect(missing.entries.first?.folderStorageState == .pending, "Cached Local hid a missing folder")
                try await f.connect(pins: [])
                let unpinned = try await f.engine.listDirectory(relativePath: "")
                try expect(unpinned.entries.first?.folderStorageState == .onlineOnly, "Cached badge ignored changed pins")
            },
            Case(name: "local folder badges resolve while unrelated files are still being checked") { f in
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                for base in [f.remote, f.local] {
                    try f.write(base, "Ready/file.txt", "ready", date: date)
                    for index in 0..<800 {
                        try f.write(base, "Bulk/\(index).txt", "unchanged", date: date)
                    }
                }
                try await f.connect(pins: ["Ready", "Bulk"])
                let once = OneShot()
                let engine = f.engine
                let events = f.events
                await engine.setEventHandler { event in
                    events.append(event)
                    if event.kind == .progress, event.phase == .preparing, once.take() {
                        Task { _ = try? await engine.listDirectory(relativePath: "") }
                    }
                }
                try await f.sync()
                let log = events.snapshot()
                let local = log.firstIndex { $0.kind == .storage && $0.path == "Ready" && $0.folderStorageState == .local }
                let complete = log.firstIndex { $0.kind == .complete }
                try expect(local != nil && complete != nil && local! < complete!,
                           "An unrelated global check blocked the Ready folder's Local badge")
            },
            Case(name: "sync invalidation rechecks visible folders without reopening them") { f in
                try f.write(f.remote, "Work/Sub/file.txt", "local")
                try await f.connect(pins: ["Work"])
                _ = try await f.engine.listDirectory(relativePath: "")
                try await f.sync()
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline {
                    if f.events.snapshot().contains(where: {
                        $0.kind == .storage && $0.path == "Work" && $0.folderStorageState == .local
                    }) { return }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw TestFailure(description: "Sync discarded the visible folder's background check")
            },
            Case(name: "queued folder checks resume after a merge without reopening the directory") { f in
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                try f.write(f.remote, "Work/Sub/file.txt", "local", date: date)
                try f.write(f.local, "Work/Sub/file.txt", "local", date: date)
                try await f.connect(pins: ["Work"])
                try await f.engine.prepareInitialMerge(connectionID: f.connection.id)
                let listing = try await f.engine.listDirectory(relativePath: "")
                try expect(listing.entries.first?.folderStorageState == .checking, "Fixture did not queue a folder check")
                try await f.engine.abortInitialMerge(connectionID: f.connection.id)
                // Do not poll listDirectory: reopening it would restart a stranded worker.
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    if f.events.snapshot().contains(where: {
                        $0.kind == .storage && $0.path == "Work" && $0.folderStorageState == .local
                    }) { return }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw TestFailure(description: "A paused folder check stayed Checking after all nested files were Local")
            },
            Case(name: "temporary cleanup groups file pins without recursively crawling folder pins") { _ in
                let files = Set((0..<1_000).map { "Photos/\($0).jpg" })
                let paths = SyncEngine.temporaryCleanupPaths(pins: files.union(["Work"]), verifiedFiles: files)
                try expect(paths == ["Photos", "Work"], "Cleanup tried a directory read for each individual file")
                try expect(SyncEngine.temporaryCleanupPaths(pins: ["root.txt", ""], verifiedFiles: ["root.txt"]) == [""],
                           "Root file pins were not deduplicated")
            },
            Case(name: "cached pin ancestor index follows pin additions and removals") { f in
                for base in [f.remote, f.local] {
                    try f.write(base, "A/file.txt", "a")
                    try f.write(base, "B/file.txt", "b")
                }
                try await f.connect(pins: ["A/file.txt"])
                let first = try await f.engine.listDirectory(relativePath: "")
                try expect(first.entries.first(where: { $0.name == "A" })?.hasPinnedDescendants == true,
                           "Initial pin ancestor was not indexed")
                _ = try await f.engine.setPinned(relativePath: "B/file.txt", pinned: true)
                let added = try await f.engine.listDirectory(relativePath: "")
                try expect(added.entries.first(where: { $0.name == "B" })?.hasPinnedDescendants == true,
                           "Adding a pin reused a stale ancestor index")
                _ = try await f.engine.setPinned(relativePath: "A/file.txt", pinned: false)
                let removed = try await f.engine.listDirectory(relativePath: "")
                try expect(removed.entries.first(where: { $0.name == "A" })?.hasPinnedDescendants == false,
                           "Removing a pin reused a stale ancestor index")
                try expect(removed.entries.first(where: { $0.name == "B" })?.hasPinnedDescendants == true,
                           "Removing one pin discarded unrelated ancestors")
            },
            Case(name: "a folder containing only synchronized empty folders becomes Local") { f in
                for index in 0..<12 {
                    try f.fm.createDirectory(at: f.local.appendingPathComponent("Work/Sub-\(index)/Empty"),
                                             withIntermediateDirectories: true)
                }
                try f.fm.createDirectory(at: f.remote.appendingPathComponent("Work"), withIntermediateDirectories: true)
                try await f.connect(pins: ["Work"])
                _ = try await f.engine.listDirectory(relativePath: "")
                _ = try await f.engine.listDirectory(relativePath: "Work")
                try await f.sync()
                try await f.waitForFolder("Work", state: .local)
            },
            Case(name: "a child becoming Local clears its parent's stale directory-only Pending badge") { f in
                try f.fm.createDirectory(at: f.local.appendingPathComponent("Work/Sub"), withIntermediateDirectories: true)
                try f.fm.createDirectory(at: f.remote.appendingPathComponent("Work"), withIntermediateDirectories: true)
                try await f.connect(pins: ["Work"])
                _ = try await f.engine.listDirectory(relativePath: "Work")
                // Simulate a directory upload finishing after the parent was read.
                try f.fm.createDirectory(at: f.remote.appendingPathComponent("Work/Sub"), withIntermediateDirectories: true)
                _ = try await f.engine.listDirectory(relativePath: "Work/Sub")
                let root = try await f.engine.listDirectory(relativePath: "")
                try expect(root.entries.first?.folderStorageState == .local,
                           "A stale pending directory snapshot overrode the child's fresh Local state")
            },
            Case(name: "all individually local files make the parent Local without pinning the parent") { f in
                try f.write(f.remote, "Work/one.txt", "one")
                try f.write(f.remote, "Work/two.txt", "two")
                try f.write(f.remote, "Work/._one.txt", "paired AppleDouble metadata")
                try await f.connect(pins: ["Work/one.txt", "Work/two.txt"])
                try await f.sync()
                try await f.waitForFolder("Work", state: .local)
                let pins = await f.engine.getPinnedPaths()
                try expect(pins == ["Work/one.txt", "Work/two.txt"], "A storage badge pinned the whole folder")
                try f.write(f.remote, "Work/new-online.txt", "online")
                try await f.sync()
                try await f.waitForFolder("Work", state: .partial)
                try expect(!f.exists(f.local, "Work/new-online.txt"), "A Local badge downloaded a newly added unpinned file")
                try f.fm.removeItem(at: f.remote.appendingPathComponent("Work/new-online.txt"))
                try await f.sync()
                try await f.waitForFolder("Work", state: .local)
            },
            Case(name: "nested online-only contents prevent a parent from falsely becoming Local") { f in
                try f.write(f.remote, "Work/Sub/local.txt", "local")
                try f.write(f.remote, "Work/Sub/online.txt", "online")
                try await f.connect(pins: ["Work/Sub/local.txt"])
                try await f.sync()
                try await f.waitForFolder("Work", state: .partial)
                try await f.waitForFolder("Work/Sub", state: .partial)
                _ = try await f.engine.setPinned(relativePath: "Work/Sub/online.txt", pinned: true)
                try await f.waitForFolder("Work", state: .local)
                try await f.waitForFolder("Work/Sub", state: .local)
            },
            Case(name: "hidden user files participate in folder storage even when not displayed") { f in
                try f.write(f.remote, "Work/local.txt", "local")
                try f.write(f.remote, "Work/.env", "online-only hidden data")
                try await f.connect(pins: ["Work/local.txt"])
                try await f.sync()
                let visible = try await f.engine.listDirectory(relativePath: "Work")
                try expect(visible.entries.map(\.name) == ["local.txt"], "Visibility preference changed")
                try await f.waitForFolder("Work", state: .partial)
                _ = try await f.engine.setPinned(relativePath: "Work/.env", pinned: true)
                try await f.waitForFolder("Work", state: .local)
            },
            Case(name: "verified equal files with rounded mtimes do not remain pending after Sync complete") { f in
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                try f.write(f.remote, "Work/file.txt", "equal", date: date)
                try f.write(f.local, "Work/file.txt", "equal", date: date.addingTimeInterval(0.5))
                try await f.connect(pins: ["Work/file.txt"])
                let before = try await f.engine.listDirectory(relativePath: "Work")
                try expect(before.entries[0].syncStatus == .pending, "Unverified timestamp differences were hidden")
                try await f.sync()
                let after = try await f.engine.listDirectory(relativePath: "Work")
                try expect(after.entries[0].syncStatus == .synced, "A completed byte verification left a pending badge")
                try expect(!f.events.snapshot().contains { $0.kind == .file && $0.isTransfer }, "Identical bytes were copied just to repair a badge")
                let searched = try await f.engine.search(query: "file.txt", under: "")
                try expect(searched.count == 1 && searched[0].syncStatus == .synced, "Search disagrees with the listing")
                try f.write(f.local, "Work/file.txt", "edit!", date: date.addingTimeInterval(1.5))
                let edited = try await f.engine.listDirectory(relativePath: "Work")
                try expect(edited.entries[0].syncStatus == .pending, "A real local edit reused an obsolete verification")
                try await f.sync()
                try expect(try f.read(f.remote, "Work/file.txt") == "edit!", "A real edit was hidden by the status fix")
            },
            Case(name: "individually pinned descendants are exposed without pinning online-only siblings") { f in
                try f.write(f.remote, "Work/local.txt", "local")
                try f.write(f.remote, "Work/online.txt", "online")
                try await f.connect(pins: ["Work/local.txt"])
                try await f.sync()
                let root = try await f.engine.listDirectory(relativePath: "")
                let folder = root.entries.first { $0.name == "Work" }!
                try expect(folder.hasPinnedDescendants && folder.isLocallyAvailable, "Parent lost its partial-local status")
                try expect(folder.syncMode == .onlineOnly, "A display fix silently pinned the whole parent")
                let children = try await f.engine.listDirectory(relativePath: "Work")
                try expect(children.entries.first { $0.name == "local.txt" }?.syncStatus == .synced, "Pinned file is not synchronized")
                try expect(children.entries.first { $0.name == "online.txt" }?.syncStatus == .onlineOnly, "Online-only sibling lost its policy")
                try expect(!f.exists(f.local, "Work/online.txt"), "Online-only sibling was downloaded")
                let searched = try await f.engine.search(query: "Work", under: "")
                try expect(searched.first?.hasPinnedDescendants == true, "Search lost the parent's partial-local status")
            },
            Case(name: "internal state cannot make enumeration skip the following user folder") { f in
                try f.write(f.remote, ".tethwork-sync-state.json", "internal")
                try f.write(f.remote, "Z/sub/file.txt", "keep baseline")
                try await f.connect(pins: [""])
                try await f.sync()
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: f.local.appendingPathComponent(".tethwork-sync-state.json"))) as! [String: Any]
                let paths = state["syncedPaths"] as? [String] ?? []
                try expect(paths.contains("Z/sub/file.txt"), "Skipping an internal file also skipped a user subtree")
            },
            Case(name: "individual file pins share directory watchers") { _ in
                let files = Set((0..<1000).map { "Work/file-\($0).txt" })
                let watches = SyncEngine.watchDirectoryPaths(pins: files, knownPaths: files)
                try expect(watches == ["", "Work"], "One thousand files created one thousand watchers")
                let nested = SyncEngine.watchDirectoryPaths(pins: ["Work"], knownPaths: ["Work", "Work/sub/file.txt"])
                try expect(nested == ["", "Work", "Work/sub"], "Nested pinned directories lost change coverage")
            },
            Case(name: "pinned local-only rows are visible while an upload is pending") { f in
                try f.write(f.local, "Work/new.txt", "pending")
                try f.write(f.local, "Unpinned/other.txt", "not selected")
                try await f.connect(pins: ["Work"])
                let root = try await f.engine.listDirectory(relativePath: "")
                try expect(root.entries.map(\.name) == ["Work"], "Pending local folder was hidden or unpinned content leaked")
                let listing = try await f.engine.listDirectory(relativePath: "Work")
                try expect(listing.entries.count == 1 && listing.entries[0].syncStatus == .pending && listing.entries[0].isLocallyAvailable,
                           "Pending local file was missing or falsely reported synchronized")
                try expect(!f.exists(f.remote, "Work/new.txt"), "Browsing performed an upload")
            },
            Case(name: "trash preserves unrelated deletion history without rescanning pins") { f in
                try f.write(f.remote, "Delete/sub/file.txt", "payload")
                try f.write(f.local, "Delete/sub/file.txt", "payload")
                try await f.engine.connect(connection: f.connection, pinned: ["Delete", "Unrelated"],
                                           initiallySyncedPaths: ["Delete", "Delete/sub", "Delete/sub/file.txt", "Unrelated/previous.txt"])
                let before = try f.fm.attributesOfItem(atPath: f.remote.appendingPathComponent("Delete").path)[.systemFileNumber] as? NSNumber
                try await f.engine.trashItems(relativePaths: ["Delete"])
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: f.local.appendingPathComponent(".tethwork-sync-state.json"))) as! [String: Any]
                try expect(state["syncedPaths"] as? [String] == ["Unrelated/previous.txt"], "Trash rescanned or discarded unrelated history")
                let trash = TrashStore.loadItems(remoteRoot: f.remote.path)
                try expect(trash.count == 1, "Folder was split into per-file Trash operations")
                let after = try f.fm.attributesOfItem(atPath: TrashStore.payloadPath(remoteRoot: f.remote.path, item: trash[0]))[.systemFileNumber] as? NSNumber
                try expect(before == after, "Trash copied the tree instead of renaming it")
                try expect(!f.exists(f.local, "Delete"), "Local folder did not disappear with the remote folder")
            },
            Case(name: "import preserves dotfiles, empty subfolders and duplicate dropped names") { f in
                try f.write(f.root, "Source/.env", "secret settings")
                try f.write(f.root, "Source/.tethwork-sync-state.json", "not user content")
                try f.fm.createDirectory(at: f.root.appendingPathComponent("Source/Empty"), withIntermediateDirectories: true)
                try f.write(f.root, "A/report.txt", "first")
                try f.write(f.root, "B/report.txt", "second")
                try await f.connect(pins: [""])
                try await f.engine.importItems(from: [f.root.appendingPathComponent("Source"),
                                                      f.root.appendingPathComponent("A/report.txt"),
                                                      f.root.appendingPathComponent("B/report.txt")], toDirectory: "")
                try expect(try f.read(f.remote, "Source/.env") == "secret settings", "Import skipped a user dotfile")
                try expect(f.exists(f.remote, "Source/Empty"), "Import omitted an empty subfolder")
                try expect(!f.exists(f.remote, "Source/.tethwork-sync-state.json"), "Import copied internal state")
                try expect(try f.read(f.remote, "report.txt") == "first", "Dropped files overwrote each other")
                try expect(try f.read(f.remote, "report 2.txt") == "second", "Duplicate drop name was not reserved")
                try f.write(f.local, "Source/.env", "edited", date: Date().addingTimeInterval(60))
                try await f.sync()
                try expect(try f.read(f.remote, "Source/.env") == "edited", "Imported dotfile stopped synchronizing")
            },
            Case(name: "aborted adoption preserves existing pins and deletion history") { f in
                try f.write(f.remote, "Work/file.txt", "baseline")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try await f.engine.prepareInitialMerge(connectionID: f.connection.id)
                try await f.engine.abortInitialMerge(connectionID: f.connection.id)
                let pins = await f.engine.getPinnedPaths()
                try expect(pins == ["Work"], "Aborting adoption lost existing pins")
                try f.fm.removeItem(at: f.local.appendingPathComponent("Work/file.txt"))
                try await f.sync()
                try expect(TrashStore.containsTrashedPath("Work/file.txt", remoteRoot: f.remote.path), "Aborting adoption erased the deletion baseline")
            },
            Case(name: "mutations reject traversal paths before writing") { f in
                try f.write(f.remote, "safe.txt", "safe")
                try await f.connect(pins: [])
                var failures = 0
                do { try await f.engine.moveItems(relativePaths: ["../escape"], toDirectory: "") } catch { failures += 1 }
                do { _ = try await f.engine.renameItem(relativePath: "../escape", newName: "renamed") } catch { failures += 1 }
                do { _ = try await f.engine.setPinned(relativePath: "../escape", pinned: true) } catch { failures += 1 }
                try expect(failures == 3, "A mutation accepted an unsafe relative path")
                try expect(try f.read(f.remote, "safe.txt") == "safe", "Validation damaged existing files")
            },
            Case(name: "another Mac's Trash deletion does not resurrect a stale local copy") { f in
                try f.write(f.remote, "Work/sub/file.txt", "before deletion")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                _ = try TrashStore.moveToTrash(relativePath: "Work/sub", remoteRoot: f.remote.path, wasPinned: true)
                try await f.sync()
                try expect(!f.exists(f.remote, "Work/sub") && !f.exists(f.local, "Work/sub"), "Stale local copy resurrected a deletion")
                try expect(f.events.snapshot().contains { $0.kind == .trash }, "Remote deletion was not explained")
                try expect(TrashStore.loadItems(remoteRoot: f.remote.path).count == 1, "Recoverable deletion was lost")
            },
            Case(name: "a new file can reuse a formerly trashed name") { f in
                try f.write(f.remote, "Work/file.txt", "old")
                _ = try TrashStore.moveToTrash(relativePath: "Work/file.txt", remoteRoot: f.remote.path, wasPinned: false)
                try f.write(f.local, "Work/file.txt", "new")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try expect(try f.read(f.remote, "Work/file.txt") == "new", "Trash deleted a genuinely new local file")
            },
            Case(name: "last-write-wins emits an explicit overwrite warning") { f in
                try f.write(f.remote, "Work/file.txt", "network")
                try f.write(f.local, "Work/file.txt", "local", date: Date().addingTimeInterval(60))
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try expect(try f.read(f.remote, "Work/file.txt") == "local", "Newest edit did not win")
                try expect(f.events.snapshot().contains { $0.kind == .conflict && $0.path == "Work/file.txt" }, "Overwrite was silent")
            },
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
            Case(name: "a write failure retries with backoff and manual Sync resumes immediately", watchChanges: true) { f in
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
                let errors = f.events.snapshot().filter { $0.kind == .error }.count
                try expect(errors >= 2 && errors <= 4, "Automatic retry did not back off")
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
            Case(name: "regular uploads atomically replace a dangling destination symlink") { f in
                try f.write(f.local, "Work/tool", "new regular file", date: Date().addingTimeInterval(60))
                try f.fm.createDirectory(at: f.remote.appendingPathComponent("Work"), withIntermediateDirectories: true)
                try f.fm.createSymbolicLink(atPath: f.remote.appendingPathComponent("Work/tool").path,
                                            withDestinationPath: "missing-target")
                try await f.connect(pins: ["Work/tool"])
                try await f.sync()
                try expect(try f.read(f.remote, "Work/tool") == "new regular file", "Dangling link blocked publication")
                try expect(!f.exists(f.remote, "Work/missing-target"), "Upload followed the destination link")
                try await f.sync()
            },
            Case(name: "SMB bulk link sizes are normalized to reconciliation metadata") { f in
                let link = f.local.appendingPathComponent("release")
                let target = "out/Products/Release"
                try f.fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
                let size = try SyncEngine.listingSize(at: link, isSymbolicLink: true, reportedSize: 1067)
                try expect(size == Int64(target.utf8.count), "SMB container size was compared with the cached link size")
                // Non-links must not pay for an extra stat on every row.
                let missing = f.local.appendingPathComponent("not-created")
                try expect(try SyncEngine.listingSize(at: missing, isSymbolicLink: false, reportedSize: 42) == 42,
                            "Regular listings discarded their bulk metadata")
            },
            Case(name: "SMB XSym sizes normalize even when bulk reads lose the remote link flag") { f in
                let link = f.remote.appendingPathComponent("release")
                let target = "out/Products/Release"
                try f.fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
                // Simulate the NAS's bulk metadata: a regular 1067-byte file,
                // even though attributesOfItem sees a normal symbolic link.
                let size = try SyncEngine.listingSize(at: link, isSymbolicLink: false, reportedSize: 1067,
                                                     pairedIsSymbolicLink: true)
                try expect(size == Int64(target.utf8.count),
                           "The missing SMB link flag left a verified link and every ancestor Pending")
                // A genuine XSym container remains its real size. The local
                // link is only a reason to stat, not permission to assume equality.
                try f.write(f.remote, "container", String(repeating: "x", count: 1067))
                let container = try SyncEngine.listingSize(at: f.remote.appendingPathComponent("container"),
                                                          isSymbolicLink: false, reportedSize: 1067,
                                                          pairedIsSymbolicLink: true)
                try expect(container == 1067, "A real remote size difference was hidden")
            },
            Case(name: "cached debug and release directory links make a build folder Local") { f in
                for (name, target) in [("debug", "out/Products/Debug"), ("release", "out/Products/Release")] {
                    let path = "Projects/Barttery/.build/\(name)"
                    for base in [f.remote, f.local] {
                        let link = base.appendingPathComponent(path)
                        try f.fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try f.fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
                    }
                }
                try await f.connect(pins: ["Projects"])
                try await f.sync()
                try await f.waitForFolder("Projects/Barttery", state: .local)
                try await f.waitForFolder("Projects/Barttery/.build", state: .local, includeHidden: true)
                let listing = try await f.engine.listDirectory(relativePath: "Projects/Barttery/.build", includeHidden: true)
                try expect(listing.entries.allSatisfy { !$0.isDirectory && $0.syncStatus == .synced },
                           "A directory symlink was traversed or left Pending")
                let results = try await f.engine.search(query: "release", under: "Projects", includeHidden: true)
                try expect(results.count == 1 && results[0].syncStatus == .synced && !results[0].isDirectory,
                           "Search uses different link metadata from folder badges")
            },
            Case(name: "verified SMB XSym links make every parent Local without repeated uploads") { f in
                let path = "Projects/App/node_modules/package/node_modules/.bin/tool"
                try f.write(f.remote, path, String(repeating: "x", count: 1067))
                let link = f.local.appendingPathComponent(path)
                try f.fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try f.fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../package/bin/tool.js")
                try f.seedVerifiedPair(path)
                try await f.connect(pins: ["Projects"])
                let listing = try await f.engine.listDirectory(relativePath: "Projects/App/node_modules/package/node_modules/.bin")
                try expect(listing.entries.first?.syncStatus == .synced,
                           "A verified size difference was still displayed as Pending")
                try await f.sync()
                try expect(!f.events.snapshot().contains { $0.phase == .transferring },
                           "An unchanged XSym representation was uploaded again")
                try await f.waitForFolder("Projects", state: .local)
                try await f.waitForFolder("Projects/App/node_modules/package/node_modules", state: .local)
                // The verification must not hide a genuinely changed source.
                try f.fm.removeItem(at: link)
                try f.fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../changed-target.js")
                let changed = try await f.engine.listDirectory(relativePath: "Projects/App/node_modules/package/node_modules/.bin")
                try expect(changed.entries.first?.syncStatus == .pending,
                           "A changed symlink reused a stale verified pair")
            },
            Case(name: "node bin links replace dangling links without changing target contents or dates") { f in
                let relative = "Work/.bin/js-yaml"
                let targetDate = Date(timeIntervalSince1970: 1_600_000_000)
                try f.write(f.remote, "Work/lib/tool.js", "target", date: targetDate)
                try f.write(f.local, "Work/lib/tool.js", "target", date: targetDate)
                for root in [f.remote, f.local] {
                    try f.fm.createDirectory(at: root.appendingPathComponent("Work/.bin"), withIntermediateDirectories: true)
                }
                let remoteLink = f.remote.appendingPathComponent(relative).path
                let localLink = f.local.appendingPathComponent(relative).path
                try f.fm.createSymbolicLink(atPath: remoteLink, withDestinationPath: "missing-target")
                var oldTimes = [timeval(tv_sec: 1_500_000_000, tv_usec: 0), timeval(tv_sec: 1_500_000_000, tv_usec: 0)]
                try expect(lutimes(remoteLink, &oldTimes) == 0, "Could not set old link timestamps")
                try f.fm.createSymbolicLink(atPath: localLink, withDestinationPath: "../lib/tool.js")
                try await f.connect(pins: [relative])
                try await f.sync()
                try expect(try f.fm.destinationOfSymbolicLink(atPath: remoteLink) == "../lib/tool.js",
                           "Link text was not copied")
                let target = f.remote.appendingPathComponent("Work/lib/tool.js").path
                try expect((try f.fm.attributesOfItem(atPath: target)[.modificationDate] as? Date) == targetDate,
                           "Staging a symlink changed the target modification date")
                try expect(try f.read(f.remote, "Work/lib/tool.js") == "target", "Link copy changed its target")
                try await f.sync()
                try expect(!f.events.snapshot().contains { $0.phase == .transferring }, "An unchanged link was recopied")
                await f.engine.fullSync(recheckContents: true)
                try expect(!f.events.snapshot().contains { $0.kind == .error }, "Full check opened the symlink as a regular file")
            },
            Case(name: "links to directories are copied as links rather than traversed") { f in
                try f.write(f.remote, "Assets/file.txt", "not pinned")
                try f.fm.createDirectory(at: f.remote.appendingPathComponent("Work"), withIntermediateDirectories: true)
                try f.fm.createSymbolicLink(atPath: f.remote.appendingPathComponent("Work/link").path,
                                            withDestinationPath: "../Assets")
                try await f.connect(pins: ["Work/link"])
                try await f.sync()
                let local = f.local.appendingPathComponent("Work/link").path
                try expect(try f.fm.destinationOfSymbolicLink(atPath: local) == "../Assets", "Directory link was expanded into a tree")
                try expect(!f.exists(f.local, "Assets"), "An unpinned link target was downloaded")
            },
            Case(name: "dangling source links synchronize without reading nonexistent targets") { f in
                try f.fm.createDirectory(at: f.remote.appendingPathComponent("Work"), withIntermediateDirectories: true)
                let remote = f.remote.appendingPathComponent("Work/link").path
                try f.fm.createSymbolicLink(atPath: remote, withDestinationPath: "not-created-yet")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                let local = f.local.appendingPathComponent("Work/link").path
                try expect(try f.fm.destinationOfSymbolicLink(atPath: local) == "not-created-yet", "Dangling link disappeared")
                try await f.sync()
                try expect(!f.events.snapshot().contains { $0.phase == .transferring }, "Dangling link was repeatedly copied")
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
            Case(name: "verification cache survives restart and full check bypasses it") { f in
                try f.write(f.remote, "Work/file.txt", "verified")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                await f.engine.disconnect()
                let localFile = f.local.appendingPathComponent("Work/file.txt").path
                try f.fm.setAttributes([.posixPermissions: 0], ofItemAtPath: localFile)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localFile) }
                let restarted = SyncEngine(watchesDirectories: false)
                let log = EventLog()
                await restarted.setEventHandler { log.append($0) }
                try await restarted.connect(connection: f.connection, pinned: ["Work"])
                await restarted.fullSync()
                try expect(!log.snapshot().contains { $0.kind == .error },
                           "Restart re-read unchanged cached file contents")
                log.clear()
                await restarted.fullSync(recheckContents: true)
                try expect(log.snapshot().contains { $0.kind == .error }, "Full check incorrectly used the cache")
                await restarted.disconnect()
            },
            Case(name: "full content check detects in-place edits that preserve size and timestamp") { f in
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                try f.write(f.remote, "Work/file.txt", "AAAA", date: date)
                try f.write(f.local, "Work/file.txt", "AAAA", date: date)
                try await f.connect(pins: ["Work"])
                try await f.sync()
                let path = f.local.appendingPathComponent("Work/file.txt")
                let handle = try FileHandle(forWritingTo: path)
                try handle.write(contentsOf: Data("BBBB".utf8))
                try handle.close()
                try f.fm.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
                try await f.sync()
                try expect(try f.read(f.remote, "Work/file.txt") == "AAAA", "Normal check did not use cached metadata")
                f.events.clear()
                await f.engine.fullSync(recheckContents: true)
                try expect(!f.events.snapshot().contains { $0.kind == .error }, "Full content check failed")
                try expect(try f.read(f.remote, "Work/file.txt") == f.read(f.local, "Work/file.txt"),
                           "Full check missed an edit preserving metadata")
            },
            Case(name: "verification cache is bound to both connection roots") { f in
                try f.write(f.remote, "Work/file.txt", "verified")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                await f.engine.disconnect()
                let cacheURL = f.local.appendingPathComponent(".tethwork-verification-cache.json")
                let original = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! [String: Any]
                let file = f.local.appendingPathComponent("Work/file.txt").path
                try f.fm.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file) }
                for key in ["localPath", "remotePath"] {
                    var json = original
                    json[key] = f.root.appendingPathComponent("another-root").path
                    try JSONSerialization.data(withJSONObject: json).write(to: cacheURL)
                    let engine = SyncEngine(watchesDirectories: false)
                    let log = EventLog()
                    await engine.setEventHandler { log.append($0) }
                    try await engine.connect(connection: f.connection, pinned: ["Work"])
                    await engine.fullSync()
                    try expect(log.snapshot().contains { $0.kind == .error }, "Cache from a different \(key) was trusted")
                    await engine.disconnect()
                }
            },
            Case(name: "replaced file invalidates cached verification even with the same size and mtime") { f in
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                try f.write(f.remote, "Work/file.txt", "AAAA", date: date)
                try f.write(f.local, "Work/file.txt", "AAAA", date: date)
                try await f.connect(pins: ["Work"])
                try await f.sync()
                // Atomic replacement gives the new file a different identity.
                let replacement = f.local.appendingPathComponent("replacement")
                try Data("BBBB".utf8).write(to: replacement)
                try f.fm.setAttributes([.modificationDate: date], ofItemAtPath: replacement.path)
                try f.fm.removeItem(at: f.local.appendingPathComponent("Work/file.txt"))
                try f.fm.moveItem(at: replacement, to: f.local.appendingPathComponent("Work/file.txt"))
                try await f.sync()
                try expect(try f.read(f.remote, "Work/file.txt") == f.read(f.local, "Work/file.txt"),
                           "Cached verification hid a replaced file")
            },
            Case(name: "partial verification is saved even when a later file fails") { f in
                try f.write(f.remote, "Work/a.txt", "verified")
                try f.write(f.local, "Work/a.txt", "verified")
                try f.write(f.remote, "Work/z.txt", "unreadable")
                let blocked = f.remote.appendingPathComponent("Work/z.txt").path
                try f.fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked) }
                try await f.connect(pins: [])
                do {
                    _ = try await f.engine.setPinned(relativePath: "Work", pinned: true)
                    throw TestFailure(description: "Unreadable file unexpectedly succeeded")
                } catch is TestFailure { throw TestFailure(description: "Unreadable file unexpectedly succeeded") }
                catch { }
                // Read the checkpoint before disconnect can flush anything.
                let cache = try Data(contentsOf: f.local.appendingPathComponent(".tethwork-verification-cache.json"))
                let json = try JSONSerialization.jsonObject(with: cache) as! [String: Any]
                let pairs = json["pairs"] as! [String: Any]
                try expect(pairs["Work/a.txt"] != nil && pairs["Work/z.txt"] == nil,
                           "Partial progress was lost or an unread file was marked verified")
                try expect(!f.exists(f.remote, ".tethwork-verification-cache.json"), "Cache was uploaded as user data")
            },
            Case(name: "corrupt verification cache safely falls back to reading contents") { f in
                try f.write(f.remote, "Work/file.txt", "AAAA")
                try f.write(f.local, "Work/file.txt", "BBBB")
                try f.write(f.local, ".tethwork-verification-cache.json", "not JSON")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try expect(try f.read(f.remote, "Work/file.txt") == f.read(f.local, "Work/file.txt"),
                           "Corrupt cache bypassed comparison")
                try expect(!f.exists(f.remote, ".tethwork-verification-cache.json"), "Cache leaked to the server")
            },
            Case(name: "repeated sync does not transfer unchanged files") { f in
                try f.write(f.remote, "Work/file.txt", "unchanged")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try await f.sync()
                try expect(!f.events.snapshot().contains {
                    $0.isTransfer && ($0.phase == .transferring || $0.kind == .file)
                }, "An unchanged file was transferred again")
                try expect(!f.events.snapshot().contains { $0.phase == .checking },
                           "A cache hit unnecessarily published Checking progress")
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
            Case(name: "reloading pins never automatically evicts previously synchronized local files") { f in
                try f.write(f.remote, "Work/Sub/file.txt", "preserve local copy")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                // A missing/reloaded pin preference is not an explicit eviction.
                try await f.connect(pins: [])
                try await f.sync()
                try expect(f.exists(f.local, "Work/Sub/file.txt"),
                           "A settings reload silently deleted a previously synchronized local file")
                try expect(try f.read(f.local, "Work/Sub/file.txt") == "preserve local copy", "Local content changed")
                try expect(f.exists(f.remote, "Work/Sub/file.txt"), "The server copy changed")
            },
            Case(name: "automatic sync never prunes unselected local edits") { f in
                try f.write(f.remote, "Work/file.txt", "server original")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try await f.connect(pins: [])
                try f.write(f.local, "Work/file.txt", "unuploaded local edit")
                try await f.sync()
                try expect(f.exists(f.local, "Work/file.txt"), "Automatic pruning deleted an unuploaded local edit")
                try expect(try f.read(f.local, "Work/file.txt") == "unuploaded local edit", "Local edit was overwritten")
                try expect(try f.read(f.remote, "Work/file.txt") == "server original", "An unselected edit was uploaded")
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
            Case(name: "cloud-managed local roots are rejected before creation or state writes") { f in
                let home = f.root.appendingPathComponent("home")
                let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
                try f.fm.createDirectory(at: cloud, withIntermediateDirectories: true)
                let engine = SyncEngine(watchesDirectories: false, homeDirectory: home)
                let local = cloud.appendingPathComponent("MustNotCreate")
                let connection = SyncConnection(name: "Unsafe cloud", remotePath: f.remote.path, localPath: local.path)
                do {
                    try await engine.connect(connection: connection, pinned: [])
                    throw TestFailure(description: "A cloud-managed local root was accepted")
                } catch SyncError.cloudManagedRoot { }
                try expect(!f.exists(cloud, "MustNotCreate"), "Rejected connection created a cloud directory")
                try expect(!f.exists(cloud, ".tethwork-sync-state.json"), "Rejected connection wrote cloud sync state")
            },
            Case(name: "cloud roots, ancestors and symlink aliases are rejected on either side") { f in
                let home = f.root.appendingPathComponent("home")
                let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
                let provider = home.appendingPathComponent("Library/CloudStorage/Provider")
                try f.fm.createDirectory(at: cloud, withIntermediateDirectories: true)
                try f.fm.createDirectory(at: provider, withIntermediateDirectories: true)
                let alias = f.root.appendingPathComponent("cloud-alias")
                try f.fm.createSymbolicLink(at: alias, withDestinationURL: cloud)
                for unsafe in [cloud, cloud.appendingPathComponent("new/subfolder"), provider,
                               provider.appendingPathComponent("new/subfolder"), home, alias] {
                    for unsafeIsLocal in [true, false] {
                        let connection = SyncConnection(name: "Unsafe", remotePath: unsafeIsLocal ? f.remote.path : unsafe.path,
                                                        localPath: unsafeIsLocal ? unsafe.path : f.local.path)
                        do {
                            try SyncEngine.validateConnectionSafety(connection, homeDirectory: home)
                            throw TestFailure(description: "A cloud path or ancestor escaped the safety guard: \(unsafe.path)")
                        } catch SyncError.cloudManagedRoot { }
                    }
                }
                let sibling = home.appendingPathComponent("Library/CloudStorage-Archive")
                try SyncEngine.validateConnectionSafety(
                    SyncConnection(name: "Ordinary folder", remotePath: f.remote.path, localPath: sibling.path), homeDirectory: home)
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
            Case(name: "network loss after validation cannot recreate the remote root") { f in
                try f.fm.createDirectory(at: f.remote.appendingPathComponent("Work"), withIntermediateDirectories: true)
                try f.write(f.local, "Work/new.txt", "pending upload")
                try await f.connect(pins: ["Work"])
                let remote = f.remote
                let unavailable = f.root.appendingPathComponent("unmounted-during-sync")
                let log = f.events
                let movedOnce = OneShot()
                await f.engine.setEventHandler { event in
                    log.append(event)
                    // Synchronization no longer pre-counts the tree, so the first
                    // preparation event is the earliest point that is still past
                    // root validation and before the upload starts.
                    if event.kind == .progress, event.phase == .preparing, movedOnce.take() {
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
            Case(name: "names containing colons synchronize in both directions") { f in
                try f.write(f.remote, "Work/remote:Lemon.txt", "remote")
                try f.write(f.local, "Work/local:Milk.txt", "local")
                try await f.connect(pins: ["Work"])
                try await f.sync()
                try expect(try f.read(f.local, "Work/remote:Lemon.txt") == "remote",
                           "Colon-named remote file was not downloaded")
                try expect(try f.read(f.remote, "Work/local:Milk.txt") == "local",
                           "Colon-named local file was not uploaded")
            },
            Case(name: "large checks publish bounded UI progress without inventing totals") { f in
                for index in 0..<256 {
                    try f.write(f.remote, "Work/file\(index).txt", "same")
                    try f.write(f.local, "Work/file\(index).txt", "same")
                }
                try await f.connect(pins: ["Work"])
                let start = ContinuousClock.now
                try await f.sync()
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let progress = f.events.snapshot().filter { $0.kind == .progress }
                try expect(progress.count <= Int(seconds * 5) + 8,
                           "Progress flooded the UI: \(progress.count) events in \(seconds)s")
                try expect(progress.allSatisfy { $0.progressTotal == nil }, "Checking invented a total")
                try expect(progress.contains { $0.phase == .checking }, "Checking phase disappeared")
                try expect(progress.contains { $0.phase == .finishing }, "Baseline refresh has no progress")
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
