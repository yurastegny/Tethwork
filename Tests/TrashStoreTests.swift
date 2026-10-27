import Foundation

private struct TrashTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TrashTestFailure(description: message) }
}

private final class Fixture {
    let root: URL
    let remote: URL
    let fm = FileManager.default

    init(base: URL) throws {
        root = base.appendingPathComponent("trash-test-\(UUID().uuidString)")
        remote = root.appendingPathComponent("remote")
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
    }

    func trash(_ path: String, date: Date = Date()) throws -> TrashItem {
        let source = remote.appendingPathComponent(path)
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(path.utf8).write(to: source)
        return try TrashStore.moveToTrash(relativePath: path, remoteRoot: remote.path, wasPinned: true, now: date)
    }

    func directory(_ item: TrashItem) -> String {
        TrashStore.payloadDirectory(remoteRoot: remote.path, id: item.id)
    }

    func close() { try? fm.removeItem(at: root) }
}

@main
struct TrashStoreTests {
    private struct Case {
        let name: String
        let run: (Fixture) throws -> Void
    }

    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let cases: [Case] = [
            Case(name: "emptying preserves the trash container when its parent forbids removing it") { f in
                _ = try f.trash("Nested/a.txt")
                _ = try f.trash("Nested/b.txt")
                let root = TrashStore.trashRoot(remoteRoot: f.remote.path)
                let before = try f.fm.attributesOfItem(atPath: root)
                try f.fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.remote.path)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.remote.path) }
                try TrashStore.empty(remoteRoot: f.remote.path)
                let after = try f.fm.attributesOfItem(atPath: root)
                try expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
                           "Empty Trash removed or recreated its service directory")
                try expect(TrashStore.loadItems(remoteRoot: f.remote.path).isEmpty, "Trash contents remain")
                try expect(Set(try f.fm.contentsOfDirectory(atPath: root)) == ["index.json"], "Unexpected trash payloads remain")
                let permissions = try f.fm.attributesOfItem(atPath: f.remote.path)[.posixPermissions] as? NSNumber
                try expect(permissions?.intValue == 0o500, "Empty Trash modified access permissions")
            },
            Case(name: "emptying continues past a blocked payload and preserves its restore metadata") { f in
                let blocked = try f.trash("Nested/blocked.txt")
                let allowed = try f.trash("Nested/allowed.txt")
                let directory = f.directory(blocked)
                try f.fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }
                var failure: Error?
                do { try TrashStore.empty(remoteRoot: f.remote.path) } catch { failure = error }
                try expect(failure != nil, "Blocked deletion reported success")
                try expect(!f.fm.fileExists(atPath: f.directory(allowed)), "Empty Trash stopped before deleting an accessible payload")
                let remaining = TrashStore.loadItems(remoteRoot: f.remote.path)
                try expect(remaining.count == 1 && remaining[0].id == blocked.id && remaining[0].originalPath == blocked.originalPath,
                           "Empty Trash discarded a blocked item's original path")
            },
            Case(name: "emptying removes unindexed and hidden payloads but not symlink targets") { f in
                _ = try f.trash("selected.txt")
                let root = URL(fileURLWithPath: TrashStore.trashRoot(remoteRoot: f.remote.path))
                let outside = f.root.appendingPathComponent("outside.txt")
                try Data("retain".utf8).write(to: outside)
                try Data("orphan".utf8).write(to: root.appendingPathComponent(".orphan"))
                try f.fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
                try TrashStore.empty(remoteRoot: f.remote.path)
                try expect(Set(try f.fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map(\.lastPathComponent)) == ["index.json"],
                           "Empty Trash left hidden or unindexed payloads")
                try expect(try String(contentsOf: outside, encoding: .utf8) == "retain", "Empty Trash followed a symlink outside the container")
            },
            Case(name: "the underlying OS error is visible before the generic trash summary") { _ in
                let underlying = NSError(domain: NSPOSIXErrorDomain, code: 13,
                                         userInfo: [NSFilePathErrorKey: "/example/blocked/file.txt"])
                let outer = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                                    userInfo: [NSUnderlyingErrorKey: underlying])
                let diagnostic = TrashStore.fileErrorDiagnostic(outer)
                try expect(diagnostic.cause.hasPrefix("NSPOSIXErrorDomain (13)"), "Useful permission error was hidden")
                try expect(diagnostic.details.contains("/example/blocked/file.txt"), "Actual failing path was lost")
                let failure = TrashStore.DeletionError(deletedIDs: [], failedIDs: ["id"], details: [diagnostic.details],
                                                       cause: diagnostic.cause)
                try expect(failure.localizedDescription.hasPrefix("NSPOSIXErrorDomain (13)"), "UI still begins with a generic summary")
            },
            Case(name: "permanent deletion removes the selected payload and index entry") { f in
                let item = try f.trash("Nested/Boekenkast in Roze met Deuren_thumbnail.png")
                try TrashStore.deletePermanently(ids: [item.id], remoteRoot: f.remote.path)
                try expect(!f.fm.fileExists(atPath: f.directory(item)), "Payload remains on disk")
                try expect(TrashStore.loadItems(remoteRoot: f.remote.path).isEmpty, "Deleted item reappeared")
            },
            Case(name: "partial deletion reports permissions and preserves failed item metadata") { f in
                let blocked = try f.trash("Nested/blocked.txt")
                let allowed = try f.trash("Nested/allowed.txt")
                let directory = f.directory(blocked)
                try f.fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }
                var failure: Error?
                do {
                    try TrashStore.deletePermanently(ids: [blocked.id, allowed.id], remoteRoot: f.remote.path)
                } catch { failure = error }
                try expect(failure != nil, "Deletion error was silently ignored")
                try expect(failure!.localizedDescription.contains("blocked.txt"), "Error did not identify the failed file")
                try expect(!f.fm.fileExists(atPath: f.directory(allowed)), "A deletable item was not removed")
                let remaining = TrashStore.loadItems(remoteRoot: f.remote.path)
                try expect(remaining.count == 1 && remaining[0].id == blocked.id, "Failed item disappeared or a deleted item reappeared")
                try expect(remaining[0].originalPath == blocked.originalPath && remaining[0].wasPinned,
                           "Failed deletion discarded restore metadata")
                try f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
                try TrashStore.deletePermanently(ids: [blocked.id], remoteRoot: f.remote.path)
                try expect(TrashStore.loadItems(remoteRoot: f.remote.path).isEmpty, "Retry did not remove the unlocked item")
            },
            Case(name: "an unreadable payload remains visible with its original restore metadata") { f in
                let item = try f.trash("Nested/unreadable.txt")
                let directory = f.directory(item)
                try f.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }
                let items = TrashStore.loadItems(remoteRoot: f.remote.path)
                try expect(items.count == 1 && items[0].id == item.id, "Unreadable item was mistaken for a missing payload")
                try expect(items[0].originalPath == item.originalPath && items[0].wasPinned,
                           "Unreadable item lost its restore metadata")
            },
            Case(name: "retention counts only successfully deleted expired items") { f in
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                let blocked = try f.trash("Nested/expired-blocked.txt", date: date)
                let allowed = try f.trash("Nested/expired-allowed.txt", date: date)
                let directory = f.directory(blocked)
                try f.fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
                defer { try? f.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }
                let now = date.addingTimeInterval(TrashStore.retentionInterval + 100)
                let deleted = TrashStore.purgeExpired(remoteRoot: f.remote.path, now: now)
                try expect(deleted == 1, "Retention counted an unsuccessful removal as deleted")
                let remaining = TrashStore.loadItems(remoteRoot: f.remote.path, now: now)
                try expect(remaining.count == 1 && remaining[0].id == blocked.id, "Retention forgot the undeleted item")
                try expect(remaining[0].originalPath == blocked.originalPath && remaining[0].deletedAt == date,
                           "Retention reset a failed item's path or deletion date")
                try expect(!f.fm.fileExists(atPath: f.directory(allowed)), "Expired accessible payload was not removed")
            },
            Case(name: "an already removed payload is handled idempotently") { f in
                let item = try f.trash("gone.txt")
                try f.fm.removeItem(atPath: f.directory(item))
                try TrashStore.deletePermanently(ids: [item.id], remoteRoot: f.remote.path)
                try expect(TrashStore.loadItems(remoteRoot: f.remote.path).isEmpty, "Stale missing entry remained")
            },
            Case(name: "an orphaned payload can still be deleted without its index") { f in
                let item = try f.trash("orphan.txt")
                try f.fm.removeItem(atPath: (TrashStore.trashRoot(remoteRoot: f.remote.path) as NSString).appendingPathComponent("index.json"))
                try TrashStore.deletePermanently(ids: [item.id], remoteRoot: f.remote.path)
                try expect(!f.fm.fileExists(atPath: f.directory(item)), "Orphaned payload was not removed")
            },
            Case(name: "an index write failure is reported even after the payload was removed") { f in
                let item = try f.trash("selected.txt")
                let other = try f.trash("Nested/keep.txt")
                let index = (TrashStore.trashRoot(remoteRoot: f.remote.path) as NSString).appendingPathComponent("index.json")
                try f.fm.setAttributes([.immutable: true], ofItemAtPath: index)
                defer { try? f.fm.setAttributes([.immutable: false], ofItemAtPath: index) }
                var failure: Error?
                do {
                    try TrashStore.deletePermanently(ids: [item.id], remoteRoot: f.remote.path)
                } catch { failure = error }
                try expect(failure != nil, "Index update failure was ignored")
                try expect(!f.fm.fileExists(atPath: f.directory(item)), "Selected payload was not removed")
                let remaining = TrashStore.loadItems(remoteRoot: f.remote.path)
                try expect(remaining.count == 1 && remaining[0].id == other.id && remaining[0].originalPath == other.originalPath,
                           "Index failure damaged another item's metadata")
            },
            Case(name: "deleting a payload unlinks symbolic links without following their targets") { f in
                let item = try f.trash("selected.txt")
                let outside = f.root.appendingPathComponent("outside")
                try f.fm.createDirectory(at: outside, withIntermediateDirectories: true)
                let retained = outside.appendingPathComponent("keep.txt")
                try Data("retain".utf8).write(to: retained)
                try f.fm.createSymbolicLink(at: URL(fileURLWithPath: f.directory(item)).appendingPathComponent("link"),
                                            withDestinationURL: outside)
                try TrashStore.deletePermanently(ids: [item.id], remoteRoot: f.remote.path)
                try expect(try String(contentsOf: retained, encoding: .utf8) == "retain", "Removal followed a symbolic link outside Trash")
            },
            Case(name: "invalid trash IDs cannot escape the trash directory") { f in
                let item = try f.trash("selected.txt")
                let outside = f.remote.appendingPathComponent("outside.txt")
                try Data("keep".utf8).write(to: outside)
                var failure: Error?
                do {
                    try TrashStore.deletePermanently(ids: [item.id, "../outside.txt"], remoteRoot: f.remote.path)
                } catch { failure = error }
                try expect(failure != nil, "Invalid ID was accepted")
                try expect(f.fm.fileExists(atPath: outside.path), "Deletion escaped the trash")
                try expect(f.fm.fileExists(atPath: f.directory(item)), "Validation happened after deletion started")
            },
            Case(name: "emptying an unavailable server does not report success") { f in
                _ = try f.trash("file.txt")
                try f.fm.moveItem(at: f.remote, to: f.root.appendingPathComponent("unmounted"))
                var failure: Error?
                do { try TrashStore.empty(remoteRoot: f.remote.path) } catch { failure = error }
                try expect(failure != nil, "Missing server was mistaken for an empty trash")
                try expect(!f.fm.fileExists(atPath: f.remote.path), "Operation recreated the missing server root")
            }
        ]
        var failures = 0
        for test in cases {
            let fixture = try Fixture(base: base)
            do {
                try test.run(fixture)
                print("PASS: \(test.name)")
            } catch {
                failures += 1
                print("FAIL: \(test.name): \(error)")
            }
            fixture.close()
        }
        print("Trash store: \(cases.count - failures)/\(cases.count) passed")
        if failures > 0 { exit(1) }
    }
}
