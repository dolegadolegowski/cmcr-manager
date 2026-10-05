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
        case badMAC(String), badAddress(String), socket(Int32)
        public var errorDescription: String? {
            switch self {
            case .badMAC(let m): return "Niepoprawny adres MAC: \(m)"
            case .badAddress(let a): return "Niepoprawny adres rozgłoszeniowy: \(a)"
            case .socket(let e) where e == EHOSTUNREACH || e == EPERM || e == EACCES:
                return "System nie pozwolił wysłać pakietu (\(String(cString: strerror(e)))). Zezwól aplikacji na dostęp do sieci lokalnej: Ustawienia systemowe › Prywatność i ochrona › Sieć lokalna."
            case .socket(let e): return "Błąd gniazda sieciowego: \(String(cString: strerror(e)))"
            }
        }
    }

    /// Accepts `aa:bb:cc:dd:ee:ff`, `aa-bb-…`, `aabb.ccdd.eeff`, `aabbccddeeff` and the unpadded form printed
    /// by `arp -a` (`0:1b:63:84:45:e6`).
    public static func parseMAC(_ mac: String) -> [UInt8]? {
        let trimmed = mac.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: { ":-".contains($0) })
        if parts.count == 6 {
            let bytes = parts.compactMap { p -> UInt8? in
                guard (1...2).contains(p.count), p.allSatisfy(\.isHexDigit) else { return nil }
                return UInt8(p, radix: 16)
            }
            return bytes.count == 6 ? bytes : nil
        }
        let hex = trimmed.filter { $0 != "." }
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
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

    /// Canonical lower-case `aa:bb:cc:dd:ee:ff`, or nil for an invalid address.
    public static func normalizeMAC(_ mac: String) -> String? {
        parseMAC(mac).map { $0.map { String(format: "%02x", $0) }.joined(separator: ":") }
    }

    /// Magic packet: 6×0xFF followed by the MAC repeated 16 times (102 bytes).
    public static func magicPacket(_ mac: [UInt8]) -> [UInt8] {
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += mac }
        return packet
    }

    /// The limited broadcast plus the directed broadcast of every active IPv4 interface. macOS sends
    /// 255.255.255.255 only through the primary interface, so a Mac on Wi-Fi + Ethernet needs both.
    public static func broadcastAddresses() -> [String] {
        var result = ["255.255.255.255"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let dst = ifa.pointee.ifa_dstaddr, dst.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var sin = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let text = String(cString: buf)
            if text != "0.0.0.0", !result.contains(text) { result.append(text) }
        }
        return result
    }

    /// Directed broadcast of the /24 network an address belongs to (`10.0.5.23` → `10.0.5.255`). Used as an
    /// extra target for Macs that were last seen in another subnet; routers usually drop it, but it is free.
    public static func subnetBroadcast(forIPv4 ip: String) -> String? {
        var a = in_addr()
        guard inet_pton(AF_INET, ip, &a) == 1 else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".") + ".255"
    }

    /// Sends one magic packet to one address and port.
    public static func send(mac: String, to address: String, port: UInt16) throws {
        guard let macBytes = parseMAC(mac) else { throw WOLError.badMAC(mac) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { throw WOLError.badAddress(address) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw WOLError.socket(errno) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        let packet = magicPacket(macBytes)
        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { throw WOLError.socket(errno) }
    }

    /// Sends magic packets for `mac` to the limited broadcast and every interface's directed broadcast
    /// (plus `extraBroadcasts`), on ports 9 and 7, `repeats` times. Returns the addresses that accepted the
    /// packet; throws only when nothing could be sent at all.
    @discardableResult
    public static func wake(mac: String, extraBroadcasts: [String] = [], ports: [UInt16] = [9, 7],
                            repeats: Int = 3) throws -> [String] {
        guard parseMAC(mac) != nil else { throw WOLError.badMAC(mac) }
        var targets = broadcastAddresses()
        for extra in extraBroadcasts where !targets.contains(extra) { targets.append(extra) }
        var delivered: [String] = []
        var lastError: Error?
        for round in 0..<max(1, repeats) {
            if round > 0 { usleep(100_000) }
            for address in targets {
                for port in ports {
                    do {
                        try send(mac: mac, to: address, port: port)
                        if !delivered.contains(address) { delivered.append(address) }
                    } catch {
                        lastError = error
                    }
                }
            }
        }
        if delivered.isEmpty, let lastError { throw lastError }
        return delivered
    }

    /// Single-address variant kept for callers of the original API.
    public static func wake(mac: String, broadcast: String, port: UInt16 = 9) throws {
        try send(mac: mac, to: broadcast, port: port)
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

    /// Removes a stale host key from ~/.ssh/known_hosts.
    public static func forgetHostKey(_ host: Machine) async -> CommandResult {
        let name = host.port == 22 ? host.address : "[\(host.address)]:\(host.port)"
        return await ProcessRunner.run("/usr/bin/ssh-keygen", ["-R", name])
    }
}
