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

enum FolderStorageState: String, Hashable, Sendable {
    case checking, onlineOnly, partial, local, pending, unavailable
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
    /// Descendants are pinned individually; the folder itself is not necessarily pinned.
    var hasPinnedDescendants: Bool = false
    /// Actual contents, independent of the policy for keeping future files.
    var folderStorageState: FolderStorageState? = nil
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
    var storageGeneration: UInt64 = 0
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

enum SyncPhase: String, Sendable {
    case preparing
    case checking
    case transferring
    case finishing
}

struct InitialUploadProgress: Equatable, Sendable {
    var phase: SyncPhase
    var filesDone: Int
    var filesTotal: Int
    var bytesDone: Int64
    var bytesTotal: Int64?
    var currentPath: String
    var bytesPerSecond: Double?
    var estimatedSecondsRemaining: Double?
    /// Files changed by other apps during the pass. They are left for normal
    /// sync instead of restarting the whole adoption.
    var deferredFiles: Int = 0

    var fraction: Double {
        guard phase != .preparing else { return 0 }
        let value: Double
        if let bytesTotal, bytesTotal > 0 {
            value = Double(bytesDone) / Double(bytesTotal)
        } else if filesTotal > 0 {
            value = Double(filesDone) / Double(filesTotal)
        } else { return 0 }
        return min(filesDone < filesTotal ? 0.99 : 1, max(0, value))
    }
}

/// Estimate the slower of byte and file throughput over the last ~45 seconds.
/// File throughput includes SMB per-file/metadata overhead, unlike link speed.
struct TransferTimeEstimator {
    private struct Sample {
        var time: TimeInterval
        var bytes: Int64
        var files: Int
    }
    private var samples: [Sample] = []

    mutating func estimate(bytesDone: Int64, filesDone: Int, bytesTotal: Int64, filesTotal: Int,
                           elapsed: TimeInterval) -> TimeInterval? {
        samples.append(Sample(time: elapsed, bytes: bytesDone, files: filesDone))
        while samples.count > 1, samples[1].time <= elapsed - 45 { samples.removeFirst() }
        guard let first = samples.first, elapsed - first.time >= 10 else { return nil }
        let duration = elapsed - first.time
        let remainingBytes = max(0, bytesTotal - bytesDone)
        let remainingFiles = max(0, filesTotal - filesDone)
        if remainingBytes == 0, remainingFiles == 0 { return 0 }
        var estimates: [TimeInterval] = []
        if remainingBytes > 0, bytesDone > first.bytes {
            estimates.append(Double(remainingBytes) * duration / Double(bytesDone - first.bytes))
        }
        if remainingFiles > 0, filesDone > first.files {
            estimates.append(Double(remainingFiles) * duration / Double(filesDone - first.files))
        }
        return estimates.max()
    }
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
        /// Last-write-wins replaced a differing copy; not a transport failure.
        case conflict
        case storage
        case error
        case status
        case complete
    }

    var kind: Kind
    var message: String
    /// Prevent queued UI events from an old volume affecting the new selection.
    var connectionID: String? = nil
    var folderStorageState: FolderStorageState? = nil
    var storageGeneration: UInt64 = 0
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
    /// A previously unavailable root has been read successfully again.
    var isRemoteAvailable: Bool = false
    var initialUploadProgress: InitialUploadProgress? = nil
}
