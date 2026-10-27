import Foundation

/// Lightweight directory observer. Avoids recursive scans of large network volumes.
/// Watches one or more directories via kernel events (when available) plus shallow polling —
/// needed for SMB/AFP where remote FS notifications are unreliable.
final class DirectoryWatcher: @unchecked Sendable {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pollTimer: DispatchSourceTimer?
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

    init(onChange: @escaping @Sendable (URL) -> Void) {
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
            self.applyWatchedURLs(urls, restartPoll: true, restartDescriptors: true)
        }
    }

    /// Update the set of watched directories without tearing down the poll timer.
    func setWatchedURLs(_ urls: [URL], completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            defer { completion?() }
            guard self.isRunning else { return }
            self.applyWatchedURLs(urls, restartPoll: false, restartDescriptors: true)
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
        for source in sources {
            source.cancel()
        }
        sources = []
        pollTimer?.cancel()
        pollTimer = nil
        lastSignatures = [:]
        watchedURLs = []
    }

    // MARK: - Internals

    private func applyWatchedURLs(_ urls: [URL], restartPoll: Bool, restartDescriptors: Bool) {
        let unique = Self.dedupe(urls)
        watchedURLs = unique

        // Drop signatures for paths no longer watched.
        let keys = Set(unique.map(\.path))
        lastSignatures = lastSignatures.filter { keys.contains($0.key) }

        // Seed signatures for new paths so the first poll does not false-trigger.
        for url in unique where lastSignatures[url.path] == nil {
            lastSignatures[url.path] = shallowSignature(of: url)
        }

        if restartDescriptors {
            restartDescriptorWatches()
        }

        if restartPoll || pollTimer == nil {
            startShallowPoll()
        }
    }

    private func restartDescriptorWatches() {
        generation &+= 1
        let currentGeneration = generation
        for source in sources {
            source.cancel()
        }
        sources = []

        for url in watchedURLs {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                // Reading a file can change access attributes on a NAS. Those
                // events must not make content verification trigger itself.
                // Actual mtime/size changes are also covered by the shallow poll.
                eventMask: [.write, .delete, .rename, .extend, .link],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self, self.isRunning, self.generation == currentGeneration else { return }
                self.notifyChange(url)
            }
            // Dispatch may still be handling the old source after cancel(). Do not
            // close (and potentially reuse) its descriptor until cancellation finishes.
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func startShallowPoll() {
        pollTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.pollOnce()
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
            self.lastSignatures[url.path] = self.shallowSignature(of: url)
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

        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = (root.path as NSString).appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: path) {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let identifier = (attrs[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
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
