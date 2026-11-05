import Foundation

/// CMCR Screen Agent on the iMacs: install/update, ask for the Screen Recording permission, status, removal
/// (docs/screen-agent.md). Every operation prints its own progress through `onOutput`; machine-readable lines
/// start with `CMCR:AGENT`.
public extension Operations {
    /// Uploads `agentApp` (a CMCR Screen Agent.app bundle) and installs or updates it as root. The same version
    /// already installed is left untouched (keeps the Screen Recording permission).
    static func installScreenAgent(on host: Machine, agentApp: URL, password: String?, settings: SSHSettings,
                                   handle: ProcessHandle? = nil, onOutput: Output? = nil) async -> CommandResult {
        let payload: URL
        switch await Payload.make([agentApp], handle: handle) {
        case .success(let url): payload = url
        case .failure(let error): return .failure(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: payload) }
        let remoteTar = remoteTempPath()
        let size = ByteCountFormatter.string(fromByteCount: Payload.size(of: payload), countStyle: .file)
        onOutput?(.stdout, Data("→ Wysyłanie usługi podglądu ekranu (\(size))…\n".utf8))
        let up = await SSH.upload([payload], to: remoteTar, on: host, password: password, settings: settings, handle: handle)
        guard up.succeeded else {
            if uploadMayHaveStarted(up) {
                await discardUpload(remoteTar, on: host, password: password, settings: settings)
            }
            return up
        }
        // Waits up to ~20 s per logged-in account for its agent to answer; a hung launchctl must not block forever.
        let r = await SSH.run(Scripts.installScreenAgent(remoteTar: remoteTar), on: host, password: password,
                              settings: settings, timeout: 240, handle: handle, onOutput: onOutput)
        if !r.succeeded { await discardUpload(remoteTar, on: host, password: password, settings: settings) }
        return r
    }

    /// Asks the agent in the logged-in user's session to request the Screen Recording permission (macOS shows its
    /// dialog at the iMac).
    static func requestScreenAgentPermission(on host: Machine, password: String?, settings: SSHSettings,
                                             handle: ProcessHandle? = nil, onOutput: Output? = nil) async -> CommandResult {
        await SSH.run(Scripts.requestScreenAgentPermission(), on: host, password: password, settings: settings,
                      timeout: 60, handle: handle, onOutput: onOutput)
    }

    /// Removes the agent, its LaunchAgent, sockets, screenshots and its TCC entry.
    static func removeScreenAgent(on host: Machine, password: String?, settings: SSHSettings,
                                  handle: ProcessHandle? = nil, onOutput: Output? = nil) async -> CommandResult {
        await SSH.run(Scripts.removeScreenAgent(), on: host, password: password, settings: settings,
                      timeout: 90, handle: handle, onOutput: onOutput)
    }

    /// Installed version, whether launchd has it in the console user's session, and the agent's own `ping` line.
    /// The status is `nil` only when the script did not report anything; without sudo it carries only the
    /// installed version (`permission` stays `.unknown`).
    static func screenAgentStatus(on host: Machine, password: String?, settings: SSHSettings,
                                  handle: ProcessHandle? = nil) async -> (ScreenAgentStatus?, CommandResult) {
        // Room for sudo, a ping, and – without the permission – a restart of the agent and a second ping.
        let r = await SSH.run(Scripts.screenAgentStatus(), on: host, password: password, settings: settings,
                              timeout: 60, handle: handle)
        let values = Parsers.keyValues(r.stdoutText)
        return (values["agent_installed"] == nil ? nil : ScreenAgentStatus.parse(values), r)
    }
}

/// What `Operations.screenAgentStatus` found on one iMac.
public struct ScreenAgentStatus: Equatable, Sendable {
    public enum Permission: String, Sendable { case granted, denied, unknown }
    public var installedVersion: String?
    /// launchd has the agent in the console user's session; `nil` when that part was not reported (no sudo for
    /// another account's session, or nobody logged in).
    public var loaded: Bool?
    public var consoleUser: String?
    public var permission: Permission
    public var locked: Bool
    /// The agent did not answer (`ERR …` detail), `nil` when it did or nobody is logged in.
    public var error: String?
    /// Why it did not answer: the `ERR` code of the client (`unreachable`, `untrusted`, `timeout`, `failed`, or the
    /// agent's own `noperm`/`locked`/…), `nil` when it answered.
    public var errorCode: String?
    /// Version of the agent that answered (`AGENT <version> …`) – the running copy, normally the installed one.
    public var runningVersion: String?
    /// The answering session is the one at the screen (not one left in the background by fast user switching).
    public var onConsole = true
    public var asleep = false

