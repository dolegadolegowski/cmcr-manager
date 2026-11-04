import Foundation

/// CMCR Screen Agent on the iMacs: install/update, ask for the Screen Recording permission, status, removal
/// (docs/screen-agent.md). Every operation prints its own progress through `onOutput`; machine-readable lines
/// start with `CMCR:AGENT`.
public extension Operations {
    /// Uploads `agentApp` (a CMCR Screen Agent.app bundle) and installs or updates it as root. The same version
    /// already installed is left untouched (keeps the Screen Recording permission).
    static func installScreenAgent(on host: Machine, agentApp: URL, password: String?, settings: SSHSettings,
                                   handle: ProcessHandle? = nil, onOutput: Output? = nil) async -> CommandResult {
        // Filled in by the core part.
        CommandResult(exitCode: 1, stdout: Data(), stderr: Data("Nie zaimplementowano.\n".utf8))
    }

    /// Asks the agent in the logged-in user's session to request the Screen Recording permission (macOS shows its
    /// dialog at the iMac).
    static func requestScreenAgentPermission(on host: Machine, password: String?, settings: SSHSettings,
                                             handle: ProcessHandle? = nil, onOutput: Output? = nil) async -> CommandResult {
        CommandResult(exitCode: 1, stdout: Data(), stderr: Data("Nie zaimplementowano.\n".utf8))
    }

    /// Removes the agent, its LaunchAgent, sockets, screenshots and its TCC entry.
    static func removeScreenAgent(on host: Machine, password: String?, settings: SSHSettings,
                                  handle: ProcessHandle? = nil, onOutput: Output? = nil) async -> CommandResult {
        CommandResult(exitCode: 1, stdout: Data(), stderr: Data("Nie zaimplementowano.\n".utf8))
    }

    /// Installed version, whether launchd has it in the console user's session, and the agent's own `ping` line.
    static func screenAgentStatus(on host: Machine, password: String?, settings: SSHSettings,
                                  handle: ProcessHandle? = nil) async -> (ScreenAgentStatus?, CommandResult) {
        (nil, CommandResult(exitCode: 1, stdout: Data(), stderr: Data("Nie zaimplementowano.\n".utf8)))
    }
}

/// What `Operations.screenAgentStatus` found on one iMac.
public struct ScreenAgentStatus: Equatable, Sendable {
    public enum Permission: String, Sendable { case granted, denied, unknown }
    public var installedVersion: String?
    public var loaded: Bool
    public var consoleUser: String?
    public var permission: Permission
    public var locked: Bool
    /// The agent did not answer (`ERR …` detail), `nil` when it did or nobody is logged in.
    public var error: String?

    public init(installedVersion: String?, loaded: Bool, consoleUser: String?, permission: Permission,
                locked: Bool, error: String?) {
        self.installedVersion = installedVersion
        self.loaded = loaded
        self.consoleUser = consoleUser
        self.permission = permission
        self.locked = locked
        self.error = error
    }

    public var isInstalled: Bool { installedVersion != nil }
    public var isCurrent: Bool { installedVersion == ScreenAgentInfo.version }
}
