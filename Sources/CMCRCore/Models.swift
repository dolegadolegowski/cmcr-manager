import Foundation

/// One managed Mac. Defaults follow cmcr-helpers.sh: admin account `imacNN` on host `imacNN.local`.
public struct Machine: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    public var user: String
    public var port: Int
    public var macAddress: String
    public var notes: String
    /// When false the host uses its own password from the Keychain instead of the shared one.
    public var usesSharedPassword: Bool
    /// Named groups (rows, rooms, classes) used to filter and select hosts.
    public var groups: [String] = []

    public init(id: UUID = UUID(), name: String, address: String, user: String, port: Int = 22,
                macAddress: String = "", notes: String = "", usesSharedPassword: Bool = true, groups: [String] = []) {
        self.id = id
        self.name = name
        self.address = address
        self.user = user
        self.port = port
        self.macAddress = macAddress
        self.notes = notes
        self.usesSharedPassword = usesSharedPassword
        self.groups = groups
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        address = try c.decode(String.self, forKey: .address)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? address
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? NSUserName()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        usesSharedPassword = try c.decodeIfPresent(Bool.self, forKey: .usesSharedPassword) ?? true
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
    }

    /// `user@host` as used by ssh/scp.
    public var destination: String { "\(user)@\(address)" }

    /// Name of the per-host local folder (cmcr-helpers uses the host name, e.g. `imac04.local`).
    public var folderKey: String { address }

    /// Mirrors the loop at the top of cmcr-helpers.sh (imac01…imac15 @ imacNN.local).
    public static func generate(prefix: String = "imac", start: Int = 1, count: Int = 15,
                                digits: Int = 2, domain: String = "local") -> [Machine] {
        guard count > 0 else { return [] }
        return (start..<(start + count)).map { i in
            let user = prefix + String(format: "%0\(max(1, digits))d", i)
            let address = domain.isEmpty ? user : "\(user).\(domain)"
            return Machine(name: user, address: address, user: user)
        }
    }

    /// Number embedded in the host name (`imac04` → 4); used by the CLI like `cmcr-exec cmd 4`.
    public var number: Int? {
        let digits = name.reversed().prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(String(digits.reversed()))
    }
}

public struct Snippet: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var category: String
    public var name: String
    public var command: String
    public var asRoot: Bool

    public init(id: UUID = UUID(), category: String, name: String, command: String, asRoot: Bool = false) {
        self.id = id
        self.category = category
        self.name = name
        self.command = command
        self.asRoot = asRoot
    }
}

public extension Snippet {
    static let unityHub = "\"/Applications/Unity Hub.app/Contents/MacOS/Unity Hub\""

