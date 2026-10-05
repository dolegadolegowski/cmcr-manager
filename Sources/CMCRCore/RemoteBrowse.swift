import Foundation

/// One item of a remote folder listing.
public struct RemoteEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case directory, file, symlink, other
    }

    public var name: String
    public var kind: Kind
    public var size: Int64
    public var modified: Date
    public var owner: String
    public var group: String
    /// Permission bits, e.g. `0o755`.
    public var permissions: Int
    /// BSD file flags reported by `stat` (`hidden`, `uchg`, …).
    public var flags: [String]
    public var linkTarget: String?
    /// For symbolic links: the link points to a folder.
    public var pointsToDirectory: Bool

    public init(name: String, kind: Kind, size: Int64 = 0, modified: Date = Date(timeIntervalSince1970: 0),
                owner: String = "", group: String = "", permissions: Int = 0o644, flags: [String] = [],
                linkTarget: String? = nil, pointsToDirectory: Bool = false) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.owner = owner
        self.group = group
        self.permissions = permissions
        self.flags = flags
        self.linkTarget = linkTarget
        self.pointsToDirectory = pointsToDirectory
    }

    public var id: String { name }

    /// Hidden in Finder: dot-files and items with the `hidden` flag (e.g. ~/Library).
    public var isHidden: Bool { name.hasPrefix(".") || flags.contains("hidden") }

    public var isSymlink: Bool { kind == .symlink }

    /// A folder or a link to a folder that can be opened (app bundles and other packages are not).
    public var isFolder: Bool {
        (kind == .directory || (kind == .symlink && pointsToDirectory)) && !isPackage
    }

    /// Bundles that Finder shows as a single file.
    public var isPackage: Bool {
        guard kind == .directory || (kind == .symlink && pointsToDirectory) else { return false }
        return Self.packageExtensions.contains(fileExtension)
    }

    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    /// `rwxr-xr-x`
    public var permissionString: String {
        let chars = Array("rwxrwxrwx")
        return String((0..<9).map { permissions & (0o400 >> $0) != 0 ? chars[$0] : "-" })
    }

    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "rtfd", "photoslibrary", "musiclibrary",
        "xcodeproj", "xcworkspace", "playground", "pages", "numbers", "key", "logicx", "band", "fcpbundle",
        "imovielibrary", "theater", "scptd", "mpkg", "pkg", "prefpane", "saver", "qlgenerator", "mdimporter",
    ]
}

/// Contents of one remote folder as returned by `Scripts.listDirectory`.
public struct RemoteListing: Sendable {
    /// Folder with placeholders resolved, as requested (symbolic links kept).
    public var path: String
    /// Physical location (all symbolic links resolved).
    public var physicalPath: String
    /// The account the listing ran as may create files here.
    public var writable: Bool
    public var owner: String
    public var group: String
    public var permissions: Int
    /// Administrator account used for the SSH connection.
    public var adminUser: String
    public var adminHome: String
    public var consoleUser: String?
    /// The listing was made with root privileges.
    public var asRoot: Bool
    /// Number of entries in the folder (may exceed `entries.count` for very large folders).
    public var total: Int
    public var entries: [RemoteEntry]
    /// The stream ended with its end marker (it was not cut off).
    public var complete: Bool

    public init(path: String, physicalPath: String = "", writable: Bool = true, owner: String = "",
                group: String = "", permissions: Int = 0o755, adminUser: String = "", adminHome: String = "",
                consoleUser: String? = nil, asRoot: Bool = false, total: Int = 0, entries: [RemoteEntry] = [],
                complete: Bool = true) {
        self.path = path
        self.physicalPath = physicalPath.isEmpty ? path : physicalPath
        self.writable = writable
        self.owner = owner
        self.group = group
        self.permissions = permissions
        self.adminUser = adminUser
        self.adminHome = adminHome
        self.consoleUser = consoleUser
        self.asRoot = asRoot
        self.total = total
        self.entries = entries
        self.complete = complete
    }

    public var truncated: Bool { total > entries.count }
}

