import AppKit
import Foundation

/// Hosted XCTest already has NSApp, so it cannot catch early App.init crashes.
@main
struct AppStartupTests {
    @MainActor
    static func main() {
        precondition(NSApp == nil, "This regression must run before NSApplication is created")
        let suite = "app.tethwork.early-startup.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: ConfigStore(defaults: defaults))
        precondition(NSApp == nil, "Model initialization must defer AppKit startup work")
        precondition(model.connections.isEmpty, "Startup test must not load real user connections")
        withExtendedLifetime(model) {}
        print("PASS: AppModel can initialize before SwiftUI creates NSApplication")
    }
}
