import Foundation
import CoreServices

enum DirectoryWatcherMode {
    /// Poll shallow directory snapshots. Used for SMB shares, where kernel
    /// file events are unreliable and a recursive event stream is unavailable.
    case polling
    /// One recursive FSEvents stream for the whole local root. Never opens a
    /// descriptor per watched directory.
    case recursiveFileEvents
}

/// Lightweight directory observer. Avoids recursive scans of large network volumes.
/// Watches one or more directories via kernel events (when available) plus shallow polling —
/// needed for SMB/AFP where remote FS notifications are unreliable.
final class DirectoryWatcher: @unchecked Sendable {
    private var pollTimer: DispatchSourceTimer?
    private var eventStream: FSEventStreamRef?
    private let mode: DirectoryWatcherMode
    private let queue = DispatchQueue(label: "app.tethwork.watcher", qos: .utility)
    private let onChange: @Sendable (URL) -> Void
    private var watchedURLs: [URL] = []
    private var lastSignatures: [String: String] = [:]
    private var pollInterval: TimeInterval = 1.0
    /// Coalesce bursts of events into a single callback.
    private var pendingNotify: DispatchWorkItem?
    /// All mutable state is confined to `queue`, including lifecycle operations.
    private var isRunning = false
    private var generation: UInt64 = 0

    init(mode: DirectoryWatcherMode = .polling,
         onChange: @escaping @Sendable (URL) -> Void) {
        self.mode = mode
        self.onChange = onChange
    }

    deinit {
        // Pending operations retain self, so no operation can still access this state.
        stopOnQueue()
    }

    func start(watching root: URL, interval: TimeInterval = 1.0) {
        start(watching: [root], interval: interval)
    }

    func start(watching urls: [URL], interval: TimeInterval = 1.0) {
        queue.async {
            self.stopOnQueue()
            self.isRunning = true
            self.pollInterval = max(0.4, interval)
            switch self.mode {
            case .polling:
                self.applyWatchedURLs(urls, restartPoll: true)
            case .recursiveFileEvents:
                self.watchedURLs = Self.dedupe(urls)
                if !self.startFileEvents() {
                    // FSEvents is unavailable (for example on a filesystem that
                    // does not support it). Keep a root-level poll as a fallback
                    // rather than falling back to one descriptor per directory.
                    self.startShallowPoll()
                }
            }
        }
    }

