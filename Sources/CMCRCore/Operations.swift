import Foundation

/// Multi-step operations shared by the app and the `cmcrctl` command line tool.
public enum Operations {
    public typealias Output = @Sendable (OutputChannel, Data) -> Void

    static func remoteTempPath() -> String {
        "/tmp/cmcr-up-\(UUID().uuidString.prefix(8).lowercased()).tar"
    }

    /// cmcr-push: upload a payload archive and unpack it into `destination`.
    public static func push(payload: URL, to host: Machine, destination: String, owner: String, mode: String,
                            asRoot: Bool, password: String?, settings: SSHSettings,
                            handle: ProcessHandle? = nil, onOutput: Output? = nil) async -> CommandResult {
        let remoteTar = remoteTempPath()
        onOutput?(.stdout, Data("→ Wysyłanie \(ByteCountFormatter.string(fromByteCount: Payload.size(of: payload), countStyle: .file))…\n".utf8))
        let up = await SSH.upload([payload], to: remoteTar, on: host, password: password, settings: settings, handle: handle)
        guard up.succeeded else { return up }
        return await SSH.run(Scripts.pushFinalize(remoteTar: remoteTar, destination: destination, owner: owner,
                                                  mode: mode, asRoot: asRoot),
                             on: host, password: password, settings: settings, handle: handle, onOutput: onOutput)
    }

    /// Uploads installers (.pkg/.dmg/.zip/.app) and installs them as root.
    public static func install(payload: URL, on host: Machine, password: String?, settings: SSHSettings,
                               handle: ProcessHandle? = nil, onOutput: Output? = nil) async -> CommandResult {
        let remoteTar = remoteTempPath()
        onOutput?(.stdout, Data("→ Wysyłanie instalatorów (\(ByteCountFormatter.string(fromByteCount: Payload.size(of: payload), countStyle: .file)))…\n".utf8))
        let up = await SSH.upload([payload], to: remoteTar, on: host, password: password, settings: settings, handle: handle)
        guard up.succeeded else { return up }
        return await SSH.run(Scripts.installPayload(remoteTar: remoteTar), on: host, password: password,
                             settings: settings, handle: handle, onOutput: onOutput)
    }

    /// cmcr-pull: fetch the contents of a remote folder into `localDirectory`.
    public static func pull(source: String, from host: Machine, into localDirectory: URL, asRoot: Bool,
                            password: String?, settings: SSHSettings,
                            handle: ProcessHandle? = nil, onOutput: Output? = nil) async -> CommandResult {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-pull-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = await SSH.run(Scripts.pullArchive(source: source, asRoot: asRoot), on: host, password: password,
                              settings: settings, stdoutFile: tmp, handle: handle, onOutput: onOutput)
        guard r.succeeded else { return r }
        do {
            try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure("Nie można utworzyć \(localDirectory.path): \(error.localizedDescription)")
        }
        let x = await ProcessRunner.run("/usr/bin/tar", ["-xf", tmp.path, "-C", localDirectory.path])
        guard x.succeeded else { return x }
        let ls = await ProcessRunner.run("/bin/ls", ["-l", localDirectory.path])
        onOutput?(.stdout, Data("Pobrano do \(localDirectory.path):\n".utf8) + ls.stdout)
        return CommandResult(exitCode: 0, stdout: ls.stdout, stderr: r.stderr)
    }

    public struct Screenshot: Sendable {
        public var imageData: Data?
        public var user: String?
        public var message: String?
    }

    /// Captures the screen of the logged-in user, honouring the observation restrictions.
    public static func screenshot(of host: Machine, maxSize: Int, settings appSettings: AppSettings, notify: Bool,
                                  password: String?, sshSettings: SSHSettings) async -> Screenshot {
        let script = Scripts.screenshot(maxSize: maxSize, quality: appSettings.screenshotQuality, notify: notify,
                                        onlyStandard: appSettings.observeOnlyStandardAccounts,
                                        allowedUsers: appSettings.observeAllowedUserList)
        let r = await SSH.run(script, on: host, password: password, settings: sshSettings, timeout: 45)
        let err = r.stderrText
        let user = err.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("CMCR:USER:") }
            .map { String($0.dropFirst("CMCR:USER:".count)) }
        if r.succeeded, !r.stdout.isEmpty {
            return Screenshot(imageData: r.stdout, user: user, message: nil)
        }
        let message: String
        switch r.exitCode {
        case ScriptCode.noConsoleUser:
            message = "Nikt nie jest zalogowany (okno logowania)."
        case ScriptCode.observeDenied:
            let who = err.split(whereSeparator: \.isNewline).first { $0.hasPrefix("CMCR:") }?
                .split(separator: ":").last.map(String.init) ?? "?"
            message = err.contains("CMCR:ADMIN")
                ? "Zalogowane konto administratora (\(who)) – podgląd zablokowany przez ograniczenia."
                : "Konto \(who) nie jest na liście kont dozwolonych do podglądu."
        case ScriptCode.captureFailed:
            message = "Zrzut ekranu nieudany. Na tym Macu nadaj uprawnienie „Nagrywanie ekranu” dla /usr/libexec/sshd-keygen-wrapper (Ustawienia › Prywatność i ochrona)."
        default:
            message = SSH.diagnose(r).1
        }
        return Screenshot(imageData: nil, user: user, message: message)
    }

    /// Local folder layout from README "Prepare files moving": ~/Public/cmcr/{all,<host>}.
    public static func prepareLocalFolders(base: String, hosts: [Machine]) throws -> URL {
        let root = URL(fileURLWithPath: expandTilde(base), isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("all"), withIntermediateDirectories: true)
        for h in hosts {
            try fm.createDirectory(at: root.appendingPathComponent(h.folderKey), withIntermediateDirectories: true)
        }
        return root
    }

    /// Items cmcr-push would send to a host: everything in `<base>/all` plus `<base>/<host>`.
    public static func conventionItems(base: String, host: Machine, includeAll: Bool = true) -> [URL] {
        let root = URL(fileURLWithPath: expandTilde(base), isDirectory: true)
        var dirs = [root.appendingPathComponent(host.folderKey)]
        if includeAll { dirs.insert(root.appendingPathComponent("all"), at: 0) }
        return dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent != ".DS_Store" }
        }
    }
}
