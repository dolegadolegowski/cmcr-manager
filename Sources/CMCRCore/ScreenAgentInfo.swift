import Foundation

/// Fixed facts about CMCR Screen Agent – the small app that takes a screenshot on the iMac only when the screen
/// preview asks for it (docs/screen-agent.md). The agent repeats these values (`Sources/ScreenAgentKit`); a test
/// keeps both copies equal.
public enum ScreenAgentInfo {
    /// Version of the agent itself, independent of the app's VERSION. Bump it only when the agent's code changes:
    /// with an ad-hoc signature every replaced agent needs its Screen Recording permission granted again.
    public static let version = "1.0.0"
    /// Bundle identifier, launchd label and the name TCC keys the permission on.
    public static let label = "pl.cmcr.manager.screen-agent"
    public static let bundleID = label
    /// Shown in System Settings › Privacy & Security › Screen & System Audio Recording.
    public static let displayName = "CMCR Screen Agent"
    public static let appName = "CMCR Screen Agent.app"
    public static let executableName = "cmcr-screen-agent"
    /// Socket protocol version (first word of every request).
    public static let protocolVersion = "CMCRA1"

    // Paths on the iMac (without the test-only CMCR_SETUP_ROOT_PREFIX).
    public static let installDir = "/Library/Application Support/CMCR/ScreenAgent"
    public static let appPath = "\(installDir)/\(appName)"
    public static let executablePath = "\(appPath)/Contents/MacOS/\(executableName)"
    /// root:wheel 0755. Root makes `run/<uid>/` (owner <uid>, 0700) before it starts that account's agent, so no
    /// account can take another one's socket name.
    public static let runDir = "\(installDir)/run"
    /// The agent's socket inside its own `run/<uid>/` (`AgentInfo.socketName` in the agent; a test keeps them equal).
    public static let socketName = "agent.sock"
    public static let shotsDir = "\(installDir)/shots"
    public static let plistPath = "/Library/LaunchAgents/\(label).plist"

    /// `run/<uid>`, the folder of that account's agent.
    public static func socketDir(uid: String) -> String { "\(runDir)/\(uid)" }
    /// `run/<uid>/agent.sock`.
    public static func socketPath(uid: String) -> String { "\(socketDir(uid: uid))/\(socketName)" }

    /// Exit codes of `cmcr-screen-agent client …`.
    public enum ClientCode {
        public static let ok: Int32 = 0
        public static let usage: Int32 = 2
        public static let unreachable: Int32 = 10
        public static let untrusted: Int32 = 11
        public static let noPermission: Int32 = 12
        public static let locked: Int32 = 13
        public static let noImage: Int32 = 14
        public static let captureFailed: Int32 = 15
        public static let protocolError: Int32 = 16
    }

    /// The LaunchAgent property list installed on the iMac (`executable` already carries any test prefix).
    public static func launchAgentPlist(executable: String = executablePath) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>Program</key>
        \t<string>\(xmlEscaped(executable))</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(xmlEscaped(executable))</string>
        \t\t<string>serve</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>ThrottleInterval</key>
        \t<integer>5</integer>
        \t<key>LimitLoadToSessionType</key>
        \t<string>Aqua</string>
        \t<key>ProcessType</key>
        \t<string>Interactive</string>
        \t<key>AssociatedBundleIdentifiers</key>
        \t<array>
        \t\t<string>\(bundleID)</string>
        \t</array>
        </dict>
        </plist>

        """
    }

    static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
