import Foundation

private struct TestFailure: Error { let message: String }
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message: message) }
}

/// Standalone persistence regression test using an isolated preferences suite.
@main
struct FavoritesTests {
    static func main() throws {
        let suite = "app.tethwork.favorites-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigStore(defaults: defaults)
        let first = SyncConnection(id: "first", name: "First", remotePath: "/remote-a", localPath: "/local-a")
        let second = SyncConnection(id: "second", name: "Second", remotePath: "/remote-b", localPath: "/local-b")
        store.upsert(first)
        store.upsert(second)
        store.setPinnedPaths(["Local"], for: first.id)
        try expect(store.favoriteFolders.isEmpty, "Local storage must not automatically create favorites")

        let a = FavoriteFolder(connectionID: first.id, relativePath: "Online")
        let b = FavoriteFolder(connectionID: second.id, relativePath: "Online")
        store.favoriteFolders = [a, b]
        try expect(store.pinnedPaths(for: first.id) == ["Local"], "Favorites must not change sync pins")
        let reloaded = ConfigStore(defaults: defaults)
        try expect(reloaded.favoriteFolders == [a, b], "Persist order and stable IDs across reloads")
        store.pendingInitialMergeIDs = [first.id, second.id]
        try expect(reloaded.pendingInitialMergeIDs == [first.id, second.id],
                     "Background uploads must remain resumable after reopening the app")

        store.setPinnedPaths([], for: first.id)
        try expect(store.favoriteFolders == [a, b], "Unpinning must preserve favorites")
        store.setPinnedPaths(["Local"], for: first.id)
        store.favoriteFolders = [b]
        try expect(store.pinnedPaths(for: first.id) == ["Local"], "Removing a favorite must not evict local files")

        store.favoriteFolders = [a, b]
        store.upsert(first)
        try expect(store.connections.map(\.id) == [first.id, second.id], "Selection must not reorder servers")
        store.deleteConnection(id: first.id)
        try expect(store.favoriteFolders == [b], "Removing a server must keep other servers' favorites")
        try expect(store.pendingInitialMergeIDs == [second.id], "Removing a server must clear only its pending upload")
        print("PASS: favorites persist independently of pins, retain order and respect server identity")
    }
}
