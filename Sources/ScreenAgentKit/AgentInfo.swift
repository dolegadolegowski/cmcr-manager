import Foundation

/// Fixed facts about CMCR Screen Agent (docs/screen-agent.md). They repeat `CMCRCore.ScreenAgentInfo`: the agent
/// does not link CMCRCore, to stay small, and `ScreenAgentKitTests` keeps both copies equal.
public enum AgentInfo {
    /// Version of the agent itself (not the app's VERSION). Bump it in both copies only when the agent changes.
    public static let version = "1.0.0"
    public static let label = "pl.cmcr.manager.screen-agent"
    public static let bundleID = label
    public static let displayName = "CMCR Screen Agent"
    public static let appName = "CMCR Screen Agent.app"
    public static let executableName = "cmcr-screen-agent"
    /// First word of every request on the socket.
    public static let protocolVersion = "CMCRA1"

    // Paths on the iMac, without the test-only prefix (`AgentPaths`).
    public static let installDir = "/Library/Application Support/CMCR/ScreenAgent"
    public static let appPath = "\(installDir)/\(appName)"
    public static let executablePath = "\(appPath)/Contents/MacOS/\(executableName)"
    public static let runDir = "\(installDir)/run"
    public static let shotsDir = "\(installDir)/shots"
    public static let plistPath = "/Library/LaunchAgents/\(label).plist"

    /// Exit codes of `cmcr-screen-agent client …` (the same values as `ScreenAgentInfo.ClientCode`).
    public enum ClientCode {
        public static let ok: Int32 = 0
        /// Anything not covered below.
        public static let other: Int32 = 1
        public static let usage: Int32 = 2
        public static let unreachable: Int32 = 10
        public static let untrusted: Int32 = 11
        public static let noPermission: Int32 = 12
        public static let locked: Int32 = 13
        public static let noImage: Int32 = 14
        public static let captureFailed: Int32 = 15
        public static let protocolError: Int32 = 16
    }

    /// The client gives up on connecting, and on a peer that stays silent, after this long.
    public static let clientTimeout: TimeInterval = 10
    /// Upper bound for a whole client exchange, so a peer that trickles bytes cannot hold the preview script.
    public static let clientTotalTimeout: TimeInterval = 30
    /// The agent answers a capture within this time (ERR failed otherwise), well inside the client's timeout.
    public static let captureTimeout: TimeInterval = 8
    /// How long the observation notice stays on screen.
    public static let noticeSeconds: TimeInterval = 8
    /// macOS keeps the Screen Recording decision for the lifetime of a process: an agent older than this that finds
    /// it has no permission exits after answering, so launchd starts a fresh one that sees a newly granted permission.
    public static let deniedRestartAge: TimeInterval = 30
    /// …but not while the permission dialog it asked for may still be on screen at the iMac.
    public static let permissionRequestHold: TimeInterval = 120
    /// Displays are numbered 1…9 (like `screencapture -D` and the preview script's `display` command).
    public static let maxDisplays = 9
    /// Largest JPEG the client accepts for one display.
    public static let maxImageBytes = 64 << 20
    /// Accepted range of the longer side requested for a capture.
    public static let maxSideRange = 16...16384
    /// Accepted JPEG quality.
    public static let qualityRange = 10...100
}

/// The agent's paths on this Mac. In DEBUG builds (the e2e harness) every system path is under
/// `$CMCR_SETUP_ROOT_PREFIX`, like the setup script's; release builds ignore the variable.
public struct AgentPaths: Equatable, Sendable {
    public var prefix: String

    public init(prefix: String = "") {
        var p = prefix
        while p.hasSuffix("/") { p.removeLast() }
        self.prefix = p
    }

    /// Paths for this process: the test prefix applies only to DEBUG builds.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentPaths {
        #if DEBUG
        return AgentPaths(prefix: environment["CMCR_SETUP_ROOT_PREFIX"] ?? "")
        #else
        return AgentPaths()
        #endif
    }

    public var installDir: String { prefix + AgentInfo.installDir }
    public var appPath: String { prefix + AgentInfo.appPath }
    public var executablePath: String { prefix + AgentInfo.executablePath }
    public var runDir: String { prefix + AgentInfo.runDir }
    public var shotsDir: String { prefix + AgentInfo.shotsDir }

    public func socketPath(uid: uid_t) -> String { "\(runDir)/\(uid).sock" }
    public func shotsDir(uid: uid_t) -> String { "\(shotsDir)/\(uid)" }
}

/// When an agent that has no Screen Recording permission should exit (see `AgentInfo.deniedRestartAge`).
public enum RestartPolicy {
    /// - Parameters:
    ///   - processAge: seconds since the agent started.
    ///   - sincePermissionRequest: seconds since this process last showed the permission dialog, if ever.
    public static func shouldExitAfterDenied(processAge: TimeInterval, sincePermissionRequest: TimeInterval?) -> Bool {
        guard processAge > AgentInfo.deniedRestartAge else { return false }
        if let s = sincePermissionRequest, s < AgentInfo.permissionRequestHold { return false }
        return true
    }
}
