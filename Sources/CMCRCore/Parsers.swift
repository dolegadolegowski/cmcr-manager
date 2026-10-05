import Foundation

public enum Parsers {
    /// Parses `key=value` lines printed by `Scripts.status()`.
    public static func keyValues(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            out[key] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Top-level application bundle for an executable path, e.g.
    /// `/Applications/Safari.app/Contents/MacOS/Safari` → `/Applications/Safari.app`.
    /// Helper apps nested inside other bundles are ignored.
    public static func appBundle(forExecutable path: String) -> String? {
        guard let r = path.range(of: ".app/Contents/MacOS/") else { return nil }
        let bundle = String(path[..<r.lowerBound]) + ".app"
        if bundle.dropLast(4).contains(".app/") { return nil }
        if path[r.upperBound...].contains("/") { return nil }
        return bundle
    }

    /// Parses `Scripts.runningApps()` output.
    public static func runningApps(_ text: String) -> (user: String?, apps: [RunningApp]) {
        var user: String?
        var apps: [RunningApp] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("USER:") {
                let u = String(line.dropFirst(5))
                user = u.isEmpty ? nil : u
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]) else { continue }
            let path = parts[2].trimmingCharacters(in: .whitespaces)
            guard let bundle = appBundle(forExecutable: path), !seen.contains(bundle) else { continue }
            seen.insert(bundle)
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            apps.append(RunningApp(pid: pid, name: name, bundlePath: bundle))
        }
        apps.sort { ($0.isSystem ? 1 : 0, $0.name.lowercased()) < ($1.isSystem ? 1 : 0, $1.name.lowercased()) }
        return (user, apps)
    }

    public static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.isEmpty }
    }

    /// Titles of pending updates from `softwareupdate --list`.
    public static func softwareUpdates(_ text: String) -> [String] {
        var titles: [String] = []
        var lastLabel: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") {
                if let l = lastLabel { titles.append(l) }
                lastLabel = line.replacingOccurrences(of: "* Label:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Title:"), lastLabel != nil {
                let title = line.dropFirst("Title:".count).split(separator: ",").first.map(String.init) ?? ""
                let restart = line.contains("Action: restart") ? " (wymaga restartu)" : ""
                titles.append(title.trimmingCharacters(in: .whitespaces) + restart)
                lastLabel = nil
            }
        }
        if let l = lastLabel { titles.append(l) }
        return titles
    }
}

public enum WakeOnLAN {
    public enum WOLError: LocalizedError {
        case badMAC(String), socket(Int32)
        public var errorDescription: String? {
            switch self {
            case .badMAC(let m): return "Niepoprawny adres MAC: \(m)"
            case .socket(let e): return "Błąd gniazda sieciowego: \(String(cString: strerror(e)))"
            }
        }
    }

    public static func parseMAC(_ mac: String) -> [UInt8]? {
        let hex = mac.filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return bytes
    }

    /// Sends a magic packet (6×0xFF + 16×MAC) as UDP broadcast on port 9.
    public static func wake(mac: String, broadcast: String = "255.255.255.255", port: UInt16 = 9) throws {
        guard let macBytes = parseMAC(mac) else { throw WOLError.badMAC(mac) }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += macBytes }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw WOLError.socket(errno) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(broadcast)
        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { throw WOLError.socket(errno) }
    }
}

/// Local SSH key helpers (README: "Distribute your SSH key").
public enum SSHKeys {
    public static var sshDir: URL { URL(fileURLWithPath: expandTilde("~/.ssh"), isDirectory: true) }

    /// Private key the app will use: configured one, or the first existing default key.
    public static func currentPrivateKey(settings: AppSettings) -> URL? {
        if !settings.identityFile.isEmpty {
            let url = URL(fileURLWithPath: expandTilde(settings.identityFile))
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        for name in ["id_ed25519", "id_rsa", "id_ecdsa"] {
            let url = sshDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public static func publicKey(for privateKey: URL) -> String? {
        try? String(contentsOf: URL(fileURLWithPath: privateKey.path + ".pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `ssh-keygen -t ed25519` without a passphrase (the repo uses `ssh-keygen -t rsa` with defaults).
    public static func generate(type: String = "ed25519") async -> CommandResult {
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let path = sshDir.appendingPathComponent("id_\(type)").path
        if FileManager.default.fileExists(atPath: path) {
            return .failure("Klucz \(path) już istnieje.", code: 1)
        }
        return await ProcessRunner.run("/usr/bin/ssh-keygen",
                                       ["-t", type, "-N", "", "-f", path, "-C", "cmcr-manager@\(ProcessInfo.processInfo.hostName)"])
    }

    /// Removes a stale host key from ~/.ssh/known_hosts (or the files set with `UserKnownHostsFile`).
    /// The shared connection to the Mac is closed first, so the next session checks the new key.
    public static func forgetHostKey(_ host: Machine, settings: SSHSettings? = nil) async -> CommandResult {
        let name = host.port == 22 ? host.address : "[\(host.address)]:\(host.port)"
        guard let settings else { return await ProcessRunner.run("/usr/bin/ssh-keygen", ["-R", name]) }
        await SSH.closeMaster(host, settings: settings)
        let files = SSH.knownHostsFiles(settings)
        if files.isEmpty { return await ProcessRunner.run("/usr/bin/ssh-keygen", ["-R", name]) }
        var result = CommandResult(exitCode: 0)
        for file in files where FileManager.default.fileExists(atPath: file) {
            let r = await ProcessRunner.run("/usr/bin/ssh-keygen", ["-R", name, "-f", file])
            result.stdout += r.stdout
            result.stderr += r.stderr
            if r.exitCode != 0 { result.exitCode = r.exitCode }
        }
        return result
    }
}
