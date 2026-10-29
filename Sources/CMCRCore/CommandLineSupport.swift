import Foundation

// Small helpers of cmcrctl that need CMCRCore internals (and stay testable there).

public extension ConfigStore {
    /// Keeps the current hosts.json as `hosts.json.<date>.bak` – the copy the app keeps of a damaged file – before
    /// cmcrctl replaces an unreadable list. nil when the file could not be read or copied: it must not be replaced then.
    static func backupHostsFile() -> URL? { backupHostsFile(at: hostsURL) }

    internal static func backupHostsFile(at url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return backupCopy(of: url, data: data)
    }
}

/// actions.log entries of cmcrctl, in the app's format „<co> → imac01, imac02” (AppModel.runBatch).
public enum CommandLineLog {
    /// The command line as typed, on one line: control characters escaped, arguments with spaces or shell characters
    /// quoted, long ones shortened, passwords in URLs (`https://konto:hasło@…`) hidden.
    public static func describe(_ arguments: [String], limit: Int = 120) -> String {
        arguments.map { argument in
            var text = TerminalText.escape(hidingURLPassword(argument), keepBackslash: true)
            if text.count > limit { text = String(text.prefix(max(1, limit - 1))) + "…" }
            let plain = !text.isEmpty && !text.contains { " \t'\"\\$`;&|<>(){}*?[]#~".contains($0) }
            return plain ? text : shQuote(text)
        }.joined(separator: " ")
    }

    /// „cmcrctl exec … → imac01, imac02”.
    public static func line(_ what: String, hosts: [String]) -> String {
        "\(what) → \(hosts.joined(separator: ", "))"
    }

    static func hidingURLPassword(_ text: String) -> String {
        guard let scheme = text.range(of: "://"),
              let at = text[scheme.upperBound...].prefix(while: { $0 != "/" }).lastIndex(of: "@") else { return text }
        return text[..<scheme.upperBound] + "***" + text[at...]
    }
}

public extension RemotePaths {
    /// Whether collecting students' work from `path` needs root, as for the app's „Zbierz prace” sources
    /// (FilesState.useCollectSource): an account's private folders (Desktop, Documents…) cannot be read by the
    /// administrator. The student's shared folder (cmcr) with its subfolders, /Users/Shared and the administrator's
    /// own home can; paths outside /Users (/tmp, /Volumes…) keep the caller's choice.
    static func collectNeedsRoot(_ path: String, settings s: AppSettings) -> Bool {
        let p = tokenize(path, studentUser: s.studentUser)
        let shared = tokenize(s.sharedFolder, studentUser: s.studentUser)
        guard p.hasPrefix("/Users/") else { return false }
        return !(p == shared || p.hasPrefix(shared + "/") || p == "/Users/Shared" || p.hasPrefix("/Users/Shared/"))
    }
}

public extension WakeOnLAN {
    /// Where Wake-on-LAN packets for a Mac go, in the app's order (ClassroomModel.wakeMACs): the Ethernet MAC the Mac
    /// reported last (`lastStatus`, e.g. from status-cache.json), the MAC on the host list, then – only when it reported
    /// no wired port – the MAC of its default route (`HostStatus.mac`). Normalised, without repeats.
    static func candidateMACs(listed: String, lastStatus info: [String: String]) -> [String] {
        var status = HostStatus()
        status.info = info
        var out: [String] = []
        for candidate in [status.ethernetMAC, listed, status.mac] {
            guard let c = candidate, let mac = normalizeMAC(c), !out.contains(mac) else { continue }
            out.append(mac)
        }
        return out
    }

    /// The directed broadcast of the subnet the Mac was last seen in, an extra target besides this Mac's own
    /// networks (as in the app); empty when its address is not known.
    static func lastSeenBroadcasts(_ info: [String: String]) -> [String] {
        var status = HostStatus()
        status.info = info
        return status.ip.flatMap(subnetBroadcast(forIPv4:)).map { [$0] } ?? []
    }
}
