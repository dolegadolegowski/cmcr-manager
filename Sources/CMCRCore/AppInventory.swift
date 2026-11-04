import Foundation

/// One application on an iMac, from `Scripts.appInventory` (`CMCR:APP` records).
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Installed by a teacher or a student (a .pkg, a .dmg, a copy).
        case app
        /// From the Mac App Store (has _MASReceipt).
        case appStore = "appstore"
        /// Apple's own (com.apple.*): Pages, GarageBand, Xcode… – never removed by CMCR.
        case apple
        /// macOS itself (/System, the SIP flag): never removable.
        case system
        /// CMCR's own component (pl.cmcr.*).
        case cmcr
        /// A Unity editor version installed by Unity Hub (/Applications/Unity/Hub/Editor/<version>).
        case unity
    }

    public var path: String
    /// apps, utilities, folder, user:<account>, unity, system.
    public var location: String
    public var kind: Kind
    public var bundleID: String
    public var version: String
    /// KB on disk; nil when unknown (Unity editors, or no time left for `du` on a Mac without Spotlight).
    public var sizeKB: Int64?
    /// Package receipts (pkgutil) that installed it.
    public var receipts: [String]
    public var id: String { path }

    public init(path: String, location: String, kind: Kind, bundleID: String = "", version: String = "",
                sizeKB: Int64? = nil, receipts: [String] = []) {
        self.path = path
        self.location = location
        self.kind = kind
        self.bundleID = bundleID
        self.version = version
        self.sizeKB = sizeKB
        self.receipts = receipts
    }

    /// "Blender", or "Unity 6000.3.7f1" for an editor version.
    public var name: String {
        if kind == .unity { return "Unity \(version)" }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The folder it is in.
    public var folder: String { (path as NSString).deletingLastPathComponent }

    /// The account whose ~/Applications it is in.
    public var user: String? { location.hasPrefix("user:") ? String(location.dropFirst(5)) : nil }

    /// What `Scripts.uninstallApps` removes: the bundle, or the whole version folder of a Unity editor.
    public var removalPath: String { kind == .unity ? folder : path }

    public var isRemovable: Bool { reasonNotRemovable == nil }

    /// Why CMCR does not offer to uninstall it (the script refuses it as well).
    public var reasonNotRemovable: String? {
        switch kind {
        case .system: return "Aplikacja systemowa macOS – chroni ją System Integrity Protection, nie można jej odinstalować."
        case .apple: return "Aplikacja Apple – CMCR nie odinstalowuje aplikacji Apple; w razie potrzeby usuń ją przy komputerze lub przez MDM."
        case .cmcr: return "Składnik CMCR – nie odinstalowuje się go zdalnie."
        case .app, .appStore, .unity:
            return location == "system" ? "Aplikacja systemowa macOS – nie można jej odinstalować." : nil
        }
    }

    /// What the teacher should know before removing it (special uninstallers).
    public var uninstallNote: String? {
        switch kind {
        case .appStore:
            return "Z App Store: jeśli przydziela ją szkoła przez MDM (Apple School Manager), może wrócić – usuń najpierw przydział w MDM."
        case .unity:
            return "Edytor z Unity Hub: usuwany jest cały folder tej wersji razem z modułami (np. Android)."
        default:
            if bundleID.hasPrefix("com.adobe.") { return "Programy Adobe usuwaj przez Creative Cloud – po samej aplikacji zostają usługi Adobe." }
            return nil
        }
    }

    /// "Aplikacje", "Aplikacje › Narzędzia", "Aplikacje › Blender", "Aplikacje ucznia (uczen)", "Unity Hub", "macOS".
    public var locationLabel: String {
        switch location {
        case "apps": return "Aplikacje"
        case "utilities": return "Aplikacje › Narzędzia"
        case "folder": return "Aplikacje › \((folder as NSString).lastPathComponent)"
        case "unity": return "Unity Hub"
        case "system": return "macOS"
        default:
            if let user {
                let home = "/\(user)/Applications"
                return folder.hasSuffix(home) ? "Aplikacje konta \(user)"
                    : "Aplikacje konta \(user) › \((folder as NSString).lastPathComponent)"
            }
            return location
        }
    }

    public var kindLabel: String {
        switch kind {
        case .app: return ""
        case .appStore: return "App Store"
        case .apple: return "Apple"
        case .system: return "systemowa"
        case .cmcr: return "CMCR"
        case .unity: return "Unity Hub"
        }
    }
}

/// A package receipt not from Apple (`pkgutil --pkgs`), from `Scripts.appInventory(receipts: true)`.
public struct InstalledPackage: Identifiable, Hashable, Sendable {
    public var id: String
    public var version: String
    public var installed: Date?
    /// Install location from the receipt ("/" or e.g. "Applications").
    public var location: String

    public init(id: String, version: String = "", installed: Date? = nil, location: String = "") {
        self.id = id
        self.version = version
        self.installed = installed
        self.location = location
    }
}

/// Everything one Mac reported.
public struct HostInventory: Sendable {
    public var apps: [InstalledApp] = []
    public var packages: [InstalledPackage] = []
    /// Enrolled in MDM (`profiles status -type enrollment`); nil when unknown.
    public var mdmEnrolled: Bool?
    /// The list ended with its closing record (not cut short).
    public var complete = false
    public var updatedAt = Date()

    public init(apps: [InstalledApp] = [], packages: [InstalledPackage] = [], mdmEnrolled: Bool? = nil,
                complete: Bool = false) {
        self.apps = apps
        self.packages = packages
        self.mdmEnrolled = mdmEnrolled
        self.complete = complete
    }
}

public enum AppInventory {
    /// Parses `Scripts.appInventory` output; other lines are ignored. Apps are sorted by name.
    public static func parse(_ text: String) -> HostInventory {
        var inv = HostInventory()
        for raw in text.split(whereSeparator: \.isNewline) {
            let f = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let tag = f.first else { continue }
            switch tag {
            case "CMCR:APP" where f.count >= 8:
                guard let kind = InstalledApp.Kind(rawValue: f[2]), f[3].hasPrefix("/") else { continue }
                inv.apps.append(InstalledApp(path: f[3], location: f[1], kind: kind, bundleID: f[4], version: f[5],
                                             sizeKB: Int64(f[6]),
                                             receipts: f[7].split(separator: ",").map(String.init)))
            case "CMCR:PKG" where f.count >= 5:
                inv.packages.append(InstalledPackage(id: f[1], version: f[2],
                                                     installed: TimeInterval(f[3]).map { Date(timeIntervalSince1970: $0) },
                                                     location: f[4]))
            case "CMCR:MDM" where f.count >= 2:
                inv.mdmEnrolled = f[1] == "yes" ? true : f[1] == "no" ? false : nil
            case "CMCR:END":
                inv.complete = true
            default:
                continue
            }
        }
        inv.apps.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        inv.packages.sort { $0.id < $1.id }
        return inv
    }

    /// "120 MB", "10,2 GB"; "—" when unknown.
    public static func sizeText(_ kb: Int64?) -> String {
        guard let kb else { return "—" }
        return ByteCountFormatter.string(fromByteCount: kb * 1024, countStyle: .file)
    }
}
