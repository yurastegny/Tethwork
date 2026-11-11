import Foundation

/// One long-lived engine per volume. Browser selection never owns its lifetime.
@MainActor
final class ConnectionSyncCoordinator {
    struct State {
        var isConnected = false
        var isSyncing = false
        var progress: SyncEvent?
        var error: String?
        var uploadBytesPerSecond: Double = 0
        var downloadBytesPerSecond: Double = 0
    }

    private final class Session {
        let connection: SyncConnection
        let engine: SyncEngine
        var connecting: Task<Void, Error>?
        var connectAttempt = UUID()
        var ready = false
        var adopting = false

        init(connection: SyncConnection, engine: SyncEngine) {
            self.connection = connection
            self.engine = engine
        }
    }

    private var sessions: [String: Session] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var jobTokens: [String: UUID] = [:]
    private var adoptionTokens: [String: UUID] = [:]
    private var retiring: [String: Task<Void, Never>] = [:]
    private var configured: [String: SyncConnection] = [:]
    private var suspendedIDs = Set<String>()
    private var paused = false
    private var pauseRevision: UInt64 = 0
    private let makeEngine: () -> SyncEngine
    private let retryDelay: UInt64
    private(set) var states: [String: State] = [:]
    var onEvent: ((SyncEvent) -> Void)?
    var onStatesChanged: (([String: State]) -> Void)?
    var onAdopted: ((String, [String]) -> Void)?

    func isAdopting(_ id: String) -> Bool { adoptionTokens[id] != nil }

    init(makeEngine: @escaping () -> SyncEngine = { SyncEngine() }, retryDelay: UInt64 = 15_000_000_000) {
        self.makeEngine = makeEngine
        self.retryDelay = retryDelay
    }

    /// Reuse an engine even when its reconciliation is in flight.
    func connect(_ connection: SyncConnection, pins: [String], deferInitialMerge: Bool = false,
                 deferWatchers: Bool = false) async throws -> SyncEngine {
        await retiring[connection.id]?.value
        try Task.checkCancellation()
        if let old = sessions[connection.id], !sameRoots(old.connection, connection) {
            await stop(connection.id)?.value
            try Task.checkCancellation()
        }
        let session: Session
        if let existing = sessions[connection.id] {
            session = existing
        } else {
            session = Session(connection: connection, engine: makeEngine())
            sessions[connection.id] = session
        }
        if !session.ready {
            if session.connecting == nil {
                session.connectAttempt = UUID()
                session.connecting = Task { [weak self, weak session] in
                    guard let self, let session else { throw CancellationError() }
                    await session.engine.setEventHandler { [weak self, weak session] event in
                        Task { @MainActor in
                            guard let self, let session, self.sessions[connection.id] === session else { return }
                            self.receive(event, id: connection.id)
                        }
                    }
                    await session.engine.setAutomaticSyncPaused(self.paused)
                    try Task.checkCancellation()
                    try await session.engine.connect(connection: connection, pinned: pins,
                                                     deferInitialMerge: deferInitialMerge, deferWatchers: deferWatchers)
                }
            }
            let attempt = session.connectAttempt
            let connecting = session.connecting!
            do {
                try await connecting.value
                guard sessions[connection.id] === session, session.connectAttempt == attempt else { throw CancellationError() }
                session.ready = true
                session.connecting = nil
                var state = states[connection.id] ?? State()
                state.isConnected = true
                state.error = nil
                states[connection.id] = state
                publish()
            } catch {
                if sessions[connection.id] === session, session.connectAttempt == attempt {
                    session.connecting = nil
                    var state = states[connection.id] ?? State()
                    state.isConnected = false
                    state.isSyncing = false
                    state.error = error is CancellationError ? nil : error.localizedDescription
                    states[connection.id] = state
                    publish()
                }
                throw error
            }
        }
        return session.engine
    }

