import Foundation

enum SyncMode: String, Codable, Hashable {
    case offline
    case onlineOnly = "online-only"
}

enum SyncStatus: String, Codable, Hashable {
    case synced
    case pending
    case syncing
    case error
    case onlineOnly = "online-only"
}

struct SyncConnection: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var remotePath: String
    var localPath: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        remotePath: String,
        localPath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.remotePath = remotePath
        self.localPath = localPath
        self.createdAt = createdAt
    }
}

struct FavoriteFolder: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var connectionID: String
    var relativePath: String
}

struct FileEntry: Identifiable, Hashable {
    var id: String { relativePath }
    var name: String
    var absolutePath: String
    var relativePath: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date
    var syncMode: SyncMode
    var isLocallyAvailable: Bool
    var syncStatus: SyncStatus
}

/// Flattened list-view row (folder outline with indentation).
struct OutlineRow: Identifiable, Hashable {
    var id: String { entry.relativePath }
    var entry: FileEntry
    var depth: Int
}

struct Breadcrumb: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
}

struct DirectoryListing {
    var relativePath: String
    var entries: [FileEntry]
    var breadcrumbs: [Breadcrumb]
}

/// Where a trash item came from.
enum TrashOrigin: String, Codable, Hashable {
    /// Deleted in Tethwork's browser.
    case app
    /// The local synced copy disappeared (deleted in Finder) and the deletion
    /// was propagated to the network volume.
    case local
}

/// A file or folder kept in the server-side trash on the network volume.
struct TrashItem: Identifiable, Codable, Hashable {
    /// UUID naming the payload folder inside `.tethwork-trash`.
    var id: String
    var name: String
    /// Path relative to the network volume root before deletion.
    var originalPath: String
    var isDirectory: Bool
    var size: Int64
    var deletedAt: Date
    /// Restore local availability after restoring, when the path was pinned.
    var wasPinned: Bool
    /// Optional for compatibility with trash entries written before this field existed.
    var origin: TrashOrigin? = nil

    /// True when the item was deleted from the local sync folder on this Mac.
    var wasDeletedLocally: Bool { origin == .local }

    var originalFolder: String {
        let parent = (originalPath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    var expiresAt: Date {
        deletedAt.addingTimeInterval(TrashStore.retentionInterval)
    }

    /// Whole days left before automatic removal (0 once expired).
    func daysRemaining(from now: Date = Date()) -> Int {
        let interval = expiresAt.timeIntervalSince(now)
        guard interval > 0 else { return 0 }
        return max(1, Int(ceil(interval / 86_400)))
    }
}

enum SyncPhase: String {
    case preparing
    case checking
    case transferring
    case finishing
}

struct SyncEvent: Equatable {
    enum TransferDirection: Equatable {
        case upload
        case download
    }

    enum Kind: Equatable {
        case progress
        case file
        /// An item was moved to Trash because its local copy disappeared.
        case trash
        case error
        case status
        case complete
    }

    var kind: Kind
    var message: String
    var path: String?
    var progressDone: Int? = nil
    var progressTotal: Int? = nil
    /// True only when a real copy is fixing a local↔remote mismatch.
    var isTransfer: Bool = false
    var bytesPerSecond: Double? = nil
    var transferDirection: TransferDirection? = nil
    var phase: SyncPhase? = nil
    /// True only when the remote root itself cannot be reached. File-level sync
    /// errors must not make the whole connection look offline.
    var isRemoteUnavailable: Bool = false
}
