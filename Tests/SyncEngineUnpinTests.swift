import Foundation

/// Standalone regression test; compile alongside Models, DirectoryWatcher,
/// TrashStore and SyncEngine (no app settings or real volumes are used).
@main
struct SyncEngineUnpinTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
            .appendingPathComponent("unpin-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let remote = root.appendingPathComponent("remote")
        let local = root.appendingPathComponent("local")
        for base in [remote, local] {
            for name in ["A", "B"] {
                let folder = base.appendingPathComponent(name)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(name.utf8).write(to: folder.appendingPathComponent("file.txt"))
            }
        }
        let stateURL = local.appendingPathComponent(".tethwork-sync-state.json")
        let state: [String: Any] = [
            "remotePath": remote.resolvingSymlinksInPath().path,
            "syncedPaths": ["A", "A/file.txt", "B", "B/file.txt"]
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)

        let engine = SyncEngine(watchesDirectories: false)
        let connection = SyncConnection(name: "Test", remotePath: remote.path, localPath: local.path)
        try await engine.connect(connection: connection, pinned: ["A", "B"])
        let paths = try await engine.setPinned(relativePath: "A", pinned: false)
        precondition(paths == ["B"], "Unrelated pins must remain")
        precondition(!fm.fileExists(atPath: local.appendingPathComponent("A").path))
        precondition(fm.fileExists(atPath: remote.appendingPathComponent("A/file.txt").path))
        precondition(fm.fileExists(atPath: local.appendingPathComponent("B/file.txt").path))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        precondition(Set(saved["syncedPaths"] as! [String]) == ["B", "B/file.txt"],
                     "Eviction must remove only its own deletion baseline")
        await engine.disconnect()

        try await engine.connect(connection: connection, pinned: ["", "B"])
        let rootPaths = try await engine.setPinned(relativePath: "", pinned: false)
        precondition(rootPaths.isEmpty, "Unpinning the volume must clear nested pins")
        precondition(!fm.fileExists(atPath: local.appendingPathComponent("B").path))
        precondition(fm.fileExists(atPath: remote.appendingPathComponent("B/file.txt").path))
        precondition(fm.fileExists(atPath: stateURL.path), "Keep internal sync state")
        await engine.disconnect()
        print("PASS: folder/volume eviction preserves remote files, unrelated pins and sync baseline")
    }
}
