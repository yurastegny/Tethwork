import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}

private final class Fixture {
    let fm = FileManager.default
    let root: URL
    let local: URL
    let remote: URL
    let metadata: URL
    let connection: SyncConnection
    let inventory: LocalFileInventory
    init(_ base: URL) throws {
        root = base.appendingPathComponent("inventory-test-\(UUID().uuidString)")
        local = root.appendingPathComponent("local")
        remote = root.appendingPathComponent("remote")
        metadata = root.appendingPathComponent("inventory")
        connection = SyncConnection(id: "stable-id", name: "Test", remotePath: remote.path, localPath: local.path)
        inventory = LocalFileInventory(directory: metadata, connection: connection)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
    }
    func seed(_ path: String = "Work/file.txt") throws {
        let url = local.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: url)
        try inventory.beginSession(selectedPaths: ["Work"])
        inventory.confirm(path: path, size: 4, modified: Date(timeIntervalSince1970: 1_700_000_000), fileID: 1)
        try inventory.checkpoint(force: true, successfulOperation: "Fixture verified")
    }
    func snapshot() throws -> LocalFileInventory.Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalFileInventory.Snapshot.self, from: Data(contentsOf: inventory.manifestURL))
    }
    func events() throws -> [LocalFileInventory.Event] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: inventory.journalURL, encoding: .utf8).split(separator: "\n").map {
            try decoder.decode(LocalFileInventory.Event.self, from: Data($0.utf8))
        }
    }
}

