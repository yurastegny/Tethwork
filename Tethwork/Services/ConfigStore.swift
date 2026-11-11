import Foundation

/// Persists connections, favorites and selective-sync pins independently.
final class ConfigStore {
    static let shared = ConfigStore()

    private let connectionsKey = "connections"
    private let activeIdKey = "activeConnectionId"
    private let pinnedKey = "pinnedByConnection"
    private let favoritesKey = "favoriteFolders"
    private let pendingMergesKey = "pendingInitialMergeIDs"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let pinsFileURL: URL?
    private var cachedPins: [String: [String]]?

    init(defaults: UserDefaults = .standard, pinsFileURL: URL? = nil) {
        self.defaults = defaults
        self.pinsFileURL = pinsFileURL ?? (defaults === UserDefaults.standard
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Tethwork/pinned-paths.json") : nil)
        // Migrate before any other preferences are written: the old domain can
        // exceed CFPreferences' 4 MB limit with individually adopted files.
        if self.pinsFileURL != nil { _ = pinnedByConnection }
    }

    var pendingInitialMergeIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: pendingMergesKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: pendingMergesKey) }
    }

    var favoriteFolders: [FavoriteFolder] {
        get {
            guard let data = defaults.data(forKey: favoritesKey),
                  let value = try? decoder.decode([FavoriteFolder].self, from: data)
            else { return [] }
            return value
        }
        set {
            if let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: favoritesKey)
            }
        }
    }

    var connections: [SyncConnection] {
        get {
            guard let data = defaults.data(forKey: connectionsKey),
                  let value = try? decoder.decode([SyncConnection].self, from: data)
            else { return [] }
            return value
        }
        set {
            if let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: connectionsKey)
            } else {
                defaults.removeObject(forKey: connectionsKey)
            }
        }
    }

    var activeConnectionId: String? {
        get { defaults.string(forKey: activeIdKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: activeIdKey)
            } else {
                defaults.removeObject(forKey: activeIdKey)
            }
        }
    }

    var pinnedByConnection: [String: [String]] {
        get {
            if let cachedPins { return cachedPins }
            if let pinsFileURL, let data = try? Data(contentsOf: pinsFileURL),
               let value = try? decoder.decode([String: [String]].self, from: data) {
                cachedPins = value
                defaults.removeObject(forKey: pinnedKey)
                return value
            }
            guard let data = defaults.data(forKey: pinnedKey),
                  let value = try? decoder.decode([String: [String]].self, from: data)
            else { return [:] }
            if let pinsFileURL {
                // Never discard the legacy copy if writing the replacement fails.
                if persistPins(data, to: pinsFileURL) { defaults.removeObject(forKey: pinnedKey) }
                cachedPins = value
            }
            return value
        }
        set {
            if let data = try? encoder.encode(newValue) {
                if let pinsFileURL {
                    guard persistPins(data, to: pinsFileURL) else { return }
                    cachedPins = newValue
                    defaults.removeObject(forKey: pinnedKey)
                } else {
                    defaults.set(data, forKey: pinnedKey)
                }
            } else {
                NSLog("Tethwork could not encode pinned paths; retaining the previous selection")
            }
        }
    }

    private func persistPins(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Tethwork could not save pinned paths: %@", error.localizedDescription)
            return false
        }
    }

    func pinnedPaths(for connectionId: String) -> [String] {
        pinnedByConnection[connectionId] ?? []
    }

    func setPinnedPaths(_ paths: [String], for connectionId: String) {
        var map = pinnedByConnection
        map[connectionId] = paths
        pinnedByConnection = map
    }

    func upsert(_ connection: SyncConnection) {
        var list = connections
        if let index = list.firstIndex(where: { $0.id == connection.id }) {
            list[index] = connection
        } else {
            list.append(connection)
        }
        connections = list
        activeConnectionId = connection.id
    }

    func update(_ connection: SyncConnection) {
        connections = connections.map { $0.id == connection.id ? connection : $0 }
    }

    @discardableResult
    func deleteConnection(id: String) -> [SyncConnection] {
        let remaining = connections.filter { $0.id != id }
        connections = remaining
        var map = pinnedByConnection
        map.removeValue(forKey: id)
        pinnedByConnection = map
        favoriteFolders = favoriteFolders.filter { $0.connectionID != id }
        pendingInitialMergeIDs.remove(id)
        if activeConnectionId == id {
            activeConnectionId = nil
        }
        return remaining
    }

    private let viewModeKey = "browserViewMode"
    var showsHiddenFiles: Bool {
        get { defaults.bool(forKey: "showsHiddenFiles") }
        set { defaults.set(newValue, forKey: "showsHiddenFiles") }
    }

    /// list | icons | columns
    var viewMode: String {
        get { defaults.string(forKey: viewModeKey) ?? "list" }
        set { defaults.set(newValue, forKey: viewModeKey) }
    }
}
