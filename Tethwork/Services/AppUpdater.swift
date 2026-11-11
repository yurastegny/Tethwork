import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    private weak var model: AppModel?
    private var controller: SPUStandardUpdaterController?
    private var availability: AnyCancellable?
    private var activity: AnyCancellable?
    private var pendingInstallation: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        activity = model.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new activity state is assigned.
            DispatchQueue.main.async { [weak self] in self?.resumeInstallationIfIdle() }
        }
    }

    func start() {
        guard controller == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Sparkle must not initialize before NSApplication finishes launching.
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        availability = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.updateChannels(releaseChannel: Bundle.main.object(forInfoDictionaryKey: "TethworkReleaseChannel") as? String)
    }

    static func updateChannels(releaseChannel: String?) -> Set<String> {
        releaseChannel == "beta" ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallationIfNeeded(installHandler)
    }

    /// Never restart the app in the middle of a synchronization or initial upload.
    func postponeInstallationIfNeeded(_ installHandler: @escaping () -> Void) -> Bool {
        guard let model, model.isSyncing || model.isMergingInitialFiles else { return false }
        pendingInstallation = installHandler
        return true
    }

    func resumeInstallationIfIdle() {
        guard let handler = pendingInstallation,
              model?.isSyncing != true, model?.isMergingInitialFiles != true else { return }
        pendingInstallation = nil
        handler()
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}