/// Why a remote browser operation failed, in terms a teacher can act on.
public enum RemoteBrowseError: Error, Equatable, Sendable, LocalizedError {
    case notFound(String)
    case notDirectory(String)
    case accessDenied(String)
    case privacyDenied(String)
    case noConsoleUser
    case refused(String)
    case exists(String)
    case unreachable(String)
    case authentication(String)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let m), .notDirectory(let m), .accessDenied(let m), .privacyDenied(let m), .refused(let m),
             .exists(let m), .unreachable(let m), .authentication(let m), .failed(let m):
            return m
        case .noConsoleUser:
            return "Nikt nie jest zalogowany – folder zalogowanego użytkownika jest niedostępny."
        case .cancelled:
            return "Anulowano."
        }
    }

    /// Interprets the result of a browser script.
    public static func from(_ r: CommandResult) -> RemoteBrowseError {
        if r.cancelled { return .cancelled }
        let message = r.stderrText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("CMCR:") }
            .joined(separator: "\n")
        let text = message.isEmpty ? "Polecenie zakończone kodem \(r.exitCode)." : message
        switch r.exitCode {
        case BrowseCode.notFound: return .notFound(text)
        case BrowseCode.notDirectory: return .notDirectory(text)
        case BrowseCode.accessDenied: return .accessDenied(text)
        case BrowseCode.privacyDenied: return .privacyDenied(text)
        case BrowseCode.refused: return .refused(text)
        case BrowseCode.exists: return .exists(text)
        case ScriptCode.noConsoleUser where r.stderrText.contains("CMCR:NO_CONSOLE"): return .noConsoleUser
        default: break
        }
        let (reach, diagnosis) = SSH.diagnose(r)
        switch reach {
        case .offline: return .unreachable(diagnosis)
        case .authFailed: return .authentication(diagnosis)
        case .error: return .failed(diagnosis)
        default:
            if r.exitCode == 91 || diagnosis.hasPrefix("Błędne hasło") { return .authentication(diagnosis) }
            return .failed(message.isEmpty ? diagnosis : message)
        }
    }
}

public extension Parsers {
    /// Parses the NUL-separated record stream printed by `Scripts.listDirectory`.
    static func remoteListing(_ data: Data) -> RemoteListing? {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if tokens.last == "" { tokens.removeLast() }
        guard let start = tokens.firstIndex(of: "CMCR-LISTING") else { return nil }
        var listing = RemoteListing(path: "")
        listing.complete = false
        var euid = ""
        var i = start + 2
        func next() -> String? {
            guard i < tokens.count else { return nil }
            defer { i += 1 }
            return tokens[i]
        }
        while let key = next() {
            switch key {
            case "PATH": listing.path = next() ?? ""
            case "REAL": listing.physicalPath = next() ?? ""
            case "WRITABLE": listing.writable = next() == "1"
            case "USER": listing.adminUser = next() ?? ""
            case "EUID": euid = next() ?? ""
            case "CONSOLE": listing.consoleUser = next().flatMap { $0.isEmpty ? nil : $0 }
            case "HOME": listing.adminHome = next() ?? ""
            case "TOTAL": listing.total = Int(next() ?? "") ?? 0
            case "SELF":
                listing.owner = next() ?? ""
                listing.group = next() ?? ""
                listing.permissions = Int(next() ?? "", radix: 8) ?? 0
            case "ENTRY":
                guard i + 10 <= tokens.count else { i = tokens.count; break }
                let f = Array(tokens[i..<(i + 10)])
                i += 10
                guard !f[8].isEmpty else { continue }
                let kind: RemoteEntry.Kind
                switch f[0] {
                case "Directory": kind = .directory
                case "Regular File": kind = .file
                case "Symbolic Link": kind = .symlink
                default: kind = .other
                }
                listing.entries.append(RemoteEntry(
                    name: f[8], kind: kind, size: Int64(f[1]) ?? 0,
                    modified: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0),
                    owner: f[3], group: f[4], permissions: Int(f[5], radix: 8) ?? 0,
                    flags: f[6] == "-" ? [] : f[6].split(separator: ",").map(String.init),
                    linkTarget: kind == .symlink ? f[9] : nil, pointsToDirectory: f[7] == "1"))
            case "END":
                listing.complete = true
            default:
                break
            }
        }
        if listing.physicalPath.isEmpty { listing.physicalPath = listing.path }
        listing.asRoot = euid == "0"
        listing.total = max(listing.total, listing.entries.count)
        return listing.path.isEmpty ? nil : listing
    }
}

/// A well-known place on the iMacs, written with placeholders so it means the same on every Mac.
public struct RemoteFolder: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var path: String
    public var icon: String

    public init(id: String, title: String, path: String, icon: String) {
        self.id = id
        self.title = title
        self.path = path
        self.icon = icon
    }
}

/// Remote path helpers: placeholders (`{student}`, `{console}`, `~`), friendly names and breadcrumbs.
public enum RemotePaths {
    public static let student = "/Users/{student}"
    public static let console = "/Users/{console}"
    public static let adminHome = "~"

    /// Favourite places shown in the folder picker and the file browser.
    public static func favorites(_ s: AppSettings) -> [RemoteFolder] {
        [
            RemoteFolder(id: "cmcr", title: "Folder cmcr ucznia", path: tokenize(s.sharedFolder, studentUser: s.studentUser),
                         icon: "folder.badge.person.crop"),
            RemoteFolder(id: "desktop", title: "Biurko ucznia", path: student + "/Desktop", icon: "menubar.dock.rectangle"),
            RemoteFolder(id: "documents", title: "Dokumenty ucznia", path: student + "/Documents", icon: "doc"),
            RemoteFolder(id: "downloads", title: "Pobrane ucznia", path: student + "/Downloads", icon: "arrow.down.circle"),
            RemoteFolder(id: "studentHome", title: "Katalog domowy ucznia", path: student, icon: "house"),
            RemoteFolder(id: "consoleDesktop", title: "Biurko zalogowanego użytkownika", path: console + "/Desktop",
                         icon: "person.crop.rectangle"),
            RemoteFolder(id: "usersShared", title: "Wspólny folder (Shared)", path: "/Users/Shared", icon: "person.2"),
            RemoteFolder(id: "applications", title: "Programy", path: "/Applications", icon: "square.grid.2x2"),
            RemoteFolder(id: "adminHome", title: "Katalog domowy administratora", path: adminHome, icon: "person.badge.key"),
        ]
    }

