import AppKit
import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// The app's model tests need a configuration folder, Keychain service and update cache of their own:
/// scripts/test.sh starts `swift test` with them (CMCR_CONFIG_DIR, CMCR_KEYCHAIN_SERVICE, CMCR_PASSWORD,
/// CMCR_UPDATE_STATE_DIR). Without them the suite is skipped, so a plain `swift test` never touches the
/// user's real configuration or Keychain items.
enum AppTestEnvironment {
    static var isIsolated: Bool {
        let env = ProcessInfo.processInfo.environment
        guard let config = env["CMCR_CONFIG_DIR"], let service = env["CMCR_KEYCHAIN_SERVICE"],
              let state = env["CMCR_UPDATE_STATE_DIR"], env["CMCR_PASSWORD"]?.isEmpty == false else { return false }
        let temporary = [NSTemporaryDirectory(), "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        return service != "pl.cmcr.manager" && service.hasPrefix("pl.cmcr.manager.")
            && [config, state].allSatisfy { path in temporary.contains { path.hasPrefix($0) } }
    }

    /// A Mac that refuses every connection at once (nothing listens on port 1).
    static func closedHost(_ name: String, mac: String = "") -> Machine {
        Machine(name: name, address: "127.0.0.1", user: "nikt", port: 1, macAddress: mac)
    }

    @MainActor
    static func makeModel(_ hosts: [Machine]) -> AppModel {
        _ = NSApplication.shared          // NSApp is used for the Dock badge and notifications
        precondition(Keychain.service != "pl.cmcr.manager", "testy nie mogą używać prawdziwego Pęku kluczy")
        let model = AppModel()
        model.machines = hosts
        model.statuses = [:]
        return model
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    @MainActor
    static func wait(_ timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}
