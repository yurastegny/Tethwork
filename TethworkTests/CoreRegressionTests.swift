import XCTest
import Combine
import AppKit
import SwiftUI
import QuickLookThumbnailing
@testable import Tethwork

final class CoreRegressionTests: XCTestCase {
    func testBundleVersionAndReleaseChannel() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "0.0.1")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "1")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "TethworkReleaseChannel") as? String, "beta")
    }

    @MainActor
    func testAppIconIncludesModernAssetAndFullResolutionLegacyFallback() throws {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, "AppIcon")
        XCTAssertNotNil(NSImage(named: "AppIcon"))
        let url = try XCTUnwrap(bundle.url(forResource: "AppIcon", withExtension: "icns"))
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        let sizes = Set(image.representations.map(\.pixelsWide))
        XCTAssertTrue(Set([16, 32, 64, 128, 256, 512, 1024]).isSubset(of: sizes),
                      "macOS 14/15 need a full-resolution ICNS, not Xcode's default 256 px fallback")
        for representation in image.representations {
            XCTAssertEqual(representation.pixelsWide, representation.pixelsHigh)
        }
        let largest = try XCTUnwrap(image.representations.first { $0.pixelsWide == 1024 } as? NSBitmapImageRep)
        XCTAssertEqual(try XCTUnwrap(largest.colorAt(x: 0, y: 0)).alphaComponent, 0,
                       "Keep the system-generated transparent margins instead of exporting an edge-to-edge square")
        XCTAssertGreaterThan(try XCTUnwrap(largest.colorAt(x: 512, y: 512)).alphaComponent, 0)
    }

    @MainActor
    func testNativeMenuPreservesTheOriginalMenuBarIconAssets() throws {
        for name in ["default", "default-inactive", "sync"] {
            let original = try XCTUnwrap(NSImage(named: name))
            let size = original.size
            let isTemplate = original.isTemplate
            let image = try XCTUnwrap(MenuBarStatusController.menuIcon(named: name))
            XCTAssertEqual(image.size, size, "Native menus must not stretch the icon to a square")
            XCTAssertEqual(image.isTemplate, isTemplate)
            XCTAssertTrue(image.isTemplate, "Menu-bar icons must adapt to light and dark appearances")
            XCTAssertEqual(image.size.width, 12)
            XCTAssertEqual(image.size.height, name == "default-inactive" ? 13 : 15)
        }
    }

    @MainActor
    func testMenuBarWidthDoesNotFollowTheStatusTitle() {
        let suite = "app.tethwork.fixed-menu-width.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false)
        model.activeConnection = SyncConnection(id: "width", name: "Width", remotePath: "/unused-remote", localPath: "/unused-local")
        let controller = MenuBarStatusController(model: model, installsStatusItem: false)
        XCTAssertEqual(MenuBarStatusController.menuWidth, 240)
        for title in ["Ready", String(repeating: "W", count: 200), String(repeating: "Широкая строка ", count: 20), String(repeating: "👨‍👩‍👧‍👦", count: 60)] {
            model.statusMessage = title
            controller.refresh()
            controller.menu.update()
            XCTAssertEqual(controller.menu.minimumWidth, MenuBarStatusController.menuWidth)
            XCTAssertEqual(controller.menu.size.width, MenuBarStatusController.menuWidth, accuracy: 1)
            let rendered = MenuBarStatusController.compactStatus(title)
            let width = (rendered as NSString).size(withAttributes: [.font: controller.menu.font ?? NSFont.menuFont(ofSize: 0)]).width
            XCTAssertLessThanOrEqual(width, MenuBarStatusController.titleWidth)
        }
    }

    @MainActor
    func testCompactStatusUsesCurrentActivityInsteadOfAStaleConnectingMessage() {
        let progress = AppModel.SyncProgress(done: 5, total: 100, phase: .checking)
        XCTAssertEqual(StatusBarView.activityStatusText(progress: progress, fallback: "Connecting…"), String(localized: "Checking files…"))
        XCTAssertEqual(StatusBarView.activityStatusText(progress: nil, fallback: "Ready"), "Ready")
    }

    @MainActor
    func testMenuBarSubmenuKeepsItsIdentityAndActionsDuringProgressUpdates() throws {
        let suite = "app.tethwork.stable-menu.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false)
        let connection = SyncConnection(id: "menu", name: "Menu", remotePath: "/unused-remote", localPath: "/unused-local")
        model.connections = [connection]
        model.activeConnection = connection
        model.syncProgress = .init(done: 1, total: 100)
        let controller = MenuBarStatusController(model: model, installsStatusItem: false)
        let pause = try XCTUnwrap(controller.menu.items.first { $0.identifier?.rawValue == "pause" })
        let submenu = try XCTUnwrap(pause.submenu)
        let firstOption = try XCTUnwrap(submenu.items.first)
        let volume = try XCTUnwrap(controller.menu.items.first { $0.identifier?.rawValue == "volume" })
        let count = controller.menu.items.count
        XCTAssertFalse(volume.isHidden)
        controller.menuWillOpen(controller.menu)
        controller.menuWillOpen(submenu)
        let frozenTitle = volume.title
        for done in 2..<30 {
            model.syncProgress = .init(done: done, total: 100)
            controller.refresh()
            XCTAssertTrue(pause.submenu === submenu)
            XCTAssertTrue(submenu.items.first === firstOption)
            XCTAssertEqual(controller.menu.items.count, count)
            XCTAssertEqual(volume.title, frozenTitle, "Menu width must not change while pause options are tracked")
        }
        controller.menuDidClose(submenu)
        XCTAssertNotEqual(volume.title, frozenTitle, "Newest progress should appear when the submenu closes")
        model.syncProgress = nil
        controller.refresh()
        XCTAssertFalse(volume.isHidden, "A stage transition must not move rows while tracking a submenu")
        XCTAssertTrue(firstOption.target === controller)
        let action = try XCTUnwrap(firstOption.action)
        XCTAssertTrue(NSApp.sendAction(action, to: firstOption.target, from: firstOption))
        XCTAssertTrue(model.isSyncPaused, "The preserved submenu action did not pause sync")
        model.resumeSync()
        controller.menuDidClose(controller.menu)
        XCTAssertTrue(volume.isHidden)
    }

    @MainActor
    func testInitialUploadPresentationUsesByteProgressAndSeparatesFinalChecks() {
        let snapshot = InitialUploadProgress(phase: .transferring, filesDone: 1, filesTotal: 4, bytesDone: 75, bytesTotal: 100,
                                             currentPath: "large.bin", bytesPerSecond: 1024, estimatedSecondsRemaining: 120)
        var progress = AppModel.SyncProgress(done: 1, total: 4, phase: .transferring, direction: .upload, initialUpload: snapshot)
        XCTAssertEqual(progress.percent, 75, "A count of unequal-sized files must not determine the percentage")
        XCTAssertNotNil(progress.byteSummary)
        XCTAssertNotNil(progress.remainingTimeText)
        XCTAssertFalse(progress.isIndeterminate)
        progress.phase = .finishing
        XCTAssertFalse(progress.isIndeterminate, "Known final verification work must also report progress")
        XCTAssertNotNil(progress.remainingTimeText)
        progress.phase = .checking
        XCTAssertFalse(progress.isIndeterminate)
        XCTAssertNotNil(progress.remainingTimeText, "Comparison used to hide the ETA even with a known work total")
        progress.phase = .preparing
        XCTAssertTrue(progress.isIndeterminate)
        XCTAssertNil(progress.remainingTimeText)
        XCTAssertNil(AppModel.SyncProgress.formattedRemainingTime(.infinity))
        XCTAssertNil(AppModel.SyncProgress.formattedRemainingTime(0))

        var stillPublishing = snapshot
        stillPublishing.bytesDone = 100
        XCTAssertLessThan(stillPublishing.fraction, 1, "Pending empty files/atomic publication must not show completion")
    }

    @MainActor
    func testMenuBarStatusCannotExpandTheMenuWithFullDiagnostics() {
        let diagnostic = "Automatic synchronization: Remote path unavailable: /Volumes/Data/Projects\n" +
            "Tethwork.SyncError (0): " + String(repeating: "very-long-path/", count: 30)
        let title = MenuBarStatusController.compactStatus(diagnostic)
        XCTAssertLessThanOrEqual(title.count, 48)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.contains("\n"))
        XCTAssertEqual(MenuBarStatusController.compactStatus("Ready"), "Ready")
        XCTAssertEqual(MenuBarStatusController.compactStatus("Checking\n  files…"), "Checking files…")
        XCTAssertLessThanOrEqual(MenuBarStatusController.compactStatus(String(repeating: "👨‍👩‍👧‍👦", count: 60)).count, 48)
    }

    @MainActor
    func testRestoredRemoteAccessClearsOnlyTheObsoleteConnectionError() {
        let suite = "app.tethwork.remote-recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false)
        model.handle(.init(kind: .error, message: "Remote path unavailable", path: nil, isRemoteUnavailable: true))
        XCTAssertTrue(model.isRemoteUnavailable)
        model.handle(.init(kind: .status, message: "Connected", path: nil, isRemoteAvailable: true))
        XCTAssertFalse(model.isRemoteUnavailable)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Connected")

        model.handle(.init(kind: .error, message: "Remote path unavailable", path: nil, isRemoteUnavailable: true))
        model.errorMessage = "Another operation failed"
        model.handle(.init(kind: .status, message: "Connected", path: nil, isRemoteAvailable: true))
        XCTAssertEqual(model.errorMessage, "Another operation failed")
    }

    @MainActor
    func testStorageUpdatePublishesChangesForExpandedOutlineChildren() async throws {
        let suite = "app.tethwork.outline-storage.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote")
        let local = root.appendingPathComponent("local")
        for base in [remote, local] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent("Work/Sub"), withIntermediateDirectories: true)
        }
        let connection = SyncConnection(id: "outline", name: "Outline", remotePath: remote.path, localPath: local.path)
        let engine = SyncEngine(watchesDirectories: false)
        try await engine.connect(connection: connection, pinned: ["Work"], deferInitialMerge: true)
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false, engine: engine)
        model.activeConnection = connection
        let listing = try await engine.listDirectory(relativePath: "")
        model.listing = listing
        let folder = try XCTUnwrap(listing.entries.first)
        await model.toggleFolderExpanded(folder)
        XCTAssertEqual(model.listOutlineRows().first(where: { $0.entry.relativePath == "Work/Sub" })?.entry.folderStorageState, .checking)
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        model.handle(.init(kind: .storage, message: "", folderStorageState: .local,
                           storageGeneration: listing.storageGeneration, path: "Work/Sub"))
        XCTAssertGreaterThan(updates, 0, "A cache-only storage update must redraw expanded rows")
        XCTAssertEqual(model.listOutlineRows().first(where: { $0.entry.relativePath == "Work/Sub" })?.entry.folderStorageState, .local)
        withExtendedLifetime(subscription) {}
        await engine.disconnect()
    }

    @MainActor
    func testAutomaticallyResolvedConflictsOnlyUpdateStatus() {
        let suite = "app.tethwork.resolved-conflicts.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false)
        let message = "Replaced the older network copy with the newer local version."
        model.handle(.init(kind: .conflict, message: message, path: "esvalidate"))
        XCTAssertEqual(model.statusMessage, message)
        XCTAssertNil(model.errorMessage)

        model.handle(.init(kind: .error, message: "Copy failed"))
        XCTAssertEqual(model.errorMessage, "Copy failed", "Actual errors must remain visible")
    }

    @MainActor
    func testStatusPresentationDoesNotDependOnPinPolicy() {
        let suite = "app.tethwork.status-colors.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false)
        for state in [FolderStorageState.local, .partial, .onlineOnly, .pending, .checking, .unavailable] {
            let pinned = FileEntry(name: "Work", absolutePath: "/Work", relativePath: "Work", isDirectory: true,
                                   size: 0, modified: .distantPast, syncMode: .offline, isLocallyAvailable: true,
                                   syncStatus: .synced, folderStorageState: state)
            var individuallyPinned = pinned
            individuallyPinned.syncMode = .onlineOnly
            individuallyPinned.hasPinnedDescendants = true
            let first = model.displaySyncStatus(for: pinned)
            let second = model.displaySyncStatus(for: individuallyPinned)
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.foregroundColor(isSelected: false, isKeyWindow: true),
                           second.foregroundColor(isSelected: false, isKeyWindow: true))
        }
        var folder = FileEntry(name: "Work", absolutePath: "/Work", relativePath: "Work", isDirectory: true,
                               size: 0, modified: .distantPast, syncMode: .offline, isLocallyAvailable: true,
                               syncStatus: .synced, folderStorageState: .checking)
        let passive = model.displaySyncStatus(for: folder)
        model.syncProgress = .init(done: 0, total: 0, activePath: "Work/file.txt", phase: .checking)
        folder.folderStorageState = nil
        let active = model.displaySyncStatus(for: folder)
        XCTAssertEqual(active, passive, "Identical Checking labels must share both icon and tint")
    }

    @MainActor
    func testStatusTintsRespectSelectionAndWindowFocusConsistently() {
        for status in AppModel.DisplayedSyncStatus.allCases {
            XCTAssertEqual(status.foregroundColor(isSelected: true, isKeyWindow: true), .white)
            XCTAssertEqual(status.foregroundColor(isSelected: true, isKeyWindow: false), .white)
            XCTAssertEqual(status.foregroundColor(isSelected: false, isKeyWindow: false), .secondary)
        }
        XCTAssertEqual(AppModel.DisplayedSyncStatus.local.foregroundColor(isSelected: false, isKeyWindow: true), .accentColor)
        XCTAssertEqual(AppModel.DisplayedSyncStatus.checking.foregroundColor(isSelected: false, isKeyWindow: true), .secondary)
        XCTAssertEqual(AppModel.DisplayedSyncStatus.unavailable.foregroundColor(isSelected: false, isKeyWindow: true), .orange)
    }

    @MainActor
    func testSwitchingVolumesClearsProgressOwnedByThePreviousConnection() async throws {
        let suite = "app.tethwork.switch-progress.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = root.appendingPathComponent("remote")
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false,
                             engine: SyncEngine(watchesDirectories: false))
        model.activeConnection = SyncConnection(id: "old", name: "Old", remotePath: "/old-remote", localPath: "/old-local")
        model.handle(.init(kind: .progress, message: "Checking", connectionID: "old", path: "Work/file.txt",
                           progressDone: 0, isTransfer: true, bytesPerSecond: 123,
                           transferDirection: .download, phase: .checking))
        XCTAssertNotNil(model.syncProgress)
        await model.connect(name: "New", remotePath: remote.path, localPath: local.path, connectionId: "new")
        XCTAssertNil(model.syncProgress, "Previous volume left a stuck Checking badge")
        XCTAssertEqual(model.downloadBytesPerSecond, 0)
        XCTAssertFalse(model.isActivelySyncing("Work"))
        await model.disconnect()
    }

    @MainActor
    func testErrorDetailsRenderInlineInTheExistingWindow() {
        let message = "Copy synchronized file: The file couldn’t be saved.\n" +
            "Source: /Volumes/Data/Work/client.log\nDestination: /Users/example/Work/client.log\n" +
            "NSCocoaErrorDomain (256)"
        let host = NSHostingView(rootView: ErrorDetailsPanel(
            title: "Synchronization error",
            message: message,
            onClose: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 320)
        host.layoutSubtreeIfNeeded()

        // The regression was a separate popover render surface. Error details
        // must stay inside the main window hierarchy.
        XCTAssertNil(host.window)
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    @MainActor
    func testBackgroundChecksKeepKnownFolderBadgesButRealTransfersRemainVisible() {
        let suite = "app.tethwork.background-badges.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false)
        let folder = FileEntry(name: "Work", absolutePath: "/Work", relativePath: "Work", isDirectory: true,
                               size: 0, modified: .distantPast, syncMode: .offline, isLocallyAvailable: true,
                               syncStatus: .synced, folderStorageState: .local)
        model.syncProgress = .init(done: 0, total: 0, activePath: "Work/file.txt", phase: .checking)
        XCTAssertEqual(model.displaySyncStatus(for: folder).title, "Local")
        model.syncProgress?.phase = .transferring
        XCTAssertTrue(model.displaySyncStatus(for: folder).isSyncing)
        XCTAssertEqual(model.displaySyncStatus(for: folder).title, "Syncing…")
    }

    @MainActor
    func testFolderStorageEventsUpdateVisibleRowsAndRejectOlderResults() {
        let suite = "app.tethwork.folder-events.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false)
        model.activeConnection = SyncConnection(id: "test", name: "Test", remotePath: "/not-used", localPath: "/not-used-local")
        let folder = FileEntry(name: "Work", absolutePath: "/not-used/Work", relativePath: "Work", isDirectory: true,
                               size: 0, modified: .distantPast, syncMode: .onlineOnly, isLocallyAvailable: true,
                               syncStatus: .onlineOnly, hasPinnedDescendants: true, folderStorageState: .checking)
        model.listing = DirectoryListing(relativePath: "", entries: [folder], breadcrumbs: [])
        model.columns = [.init(path: "", entries: [folder], revealedChildID: nil, isLoading: false)]
        model.handle(.init(kind: .storage, message: "", connectionID: "test", folderStorageState: .local,
                           storageGeneration: 3, path: "Work"))
        XCTAssertEqual(model.listing?.entries.first?.folderStorageState, .local)
        XCTAssertEqual(model.columns.first?.entries.first?.folderStorageState, .local)
        XCTAssertEqual(model.displaySyncStatus(for: model.listing!.entries[0]).title, "Local")
        XCTAssertEqual(model.listing?.entries.first?.syncMode, .onlineOnly, "A storage event changed pin policy")
        model.handle(.init(kind: .storage, message: "", connectionID: "test", folderStorageState: .partial,
                           storageGeneration: 2, path: "Work"))
        model.handle(.init(kind: .storage, message: "", connectionID: "another-volume", folderStorageState: .partial,
                           storageGeneration: 100, path: "Work"))
        XCTAssertEqual(model.listing?.entries.first?.folderStorageState, .local, "A stale result replaced current storage state")
    }

    @MainActor
    func testStorageBadgesDistinguishPartialFoldersFromOnlineAndFullyLocal() {
        let suite = "app.tethwork.badge-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false)
        var folder = FileEntry(name: "Work", absolutePath: "/Work", relativePath: "Work", isDirectory: true,
                               size: 0, modified: .distantPast, syncMode: .onlineOnly,
                               isLocallyAvailable: true, syncStatus: .onlineOnly, hasPinnedDescendants: true)
        XCTAssertEqual(model.displaySyncStatus(for: folder).title, "Partially local")
        folder.folderStorageState = .local
        XCTAssertEqual(model.displaySyncStatus(for: folder).title, "Local", "Physical completeness must not depend on pinning the parent")
        XCTAssertEqual(folder.syncMode, .onlineOnly, "Rendering a badge changed the sync policy")
        folder.folderStorageState = .checking
        XCTAssertEqual(model.displaySyncStatus(for: folder).title, "Checking…")
        folder.folderStorageState = nil
        folder.syncMode = .offline
        folder.syncStatus = .synced
        XCTAssertEqual(model.displaySyncStatus(for: folder).title, "Local")
        folder.syncMode = .onlineOnly
        folder.hasPinnedDescendants = false
        folder.isLocallyAvailable = false
        XCTAssertEqual(model.displaySyncStatus(for: folder).title, "Online")
    }

    @MainActor
    func testThumbnailSuspensionsBlockOnlyTheirSubtreeAndRespectOverlappingOwners() {
        let requests = ThumbnailRequests()
        let root = URL(fileURLWithPath: "/test/trash/item")
        let child = root.appendingPathComponent("image.png")
        let sibling = URL(fileURLWithPath: "/test/trash/item-other/image.png")
        func request(_ url: URL) -> QLThumbnailGenerator.Request {
            .init(fileAt: url, size: CGSize(width: 24, height: 24), scale: 2, representationTypes: .thumbnail)
        }
        let first = requests.suspend(in: [root])
        let second = requests.suspend(in: [root])
        XCTAssertNil(requests.register(request(child), url: child))
        let siblingID = requests.register(request(sibling), url: sibling)
        XCTAssertNotNil(siblingID)
        requests.resume(first)
        XCTAssertNil(requests.register(request(child), url: child), "One owner resumed another owner's blocked path")
        requests.resume(second)
        let childID = requests.register(request(child), url: child)
        XCTAssertNotNil(childID)
        if let childID { requests.finish(childID) }
        if let siblingID { requests.finish(siblingID) }
    }

    @MainActor
    private func withVolumes(_ body: (AppModel, SyncEngine, [SyncConnection], URL) async throws -> Void) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tethwork-switch-tests-\(UUID())")
        let suite = "app.tethwork.switch-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        let store = ConfigStore(defaults: defaults)
        let volumes = try ["A", "B", "C"].map { name in
            let remote = root.appendingPathComponent("remote-\(name)")
            try fm.createDirectory(at: remote, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: remote.appendingPathComponent("\(name).txt"))
            return SyncConnection(id: name, name: name, remotePath: remote.path,
                                  localPath: root.appendingPathComponent("local-\(name)").path)
        }
        store.connections = volumes
        let engine = SyncEngine(watchesDirectories: false)
        let model = AppModel(store: store, startsSession: false, engine: engine,
                             engineFactory: { SyncEngine(watchesDirectories: false) })
        model.refreshFromStore()
        do {
            try await body(model, engine, volumes, root)
            await model.disconnect()
            await model.shutdownSynchronization()
        } catch {
            await model.disconnect()
            await model.shutdownSynchronization()
            throw error
        }
    }

    @MainActor
    func testUnselectedVolumesSyncWithoutChangingTheBrowser() async throws {
        try await withVolumes { model, _, volumes, _ in
            await model.selectConnection(volumes[0])
            await model.togglePinCurrent()
            await model.selectConnection(volumes[1])
            await model.togglePinCurrent()
            await model.selectConnection(volumes[2])
            let aRemote = URL(fileURLWithPath: volumes[0].remotePath).appendingPathComponent("A.txt")
            let bLocal = URL(fileURLWithPath: volumes[1].localPath).appendingPathComponent("B.txt")
            try Data("remote A edited".utf8).write(to: aRemote)
            try Data("local B edited".utf8).write(to: bLocal)
            for url in [aRemote, bLocal] {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
            }
            model.synchronizeConfiguredConnections()
            let deadline = Date().addingTimeInterval(5)
            var a: String?
            var b: String?
            while Date() < deadline {
                a = try? String(contentsOfFile: (volumes[0].localPath as NSString).appendingPathComponent("A.txt"), encoding: .utf8)
                b = try? String(contentsOfFile: (volumes[1].remotePath as NSString).appendingPathComponent("B.txt"), encoding: .utf8)
                if a == "remote A edited", b == "local B edited" { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(a, "remote A edited")
            XCTAssertEqual(b, "local B edited")
            XCTAssertEqual(model.activeConnection?.id, "C")
            XCTAssertEqual(model.listing?.entries.map(\.name), ["C.txt"])
            XCTAssertNil(model.errorMessage)
        }
    }

    @MainActor
    func testRapidDiskSwitchKeepsLatestEngineAndListing() async throws {
        try await withVolumes { model, engine, volumes, _ in
            await model.selectConnection(volumes[0])
            XCTAssertEqual(model.listing?.entries.map(\.name), ["A.txt"])
            let oldListing = Task { try? await model.loadDirectory("") }
            let intermediate = Task { await model.selectConnection(volumes[1]) }
            let deadline = Date().addingTimeInterval(5)
            while model.connectingConnectionID != "B" && model.activeConnection?.id != "B" && Date() < deadline {
                await Task.yield()
            }
            XCTAssertTrue(model.connectingConnectionID == "B" || model.activeConnection?.id == "B")
            await model.selectConnection(volumes[2])
            await intermediate.value
            _ = await oldListing.value
            let engineID = await engine.connection?.id
            XCTAssertEqual(engineID, "A", "Selecting C must not repurpose or disconnect A's engine")
            XCTAssertEqual(model.activeConnection?.id, "C")
            XCTAssertEqual(model.listing?.entries.map(\.name), ["C.txt"])
            XCTAssertNil(model.connectingConnectionID)
        }
    }

    @MainActor
    func testReturningToVolumePublishesItsSnapshotBeforeFreshListing() async throws {
        try await withVolumes { model, _, volumes, _ in
            await model.selectConnection(volumes[0])
            await model.selectConnection(volumes[1])
            try Data("new".utf8).write(to: URL(fileURLWithPath: volumes[0].remotePath).appendingPathComponent("fresh.txt"))
            var observed: [[String]] = []
            let observation = model.$listing.sink { listing in
                if model.activeConnection?.id == "A", let listing {
                    observed.append(listing.entries.map(\.name))
                }
            }
            await model.selectConnection(volumes[0])
            observation.cancel()
            XCTAssertEqual(observed.first, ["A.txt"], "The saved snapshot was not published before I/O")
            XCTAssertEqual(observed.last, ["A.txt", "fresh.txt"], "The cached snapshot was not refreshed")
            XCTAssertFalse(observed.contains(["B.txt"]), "Another volume's snapshot leaked into this volume")
        }
    }

    @MainActor
    func testHiddenFilesToggleShowsUserFilesButNeverInternalState() async throws {
        try await withVolumes { model, engine, volumes, _ in
            let root = URL(fileURLWithPath: volumes[0].remotePath)
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".hy2test"), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: root.appendingPathComponent(".hy2test/client.log"))
            try Data("internal".utf8).write(to: root.appendingPathComponent(".tethwork-sync-state.json"))
            await model.selectConnection(volumes[0])
            XCTAssertEqual(model.listing?.entries.map(\.name), ["A.txt"])
            model.setShowsHiddenFiles(true)
            let deadline = Date().addingTimeInterval(5)
            while model.listing?.entries.contains(where: { $0.name == ".hy2test" }) != true && Date() < deadline {
                await Task.yield()
            }
            XCTAssertTrue(model.showsHiddenFiles)
            XCTAssertTrue(model.listing?.entries.contains(where: { $0.name == ".hy2test" }) == true)
            XCTAssertFalse(model.listing?.entries.contains(where: { $0.name == ".tethwork-sync-state.json" }) == true)
            let found = try await engine.search(query: "client.log", under: "", includeHidden: true)
            XCTAssertEqual(found.map(\.relativePath), [".hy2test/client.log"])
            let hidden = try await engine.search(query: "client.log", under: "")
            XCTAssertTrue(hidden.isEmpty)
        }
    }

    @MainActor
    func testChangedVolumeRootDoesNotReuseOldSnapshot() async throws {
        try await withVolumes { model, _, volumes, _ in
            await model.selectConnection(volumes[0])
            var observed: [[String]] = []
            let observation = model.$listing.sink { listing in
                if let listing { observed.append(listing.entries.map(\.name)) }
            }
            observed.removeAll()
            await model.connect(name: "A", remotePath: volumes[2].remotePath,
                                localPath: volumes[0].localPath, connectionId: "A")
            observation.cancel()
            XCTAssertFalse(observed.contains(["A.txt"]), "An old root was displayed after editing the connection")
            XCTAssertEqual(model.listing?.entries.map(\.name), ["C.txt"])
        }
    }

    @MainActor
    func testTrashRemovesFolderFromVisibleSnapshotAndPreservesSibling() async throws {
        try await withVolumes { model, _, volumes, _ in
            let remote = URL(fileURLWithPath: volumes[0].remotePath)
            try FileManager.default.createDirectory(at: remote.appendingPathComponent("Delete/sub"), withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: remote.appendingPathComponent("Delete/sub/file.txt"))
            await model.selectConnection(volumes[0])
            model.pendingDeleteIDs = ["Delete"]
            await model.confirmDelete()
            XCTAssertEqual(model.listing?.entries.map(\.name), ["A.txt"])
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isBusy)
            let items = TrashStore.loadItems(remoteRoot: remote.path)
            XCTAssertEqual(items.map(\.originalPath), ["Delete"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent("A.txt").path))
        }
    }

    @MainActor
    func testCollapsingColumnsUpdatesTheCurrentFolderAndListing() {
        let suite = "app.tethwork.model-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false)
        model.columns = [.empty(path: ""), .empty(path: "Work"), .empty(path: "Work/sub")]
        model.currentPath = "Work/sub"
        model.collapseColumns(to: 1)
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.currentPath, "Work")
        XCTAssertEqual(model.listing?.relativePath, "Work")
    }

    @MainActor
    func testOutlineCacheInvalidatesWhenListingChanges() {
        let suite = "app.tethwork.model-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults), startsSession: false)
        let entry = FileEntry(name: "first", absolutePath: "/first", relativePath: "first", isDirectory: false,
                              size: 0, modified: .distantPast, syncMode: .onlineOnly,
                              isLocallyAvailable: false, syncStatus: .onlineOnly)
        model.listing = DirectoryListing(relativePath: "", entries: [entry], breadcrumbs: [])
        XCTAssertEqual(model.listOutlineRows().map(\.id), ["first"])
        model.listing = DirectoryListing(relativePath: "", entries: [], breadcrumbs: [])
        XCTAssertTrue(model.listOutlineRows().isEmpty)
    }

    func testUnsafeTrashMetadataIsRejected() {
        for path in ["../escape", "/absolute", "a/../../escape", ".tethwork-trash/index.json", ".tethwork-verification-cache.json"] {
            XCTAssertNil(TrashStore.safeRelativePath(path), path)
        }
        XCTAssertEqual(TrashStore.safeRelativePath("Work/report.txt"), "Work/report.txt")
        XCTAssertEqual(TrashStore.safeRelativePath("Fonts/Lemon:Milk"), "Fonts/Lemon:Milk")
        XCTAssertTrue(TrashStore.isValidName("Lemon:Milk"))
        XCTAssertFalse(TrashStore.isValidID("../escape"))
        XCTAssertFalse(TrashStore.isValidName("../escape"))
    }

    func testPinsAreCompactedAndUnsafePathsAreDropped() {
        XCTAssertEqual(SyncEngine.compactPinnedPaths(["Work", "Work/sub", "Other", "../escape"]), ["Other", "Work"])
        XCTAssertEqual(SyncEngine.compactPinnedPaths(["", "Work"]), [""])
    }

    func testPinSelectionMigratesToDiskAndSurvivesRelaunch() throws {
        let suite = "app.tethwork.pin-migration.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("pins.json")
        let legacy = ["photos": ["Library/a.jpg"], "data": ["Work"]]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "pinnedByConnection")
        let store = ConfigStore(defaults: defaults, pinsFileURL: url)
        XCTAssertEqual(store.pinnedByConnection, legacy)
        XCTAssertNil(defaults.data(forKey: "pinnedByConnection"))
        let manyPaths = (0..<60_000).map { "Library/" + String(repeating: "a", count: 100) + "/\($0).jpg" }
        store.setPinnedPaths(manyPaths, for: "photos")
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 4 * 1024 * 1024)
        XCTAssertNil(defaults.data(forKey: "pinnedByConnection"))
        let reopened = ConfigStore(defaults: defaults, pinsFileURL: url)
        XCTAssertEqual(reopened.pinnedPaths(for: "photos"), manyPaths)
        XCTAssertEqual(reopened.pinnedPaths(for: "data"), ["Work"])
        reopened.setPinnedPaths([], for: "photos")
        XCTAssertEqual(ConfigStore(defaults: defaults, pinsFileURL: url).pinnedPaths(for: "photos"), [])
    }

    func testFailedPinMigrationRetainsLegacySelection() throws {
        let suite = "app.tethwork.pin-migration-failure.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        // A regular file cannot act as the parent directory of the new store.
        try Data().write(to: root)
        let legacy = ["photos": ["Library"]]
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: "pinnedByConnection")
        let store = ConfigStore(defaults: defaults, pinsFileURL: root.appendingPathComponent("pins.json"))
        XCTAssertEqual(store.pinnedByConnection, legacy)
        XCTAssertEqual(defaults.data(forKey: "pinnedByConnection"), data)
    }

    @MainActor
    func testClosingTheLastWindowDoesNotTerminateSynchronization() {
        XCTAssertFalse(TethworkApplicationDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testRemoteTrashDeletionDoesNotResurrect() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tethwork-xctest-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote")
        let local = root.appendingPathComponent("local")
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data("retained in trash".utf8).write(to: remote.appendingPathComponent("file.txt"))
        let engine = SyncEngine(watchesDirectories: false)
        try await engine.connect(connection: .init(name: "Test", remotePath: remote.path, localPath: local.path), pinned: [""])
        let first = await engine.fullSync()
        XCTAssertTrue(first)
        _ = try TrashStore.moveToTrash(relativePath: "file.txt", remoteRoot: remote.path, wasPinned: true)
        let second = await engine.fullSync()
        XCTAssertTrue(second)
        XCTAssertFalse(fm.fileExists(atPath: local.appendingPathComponent("file.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: remote.appendingPathComponent("file.txt").path))
        XCTAssertEqual(TrashStore.loadItems(remoteRoot: remote.path).count, 1)
        await engine.disconnect()
    }
}