    /// Places that are not favourites but still get a friendly name.
    static func extraNames(_ s: AppSettings) -> [RemoteFolder] {
        [
            RemoteFolder(id: "consoleHome", title: "Katalog zalogowanego użytkownika", path: console, icon: "person.crop.circle"),
            RemoteFolder(id: "root", title: "Dysk systemowy", path: "/", icon: "internaldrive"),
        ]
    }

    /// Turns a concrete path into its placeholder form, so it can be used on every Mac:
    /// `/Users/<student>/…` → `/Users/{student}/…`, `/Users/<console user>/…` → `/Users/{console}/…` (when
    /// `preferConsole`), the administrator's home → `~`.
    public static func tokenize(_ path: String, studentUser: String, consoleUser: String? = nil,
                                preferConsole: Bool = false, adminHome: String? = nil) -> String {
        let p = normalize(path)
        func replacing(_ prefix: String, with token: String) -> String? {
            guard !prefix.isEmpty, prefix != "/" else { return nil }
            if p == prefix { return token }
            if p.hasPrefix(prefix + "/") { return token + p.dropFirst(prefix.count) }
            return nil
        }
        if preferConsole, let c = consoleUser, !c.isEmpty, let r = replacing("/Users/" + c, with: console) { return r }
        if !studentUser.isEmpty, let r = replacing("/Users/" + studentUser, with: student) { return r }
        if let home = adminHome.map(normalize), let r = replacing(home, with: Self.adminHome) { return r }
        return p
    }

    /// Substitutes the placeholders that can be resolved locally (`{student}`).
    public static func resolveLocal(_ path: String, studentUser: String) -> String {
        path.replacingOccurrences(of: "{student}", with: studentUser)
    }

    /// Like `resolveLocal`, plus `{console}` and `~` with the values of one Mac (from its listing).
    public static func resolve(_ path: String, studentUser: String, consoleUser: String?, adminHome: String?) -> String {
        var p = resolveLocal(path, studentUser: studentUser)
        if let c = consoleUser, !c.isEmpty { p = p.replacingOccurrences(of: "{console}", with: c) }
        if let home = adminHome, !home.isEmpty {
            if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        }
        return normalize(p)
    }

    /// Removes trailing slashes and duplicate separators.
    public static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let parts = path.split(separator: "/").map(String.init)
        return (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
    }

    public static func join(_ folder: String, _ name: String) -> String {
        let f = normalize(folder)
        return f == "/" ? "/" + name : f + "/" + name
    }

    public static func parent(of path: String) -> String {
        let p = normalize(path)
        if p == "/" || p == "~" || !p.contains("/") { return p }
        let up = (p as NSString).deletingLastPathComponent
        return up.isEmpty ? "/" : up
    }

    public static func lastComponent(_ path: String) -> String {
        let p = normalize(path)
        return p == "/" ? "/" : (p as NSString).lastPathComponent
    }

    /// A name a new file or folder may have.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && name.utf8.count <= 255
    }

    /// Breadcrumbs from the root to `path`: `[("/", "/"), ("Users", "/Users"), …]`.
    public static func breadcrumbs(_ path: String) -> [(name: String, path: String)] {
        let p = normalize(path)
        guard p.hasPrefix("/") else { return [(p, p)] }
        var out: [(String, String)] = [("/", "/")]
        var current = ""
        for part in p.split(separator: "/") {
            current += "/" + part
            out.append((String(part), current))
        }
        return out
    }

    /// Friendly description of a placeholder path: `/Users/{student}/Desktop/Projekty` → `Biurko ucznia › Projekty`.
    public static func friendlyName(_ path: String, settings s: AppSettings) -> (title: String, icon: String) {
        let p = tokenize(path, studentUser: s.studentUser)
        guard !p.isEmpty else { return ("Nie wybrano folderu", "questionmark.folder") }
        let known = favorites(s) + extraNames(s)
        let match = known
            .filter { p == $0.path || ($0.path != "/" && p.hasPrefix($0.path + "/")) }
            .max { $0.path.count < $1.path.count }
        if let base = match {
            let rest = p == base.path ? "" : String(p.dropFirst(base.path.count + 1))
            let tail = rest.split(separator: "/").joined(separator: " › ")
            return (tail.isEmpty ? base.title : base.title + " › " + tail, base.icon)
        }
        if p == "/" { return ("Dysk systemowy", "internaldrive") }
        return (lastComponent(p), "folder")
    }

    /// `true` when the path depends on the Mac it is used on in a way the teacher should know about.
    public static func usesConsoleUser(_ path: String) -> Bool { path.contains("{console}") }
}