@main struct LocalFileInventoryTests {
    static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let cases: [(String, (Fixture) async throws -> Void)] = [
            ("registry survives a new instance and preference changes do not erase expected files", { f in
                try f.seed()
                let reopened = LocalFileInventory(directory: f.metadata, connection: f.connection)
                try reopened.beginSession(selectedPaths: [])
                let state = try f.snapshot()
                try expect(state.expected["Work/file.txt"]?.size == 4, "Reopening lost expected file metadata")
                try expect(state.selectedPaths.isEmpty, "New selections were not recorded")
                try expect(state.lastSuccessfulOperation != nil, "Last successful confirmation was lost")
            }),
            ("missing-file audits never restore, delete or forget user files", { f in
                try f.seed()
                try f.fm.removeItem(at: f.local.appendingPathComponent("Work/file.txt"))
                try f.inventory.auditBeforeSync()
                let audit = try f.events().last!
                try expect(audit.missing == ["Work/file.txt"], "Missing file was not recorded")
                try expect(try f.snapshot().expected["Work/file.txt"] != nil, "A missing file erased its expectation")
                try expect(!f.fm.fileExists(atPath: f.local.appendingPathComponent("Work/file.txt").path), "Audit restored a file")
                try expect(try f.fm.contentsOfDirectory(atPath: f.remote.path).isEmpty, "Audit changed the server")
            }),
            ("an unavailable root is distinct from all files going missing", { f in
                try f.seed()
                try f.fm.moveItem(at: f.local, to: f.root.appendingPathComponent("offline"))
                try f.inventory.auditBeforeSync()
                let audit = try f.events().last!
                try expect(audit.rootAvailable == false && audit.missing?.isEmpty == true, "Unavailable root was reported as mass deletion")
                try expect(!f.fm.fileExists(atPath: f.local.path), "Audit recreated the missing root")
            }),
            ("cloud placeholders are distinguished from missing documents", { f in
                try f.seed()
                try f.fm.moveItem(at: f.local.appendingPathComponent("Work/file.txt"),
                                  to: f.local.appendingPathComponent("Work/.file.txt.icloud"))
                try f.inventory.auditBeforeSync()
                let audit = try f.events().last!
                try expect(audit.cloudOnly == ["Work/file.txt"] && audit.missing?.isEmpty == true, "Placeholder looked like a deleted document")
            }),
            ("explicit retirement records metadata and does not touch actual files", { f in
                try f.seed()
                try f.inventory.retire(scope: "Work", reason: "Explicit eviction")
                try expect(try f.snapshot().expected.isEmpty, "Completed explicit eviction did not retire the expectation")
                try expect(try f.events().contains { $0.retired?["Work/file.txt"]?.size == 4 }, "Retirement erased historical evidence")
                try expect(f.fm.fileExists(atPath: f.local.appendingPathComponent("Work/file.txt").path), "The recorder itself deleted a user file")
            }),
            ("a retained ancestor selection keeps its expected descendants", { f in
                try f.seed()
                try f.inventory.retire(scope: "Work/file.txt", reason: "Nested unpin", remainingSelections: ["Work"])
                try expect(try f.snapshot().expected["Work/file.txt"] != nil, "Ancestor selection was ignored")
            }),
            ("rename records update only registry paths", { f in
                try f.seed()
                try f.inventory.remap(from: "Work", to: "Renamed")
                let state = try f.snapshot()
                try expect(state.expected["Renamed/file.txt"] != nil && state.expected["Work/file.txt"] == nil, "Registry rename failed")
                try expect(f.fm.fileExists(atPath: f.local.appendingPathComponent("Work/file.txt").path), "Recorder renamed actual data")
            }),
            ("corrupt snapshots are preserved instead of overwritten with an empty list", { f in
                try f.seed()
                let corrupt = Data("not valid JSON".utf8)
                try corrupt.write(to: f.inventory.manifestURL)
                let reopened = LocalFileInventory(directory: f.metadata, connection: f.connection)
                var rejected = false
                do { try reopened.beginSession(selectedPaths: []) } catch { rejected = true }
                try expect(rejected, "Corrupt snapshot was silently accepted")
                try expect(try Data(contentsOf: f.inventory.manifestURL) == corrupt, "Corrupt evidence was overwritten")
            }),
            ("connection identities and roots get separate registries", { f in
                let differentID = SyncConnection(id: "different", name: "Other", remotePath: f.remote.path, localPath: f.local.path)
                let differentRoot = SyncConnection(id: "stable-id", name: "Other root", remotePath: f.root.appendingPathComponent("other-remote").path, localPath: f.local.path)
                try expect(LocalFileInventory(directory: f.metadata, connection: differentID).manifestURL != f.inventory.manifestURL, "Connection IDs mixed")
                try expect(LocalFileInventory(directory: f.metadata, connection: differentRoot).manifestURL != f.inventory.manifestURL, "Different roots mixed")
            }),
            ("legacy baselines seed expectations without creating missing documents", { f in
                let data = try JSONSerialization.data(withJSONObject: ["remotePath": f.remote.resolvingSymlinksInPath().path,
                    "syncedPaths": ["Missing/file.txt", "../escape", ".tethwork-sync-state.json"]])
                try data.write(to: f.local.appendingPathComponent(".tethwork-sync-state.json"))
                try f.inventory.beginSession(selectedPaths: [])
                let state = try f.snapshot()
                try expect(Set(state.expected.keys) == ["Missing/file.txt"], "Legacy import lost a safe path or trusted an unsafe one")
                try expect(!f.fm.fileExists(atPath: f.local.appendingPathComponent("Missing").path), "Import created missing files")
            }),
            ("metadata cannot be written into the sync roots", { f in
                let inside = f.local.appendingPathComponent("MustNotCreate")
                let unsafe = LocalFileInventory(directory: inside, connection: f.connection)
                var rejected = false
                do { try unsafe.beginSession(selectedPaths: []) } catch { rejected = true }
                try expect(rejected && !f.fm.fileExists(atPath: inside.path), "Inventory files escaped into a sync root")
            }),
            ("a symlink escape is reported without examining external files", { f in
                try f.seed()
                let external = f.root.appendingPathComponent("outside")
                try f.fm.createDirectory(at: external, withIntermediateDirectories: true)
                try f.fm.removeItem(at: f.local.appendingPathComponent("Work"))
                try f.fm.createSymbolicLink(at: f.local.appendingPathComponent("Work"), withDestinationURL: external)
                try f.inventory.auditBeforeSync()
                let audit = try f.events().last!
                try expect(audit.inaccessible?["Work/file.txt"] != nil && audit.missing?.isEmpty == true,
                           "An escaping path was treated as a normal missing file")
                try expect(try f.fm.contentsOfDirectory(atPath: external.path).isEmpty, "External directory was changed")
            }),
            ("legacy verification metadata imports only matching root pairs", { f in
                let url = f.local.appendingPathComponent(".tethwork-verification-cache.json")
                var cache: [String: Any] = ["version": 1,
                    "localPath": f.local.resolvingSymlinksInPath().path,
                    "remotePath": f.remote.resolvingSymlinksInPath().path,
                    "pairs": ["Work/file.txt": ["localSize": 42, "localModified": 700_000_000.0, "localFileID": 123]]]
                try JSONSerialization.data(withJSONObject: cache).write(to: url)
                try f.inventory.beginSession(selectedPaths: [])
                let entry = try f.snapshot().expected["Work/file.txt"]
                try expect(entry?.size == 42 && entry?.fileID == 123 && entry?.lastConfirmed == nil,
                           "Imported metadata was lost or falsely marked freshly confirmed")
                cache["remotePath"] = f.root.appendingPathComponent("unrelated").path
                try JSONSerialization.data(withJSONObject: cache).write(to: url)
                let separate = LocalFileInventory(directory: f.root.appendingPathComponent("other-inventory"), connection: f.connection)
                try separate.beginSession(selectedPaths: [])
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let state = try decoder.decode(LocalFileInventory.Snapshot.self, from: Data(contentsOf: separate.manifestURL))
                try expect(state.expected.isEmpty, "An unrelated legacy cache polluted the inventory")
            }),
            ("a completed checkpoint retains the preceding complete snapshot", { f in
                try f.seed()
                let previous = try Data(contentsOf: f.inventory.manifestURL)
                f.inventory.addExpected(paths: ["Work/new.txt"])
                try f.inventory.checkpoint(force: true)
                let backup = f.inventory.manifestURL.deletingPathExtension().appendingPathExtension("previous.json")
                try expect(try Data(contentsOf: backup) == previous, "Previous checkpoint was not preserved")
                try expect(try f.snapshot().expected["Work/new.txt"] != nil, "New checkpoint lost an expectation")
            }),
            ("engine records absence before reconciliation changes the server", { f in
                let file = f.remote.appendingPathComponent("Work/file.txt")
                try f.fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("network data".utf8).write(to: file)
                let engine = SyncEngine(watchesDirectories: false, inventoryDirectory: f.metadata)
                try await engine.connect(connection: f.connection, pinned: ["Work"])
                await engine.fullSync()
                try f.fm.removeItem(at: f.local.appendingPathComponent("Work/file.txt"))
                await engine.fullSync()
                await engine.disconnect()
                let events = try f.events()
                let audit = events.firstIndex { $0.kind == "pre_sync_audit" && $0.missing?.contains("Work/file.txt") == true }
                let trash = events.firstIndex { $0.kind == "engine_trash" }
                try expect(audit != nil && trash != nil && audit! < trash!, "Evidence did not distinguish an already missing local file from subsequent app activity")
            }),
            ("explicit engine eviction retires expectations and checkpoints its selection", { f in
                let file = f.remote.appendingPathComponent("Work/file.txt")
                try f.fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("network data".utf8).write(to: file)
                let engine = SyncEngine(watchesDirectories: false, inventoryDirectory: f.metadata)
                try await engine.connect(connection: f.connection, pinned: ["Work"])
                await engine.fullSync()
                _ = try await engine.setPinned(relativePath: "Work", pinned: false)
                let state = try f.snapshot()
                try expect(state.expected.isEmpty && state.selectedPaths.isEmpty, "Eviction left stale expectations or selection")
                try expect(try f.events().contains { $0.kind == "expected_paths_retired" && $0.retired?["Work/file.txt"] != nil },
                           "Explicit removal lost historical metadata")
                await engine.disconnect()
                try expect(try f.snapshot().expected.isEmpty, "Disconnect reintroduced retired paths")
                try expect(f.fm.fileExists(atPath: file.path), "Eviction changed the server file")
            }),
        ]
        var failures = 0
        for (name, test) in cases {
            let fixture = try Fixture(base)
            do { try await test(fixture); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
            try? fixture.fm.removeItem(at: fixture.root)
        }
        print("Local inventory: \(cases.count - failures)/\(cases.count) passed")
        if failures > 0 { exit(1) }
    }
}
