import Foundation

/// Finds the copy of CMCR Screen Agent.app that ships with this app, to upload it to the iMacs.
public enum ScreenAgentLocator {
    /// The bundled agent, or `nil` when this build has none (e.g. `swift run` without the bundle step).
    /// Lookup order: `CMCR_SCREEN_AGENT_APP` (test harness / DEBUG only), `Contents/Helpers` of the running app,
    /// `Contents/Helpers` of the app around `cmcrctl` (`Contents/Resources/bin`), next to the executable, and
    /// finally `/Applications/CMCR Manager.app`.
    public static func bundledAgent(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    mainBundle: Bundle = .main) -> URL? {
        // Filled in by the build/ship part (docs/screen-agent.md).
        nil
    }
}