    /// Initial adoption uses the additive uploader before ordinary sync. A
    /// foreground-owned upload is excluded so two uploaders never race it.
    func synchronize(_ connections: [SyncConnection], pins: [String: [String]],
                     pendingInitialMerges: Set<String> = [], externallyMerging: Set<String> = []) {
        configured = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        let changedRoots = sessions.compactMap { id, session in
            configured[id].map { sameRoots(session.connection, $0) ? nil : id } ?? nil
        }
        for id in Set(sessions.keys).union(jobs.keys).subtracting(configured.keys).union(changedRoots) {
            stop(id)
        }
        guard !paused else { return }
        for connection in connections where !suspendedIDs.contains(connection.id) && !externallyMerging.contains(connection.id) {
            guard jobs[connection.id] == nil else { continue }
            let token = UUID()
            jobTokens[connection.id] = token
            if pendingInitialMerges.contains(connection.id) { adoptionTokens[connection.id] = token }
            jobs[connection.id] = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                defer {
                    if self.jobTokens[connection.id] == token {
                        self.jobs.removeValue(forKey: connection.id)
                        self.jobTokens.removeValue(forKey: connection.id)
                        self.adoptionTokens.removeValue(forKey: connection.id)
                    }
                }
                while !Task.isCancelled, !self.paused, self.jobTokens[connection.id] == token,
                      self.configured[connection.id].map({ self.sameRoots($0, connection) }) == true {
                    do {
                        let adopting = pendingInitialMerges.contains(connection.id)
                        let engine = try await self.connect(connection, pins: pins[connection.id] ?? [], deferInitialMerge: adopting)
                        guard !Task.isCancelled, !self.paused else { return }
                        if adopting {
                            guard let session = self.sessions[connection.id] else { return }
                            session.adopting = true
                            try await engine.prepareInitialMerge(connectionID: connection.id)
                            self.receive(.init(kind: .progress, message: String(localized: "Checking existing local files…"),
                                               connectionID: connection.id, path: nil, progressDone: 0,
                                               isTransfer: true, transferDirection: .upload, phase: .preparing), id: connection.id)
                            do {
                                let paths = try await SyncEngine.mergeExistingLocalFiles(connection: connection, onTransferRate: nil, onSnapshot: { [weak self, weak session] snapshot in
                                    Task { @MainActor in
                                        guard let self, let session, self.sessions[connection.id] === session, session.adopting else { return }
                                        let message = snapshot.phase == .preparing ? String(localized: "Counting files…") :
                                            (snapshot.phase == .checking ? String(localized: "Checking local copies…") :
                                             (snapshot.phase == .finishing ? String(localized: "Final checks…") : String(localized: "Uploading files…")))
                                        self.receive(.init(kind: .progress, message: message, connectionID: connection.id,
                                                           path: snapshot.currentPath, progressDone: snapshot.filesDone, progressTotal: snapshot.filesTotal,
                                                           isTransfer: true, bytesPerSecond: snapshot.bytesPerSecond, transferDirection: .upload,
                                                           phase: snapshot.phase, initialUploadProgress: snapshot), id: connection.id)
                                    }
                                })
                                try Task.checkCancellation()
                                guard self.sessions[connection.id] === session else { throw CancellationError() }
                                let adopted = try await engine.finishInitialMerge(connectionID: connection.id, paths: paths)
                                guard self.sessions[connection.id] === session else { throw CancellationError() }
                                session.adopting = false
                                self.adoptionTokens.removeValue(forKey: connection.id)
                                self.onAdopted?(connection.id, adopted)
                            } catch {
                                session.adopting = false
                                try? await engine.abortInitialMerge(connectionID: connection.id)
                                throw error
                            }
                        }
                        await engine.activateWatchers(connectionID: connection.id)
                        await engine.fullSync()
                        return // Connected engines own their watcher/error backoff loops.
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled, self.jobTokens[connection.id] == token else { return }
                        self.receive(.init(kind: .error, message: error.localizedDescription,
                                           connectionID: connection.id, path: nil), id: connection.id)
                        do { try await Task.sleep(nanoseconds: self.retryDelay) }
                        catch { return }
                    }
                }
            }
        }
    }

    func setPaused(_ value: Bool) async {
        paused = value
        pauseRevision &+= 1
        let revision = pauseRevision
        // Let an in-flight reconciliation/adoption finish. The flag prevents new
        // scheduled passes on every engine, without abandoning their progress.
        // Take a snapshot before yielding to actors.
        let engines = sessions.values.map(\.engine)
        for engine in engines {
            guard pauseRevision == revision else { return }
            await engine.setAutomaticSyncPaused(value)
        }
    }

    func suspend(_ id: String) async {
        suspendedIDs.insert(id)
        await stop(id)?.value
    }

    func resume(_ id: String) { suspendedIDs.remove(id) }

    /// A foreground mutation must wait for the additive uploader to stop, but
    /// keep the volume's engine connected for that mutation.
    func cancelAdoption(_ id: String) async {
        guard isAdopting(id) else { return }
        let session = sessions[id]
        let job = jobs.removeValue(forKey: id)
        jobTokens.removeValue(forKey: id)
        adoptionTokens.removeValue(forKey: id)
        job?.cancel()
        await job?.value
        guard let session, sessions[id] === session else { return }
        session.adopting = false
        try? await session.engine.abortInitialMerge(connectionID: id)
        var state = states[id] ?? State()
        state.isSyncing = false
        state.progress = nil
        states[id] = state
        publish()
    }

    func remove(_ id: String) async {
        configured.removeValue(forKey: id)
        suspendedIDs.remove(id)
        await stop(id)?.value
    }

    func shutdown() async {
        configured.removeAll()
        let ids = Set(sessions.keys).union(jobs.keys)
        for id in ids { await remove(id) }
        for task in retiring.values { await task.value }
        retiring.removeAll()
    }

    @discardableResult
    private func stop(_ id: String) -> Task<Void, Never>? {
        let job = jobs.removeValue(forKey: id)
        job?.cancel()
        jobTokens.removeValue(forKey: id)
        adoptionTokens.removeValue(forKey: id)
        let session = sessions.removeValue(forKey: id)
        session?.connecting?.cancel()
        states.removeValue(forKey: id)
        publish()
        let previous = retiring[id]
        guard session != nil || job != nil else { return previous }
        let waitsForUploader = session?.adopting == true
        let task = Task {
            await previous?.value
            if let session { await session.engine.disconnect() }
            if waitsForUploader { await job?.value }
        }
        retiring[id] = task
        return task
    }

    private func sameRoots(_ lhs: SyncConnection, _ rhs: SyncConnection) -> Bool {
        lhs.remotePath == rhs.remotePath && lhs.localPath == rhs.localPath
    }

    private func receive(_ event: SyncEvent, id: String) {
        var event = event
        // An engine emits Disconnected before it has a connection ID. Keep even
        // these lifecycle events scoped to their owning volume.
        event.connectionID = id
        // Storage updates are frequent and have no bearing on global progress.
        if event.kind != .storage {
            var state = states[id] ?? State()
            if event.isRemoteAvailable {
                if !state.isConnected { state.error = nil }
                state.isConnected = true
            }
            switch event.kind {
            case .progress where event.isTransfer:
                state.isSyncing = true
                state.progress = event
                if let speed = event.bytesPerSecond {
                    if event.transferDirection == .upload { state.uploadBytesPerSecond = speed }
                    else if event.transferDirection == .download { state.downloadBytesPerSecond = speed }
                }
            case .complete, .error:
                state.isSyncing = false
                state.progress = nil
                state.uploadBytesPerSecond = 0
                state.downloadBytesPerSecond = 0
                state.error = event.kind == .error ? event.message : nil
                if event.isRemoteUnavailable { state.isConnected = false }
                else if event.kind == .complete { state.isConnected = true }
            default: break
            }
            states[id] = state
            publish()
        }
        onEvent?(event)
    }

    private func publish() { onStatesChanged?(states) }
}