    /// Update the set of watched directories without tearing down the poll timer.
    func setWatchedURLs(_ urls: [URL], completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            defer { completion?() }
            guard self.isRunning else { return }
            switch self.mode {
            case .polling:
                self.applyWatchedURLs(urls, restartPoll: false)
            case .recursiveFileEvents:
                let roots = Self.dedupe(urls)
                guard roots.map(\.path) != self.watchedURLs.map(\.path) else { return }
                self.generation &+= 1
                self.stopFileEventsOnQueue()
                self.watchedURLs = roots
                if !self.startFileEvents() { self.startShallowPoll() }
            }
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.stopOnQueue()
            completion?()
        }
    }

    private func stopOnQueue() {
        isRunning = false
        generation &+= 1
        pendingNotify?.cancel()
        pendingNotify = nil
        stopFileEventsOnQueue()
        pollTimer?.cancel()
        pollTimer = nil
        lastSignatures = [:]
        watchedURLs = []
    }

    // MARK: - Internals

    private func applyWatchedURLs(_ urls: [URL], restartPoll: Bool) {
        let unique = Self.dedupe(urls)
        watchedURLs = unique

        // Drop signatures for paths no longer watched.
        let keys = Set(unique.map(\.path))
        lastSignatures = lastSignatures.filter { keys.contains($0.key) }

        // Seed signatures for new paths so the first poll does not false-trigger.
        for url in unique where lastSignatures[url.path] == nil {
            lastSignatures[url.path] = shallowSignature(of: url)
        }

        if restartPoll || pollTimer == nil {
            startShallowPoll()
        }
    }

    private func startFileEvents() -> Bool {
        guard !watchedURLs.isEmpty else { return false }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let eventPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<count {
                let path = String(cString: eventPaths[index])
                if DirectoryWatcher.isRelevantFileEvent(path: path, flags: flags[index]) {
                    watcher.fileEventsDidFire()
                    break
                }
            }
        }
        let paths = watchedURLs.map(\.path) as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            NSLog("Tethwork could not create a recursive file watcher for %@", watchedURLs.map(\.path).joined(separator: ", "))
            return false
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            NSLog("Tethwork could not start a recursive file watcher for %@", watchedURLs.map(\.path).joined(separator: ", "))
            return false
        }
        eventStream = stream
        return true
    }

    private func stopFileEventsOnQueue() {
        guard let stream = eventStream else { return }
        eventStream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func fileEventsDidFire() {
        guard isRunning, let root = watchedURLs.first else { return }
        notifyChange(root)
    }

    /// State/cache checkpoints are writes too. Feeding them back into the
    /// engine makes each completed reconciliation schedule another full pass.
    static func isRelevantFileEvent(path: String, flags: FSEventStreamEventFlags) -> Bool {
        let recovery = UInt32(kFSEventStreamEventFlagMustScanSubDirs |
                              kFSEventStreamEventFlagUserDropped |
                              kFSEventStreamEventFlagKernelDropped |
                              kFSEventStreamEventFlagRootChanged)
        if flags & recovery != 0 { return true }
        let components = URL(fileURLWithPath: path).pathComponents
        if components.contains(where: {
            $0 == ".tethwork-sync-state.json" || $0.hasPrefix(".tethwork-sync-state.json.sb-") ||
            $0 == ".tethwork-verification-cache.json" || $0.hasPrefix(".tethwork-verification-cache.json.sb-") ||
            $0 == ".tethwork-trash" || $0.hasPrefix(".tethwork-copy-") || $0 == ".DS_Store"
        }) { return false }
        // A directory's mtime changes when a checkpoint is replaced. File-level
        // events already describe actual user additions/removals/edits below it.
        let structural = UInt32(kFSEventStreamEventFlagItemCreated |
                                kFSEventStreamEventFlagItemRemoved |
                                kFSEventStreamEventFlagItemRenamed |
                                kFSEventStreamEventFlagItemInodeMetaMod |
                                kFSEventStreamEventFlagItemChangeOwner |
                                kFSEventStreamEventFlagItemXattrMod)
        if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0,
           flags & structural == 0 { return false }
        return true
    }

    private func startShallowPoll() {
        pollTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            self.pollOnce()
            // A slow NAS sweep must have an idle gap, not an overdue repeating
            // timer immediately starting the next sweep and saturating the share.
            if self.isRunning { self.pollTimer?.schedule(deadline: .now() + self.pollInterval) }
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollOnce() {
        let urls = watchedURLs
        guard !urls.isEmpty else { return }

        var changedURL: URL?
        for url in urls {
            let signature = shallowSignature(of: url)
            let previous = lastSignatures[url.path]
            lastSignatures[url.path] = signature
            if let previous, previous != signature, changedURL == nil {
                changedURL = url
            }
        }

        if let changedURL {
            notifyChange(changedURL)
        }
    }

    private func notifyChange(_ url: URL) {
        guard isRunning else { return }
        pendingNotify?.cancel()
        let currentGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.generation == currentGeneration else { return }
            // Snapshot once per coalesced burst, not once per copied/deleted file.
            // The next poll must not report this same kernel event a second time.
            // Kernel events themselves remain valid for deeper directory changes.
            if self.mode == .polling {
                self.lastSignatures[url.path] = self.shallowSignature(of: url)
            }
            self.onChange(url)
        }
        pendingNotify = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Only inspects the directory itself and its immediate children.
    private func shallowSignature(of root: URL) -> String {
        let fm = FileManager.default
        var parts: [String] = []

        if let attrs = try? fm.attributesOfItem(atPath: root.path) {
            let type = attrs[.type] as? FileAttributeType
            let identifier = (attrs[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
            parts.append("root:\(type?.rawValue ?? "unknown"):\(identifier)")
            if type != .typeDirectory {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                parts.append("file:\(size):\(mtime)")
            }
            // Directory mtime also changes for hidden sync/cache files. Visible
            // child entries below detect additions/deletions without that noise.
        } else {
            parts.append("missing")
        }

        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys),
                                                    options: [.skipsHiddenFiles])) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            if let values = try? child.resourceValues(forKeys: keys) {
                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                // Resource identifiers are opaque. Data/NSNumber representations
                // are stable; never use an object's memory-address description.
                let identifier: String
                if let data = values.fileResourceIdentifier as? Data { identifier = data.base64EncodedString() }
                else if let number = values.fileResourceIdentifier as? NSNumber { identifier = number.stringValue }
                else { identifier = "" }
                parts.append("\(name):\(identifier):\(size):\(mtime)")
            } else {
                parts.append(name)
            }
        }
        return parts.joined(separator: "|")
    }

    private static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted {
                result.append(URL(fileURLWithPath: path))
            }
        }
        return result
    }
}