    public init(installedVersion: String?, loaded: Bool?, consoleUser: String?, permission: Permission,
                locked: Bool, error: String?) {
        self.installedVersion = installedVersion
        self.loaded = loaded
        self.consoleUser = consoleUser
        self.permission = permission
        self.locked = locked
        self.error = error
    }

    public var isInstalled: Bool { installedVersion != nil }
    /// The session at the screen was asked (as root or as that user): `agent_loaded`/`agent_ping` were reported.
    public var sessionChecked: Bool { loaded != nil }
    public var isCurrent: Bool { installedVersion == ScreenAgentInfo.version }

    /// Parses the `agent_*` lines shared by `Scripts.screenAgentStatus` and `Scripts.readiness`:
    /// `agent_installed=0|1`, `agent_version=X`, `agent_loaded=0|1`, `agent_ping=<AGENT … | ERR <code> <text>>`,
    /// `agent_ping_rc=N`, plus `console=<user>`. Unknown or missing values never fail the parse.
    public static func parse(_ v: [String: String]) -> ScreenAgentStatus {
        let installed = v["agent_installed"] == "1"
        let version = v["agent_version"].flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        let console = v["console"].flatMap { $0.isEmpty ? nil : $0 }
        let loaded = v["agent_loaded"].flatMap { $0 == "1" ? true : $0 == "0" ? false : nil }
        var status = ScreenAgentStatus(installedVersion: installed ? version : nil, loaded: loaded,
                                       consoleUser: console, permission: .unknown, locked: false, error: nil)
        guard let ping = v["agent_ping"].flatMap({ $0.isEmpty ? nil : $0 }) else { return status }
        let rc = v["agent_ping_rc"].flatMap { Int32($0) }
        if ping == "AGENT" || ping.hasPrefix("AGENT ") {
            var fields = ping.dropFirst("AGENT".count).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if let first = fields.first, !first.contains("=") {
                status.runningVersion = first
                fields.removeFirst()
            }
            var i = 0
            while i < fields.count {
                let f = fields[i]
                if f.hasPrefix("user=") {
                    // The name is the rest of the line (it may contain spaces).
                    let name = ([String(f.dropFirst("user=".count))] + fields[(i + 1)...]).joined(separator: " ")
                    if !name.isEmpty { status.consoleUser = name }
                    break
                }
                let kv = f.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    switch kv[0] {
                    case "perm": status.permission = Permission(rawValue: kv[1]) ?? .unknown
                    case "locked": status.locked = kv[1] == "1"
                    case "console": status.onConsole = kv[1] != "0"
                    case "asleep": status.asleep = kv[1] == "1"
                    default: break
                    }
                }
                i += 1
            }
            return status
        }
        // `ERR <code> <text>`, or anything else the client printed.
        var code: String?
        var text = ping
        if ping == "ERR" || ping.hasPrefix("ERR ") {
            let parts = ping.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            code = parts.count > 1 ? parts[1] : nil
            text = parts.count > 2 ? parts[2] : ""
        }
        switch rc {
        case ScreenAgentInfo.ClientCode.unreachable?: code = code ?? "unreachable"
        case ScreenAgentInfo.ClientCode.untrusted?: code = "untrusted"
        default: break
        }
        status.errorCode = code ?? "failed"
        let detail = text.trimmingCharacters(in: .whitespaces)
        status.error = detail.isEmpty ? (rc.map { "kod \($0)" } ?? "brak odpowiedzi") : detail
        return status
    }

    /// `parse` of key=value text.
    public static func parse(_ text: String) -> ScreenAgentStatus { parse(Parsers.keyValues(text)) }
}
