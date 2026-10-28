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
