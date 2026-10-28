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
