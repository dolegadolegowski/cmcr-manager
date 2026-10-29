import Foundation

/// The quarantine attribute (`com.apple.quarantine`) on files that come from the iMacs: whatever a student left in
/// a folder (an app named „Praca.pdf.app”, a `.command` script) is checked by Gatekeeper before it can run on the
/// teacher's account, which holds the SSH key for every iMac and the administrator passwords.
public enum Quarantine {
    static let attribute = "com.apple.quarantine"

    /// Marks `url` like a file downloaded from the internet. macOS's tar copies the mark of an archive to every item
    /// it unpacks, so marking the archive is enough. Returns false when the mark could not be set.
    @discardableResult
    public static func mark(_ url: URL, agent: String = "CMCR Manager") -> Bool {
        var marked = url
        var values = URLResourceValues()
        values.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeOtherDownload", "LSQuarantineAgentName": agent]
        if (try? marked.setResourceValues(values)) != nil, isMarked(url.path) { return true }
        // The same mark written directly: flags 0x0001 (downloaded), the time and the agent.
        let value = "0001;\(String(Int(Date().timeIntervalSince1970), radix: 16));\(agent);"
        let ok = value.withCString { setxattr(url.path, attribute, $0, strlen($0), 0, 0) == 0 }
        return ok && isMarked(url.path)
    }

    public static func isMarked(_ path: String) -> Bool {
        getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW) > 0
    }
}