    /// Commands collected in cmcr-helpers (README.md and notes.md) plus everyday admin checks.
    static let builtIn: [Snippet] = [
        Snippet(category: "Podstawowe", name: "Kim jestem i katalog domowy (README)", command: "whoami; ls -l ~/"),
        Snippet(category: "Podstawowe", name: "Wolne miejsce na dysku (README)", command: "df -h"),
        Snippet(category: "Podstawowe", name: "Czas pracy i obciążenie", command: "uptime"),
        Snippet(category: "Podstawowe", name: "Wersja macOS", command: "sw_vers"),
        Snippet(category: "Podstawowe", name: "Zalogowany użytkownik", command: "stat -f%Su /dev/console"),
        Snippet(category: "Podstawowe", name: "Konta użytkowników", command: "dscl . list /Users UniqueID | awk '$2 >= 500'"),
        Snippet(category: "Podstawowe", name: "Zawartość folderu cmcr ucznia", command: "ls -la /Users/student/Public/cmcr"),
        Snippet(category: "Unity Hub (notes.md)", name: "Lista zainstalowanych edytorów",
                command: "\(unityHub) -- --headless editors --all"),
        Snippet(category: "Unity Hub (notes.md)", name: "Instalacja edytora 6000.3.7f1",
                command: "\(unityHub) -- --headless install --version 6000.3.7f1"),
        Snippet(category: "Unity Hub (notes.md)", name: "Moduł Android dla 6000.3.7f1",
                command: "\(unityHub) -- --headless install-modules --version 6000.3.7f1 -m android"),
        Snippet(category: "Android SDK (notes.md)", name: "sdkmanager – API 32",
                command: "yes | /Applications/Unity/Hub/Editor/6000.3.7f1/PlaybackEngines/AndroidPlayer/SDK/cmdline-tools/16.0/bin/sdkmanager \"platform-tools\" \"platforms;android-32\""),
        Snippet(category: "Android SDK (notes.md)", name: "sdkmanager – API 34",
                command: "yes | /Applications/Unity/Hub/Editor/6000.3.7f1/PlaybackEngines/AndroidPlayer/SDK/cmdline-tools/16.0/bin/sdkmanager \"platform-tools\" \"platforms;android-34\""),
        Snippet(category: "Homebrew (notes.md)", name: "Instalacja Homebrew",
                command: "with_askpass env NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""),
        Snippet(category: "Homebrew (notes.md)", name: "Oracle JDK", command: "with_askpass brew install oracle-jdk"),
        Snippet(category: "Homebrew (notes.md)", name: "Aktualizacja pakietów brew", command: "with_askpass brew update && with_askpass brew upgrade"),
        Snippet(category: "System (root)", name: "Historia aktualizacji", command: "softwareupdate --history", asRoot: true),
        Snippet(category: "System (root)", name: "Ostatnie wpisy install.log", command: "tail -n 60 /var/log/install.log", asRoot: true),
        Snippet(category: "System (root)", name: "Włącz Wake-on-LAN", command: "pmset -a womp 1 && pmset -g | grep womp", asRoot: true),
    ]
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Account used by students (cmcr-helpers: `student`).
    public var studentUser = "student"
    /// Remote shared folder (cmcr-helpers: `/Users/student/Public/cmcr`).
    public var sharedFolder = "/Users/student/Public/cmcr"
    /// Local folder for pulled/pushed files (cmcr-helpers: `~/Public/cmcr`).
    public var localFolder = "~/Public/cmcr"
    /// Private key passed with `-i`; empty uses ssh defaults (~/.ssh/id_*).
    public var identityFile = ""
    public var connectTimeout = 5
    public var maxParallel = 8
    /// Extra `-o` options for ssh/scp, one `Key=Value` per line.
    public var extraSSHOptions = ""
    public var screenshotInterval = 10
    public var screenshotMaxSize = 1280
    public var screenshotQuality = 60
    /// Show a notification on the observed Mac when a preview starts.
    public var notifyOnObserve = true
    /// Refuse to capture sessions of administrator accounts (preview only restricted/standard accounts).
    public var observeOnlyStandardAccounts = true
    /// Comma separated list of accounts that may be observed; empty means any (subject to the rule above).
    public var observeAllowedUsers = ""
    public var snippets: [Snippet] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        studentUser = try c.decodeIfPresent(String.self, forKey: .studentUser) ?? d.studentUser
        sharedFolder = try c.decodeIfPresent(String.self, forKey: .sharedFolder) ?? d.sharedFolder
        localFolder = try c.decodeIfPresent(String.self, forKey: .localFolder) ?? d.localFolder
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? d.identityFile
        connectTimeout = try c.decodeIfPresent(Int.self, forKey: .connectTimeout) ?? d.connectTimeout
        maxParallel = try c.decodeIfPresent(Int.self, forKey: .maxParallel) ?? d.maxParallel
        extraSSHOptions = try c.decodeIfPresent(String.self, forKey: .extraSSHOptions) ?? d.extraSSHOptions
        screenshotInterval = try c.decodeIfPresent(Int.self, forKey: .screenshotInterval) ?? d.screenshotInterval
        screenshotMaxSize = try c.decodeIfPresent(Int.self, forKey: .screenshotMaxSize) ?? d.screenshotMaxSize
        screenshotQuality = try c.decodeIfPresent(Int.self, forKey: .screenshotQuality) ?? d.screenshotQuality
        notifyOnObserve = try c.decodeIfPresent(Bool.self, forKey: .notifyOnObserve) ?? d.notifyOnObserve
        observeOnlyStandardAccounts = try c.decodeIfPresent(Bool.self, forKey: .observeOnlyStandardAccounts) ?? d.observeOnlyStandardAccounts
        observeAllowedUsers = try c.decodeIfPresent(String.self, forKey: .observeAllowedUsers) ?? d.observeAllowedUsers
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? d.snippets
    }

    public var extraSSHOptionList: [String] {
        extraSSHOptions
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.hasPrefix("-o") ? String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) : $0 }
    }

    public var observeAllowedUserList: [String] {
        observeAllowedUsers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Replaces `{student}` with the configured student account.
    public func resolve(_ path: String) -> String {
        path.replacingOccurrences(of: "{student}", with: studentUser)
    }
}

public enum Reachability: String, Codable, Sendable {
    case unknown, checking, online, offline, authFailed, error

    public var label: String {
        switch self {
        case .unknown: return "nieznany"
        case .checking: return "sprawdzanie…"
        case .online: return "online"
        case .offline: return "offline"
        case .authFailed: return "błąd logowania"
        case .error: return "błąd"
        }
    }
}

public struct HostStatus: Sendable {
    public var reachability: Reachability = .unknown
    public var message = ""
    public var info: [String: String] = [:]
    public var updatedAt: Date?

    public init() {}

    public var osVersion: String? { info["os"].flatMap { $0.isEmpty ? nil : $0 } }
    public var consoleUser: String? { info["console"].flatMap { $0.isEmpty ? nil : $0 } }
    public var model: String? { info["model"] }
    public var ip: String? { info["ip"].flatMap { $0.isEmpty ? nil : $0 } }
    public var mac: String? { info["mac"].flatMap { $0.isEmpty ? nil : $0 } }
    public var arch: String? { info["arch"] }
    public var isAdmin: Bool { info["admin"] == "yes" }

    public var bootDate: Date? {
        guard let s = info["boot"], let t = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    public var uptimeText: String? {
        guard let boot = bootDate else { return nil }
        let secs = Int(Date().timeIntervalSince(boot))
        let d = secs / 86_400, h = (secs % 86_400) / 3600, m = (secs % 3600) / 60
        return d > 0 ? "\(d) d \(h) h" : "\(h) h \(m) min"
    }

    public var diskText: String? {
        guard let parts = info["disk"]?.split(separator: " "), parts.count == 2,
              let total = Double(parts[0]), let free = Double(parts[1]), total > 0 else { return nil }
        return String(format: "%.0f / %.0f GB wolne", free / 1_048_576, total / 1_048_576)
    }
}

public struct RunningApp: Identifiable, Hashable, Sendable {
    public var pid: Int
    public var name: String
    public var bundlePath: String
    public var id: Int { pid }
    /// Background agents and system UI services (anything outside the Applications folders).
    public var isSystem: Bool {
        !(bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix("/System/Applications/")
          || (bundlePath.hasPrefix("/Users/") && bundlePath.contains("/Applications/")))
    }
}
