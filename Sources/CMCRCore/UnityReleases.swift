import Foundation

// Unity Editor releases for macOS, from the Unity Release API (https://docs.unity.com/en-us/oas-release/1.0.0).
// The version is resolved once, on this Mac: a line such as 6000.6 then means the same release – and the same
// changeset – on every iMac, and the iMacs never have to ask Unity which release is the newest.

/// What the teacher typed: a line (6000.6 → its newest final release) or one exact version (6000.6.8f1).
public enum UnityVersionInput: Equatable, Sendable {
    case line(String)
    case exact(String)

    public init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if UnityReleases.isLine(s) {
            self = .line(s)
        } else if UnityReleases.isVersion(s) {
            self = .exact(s)
        } else {
            return nil
        }
    }

    public var text: String {
        switch self {
        case .line(let s), .exact(let s): return s
        }
    }
}

/// Free disk space (KB) an installation needs at most: the downloads plus the installed files.
public struct UnityDiskNeed: Equatable, Sendable {
    public var editorKB: Int64
    /// Per module id, the module together with all its sub-modules (what `--childModules` installs).
    public var modulesKB: [String: Int64]

    public init(editorKB: Int64, modulesKB: [String: Int64]) {
        self.editorKB = editorKB
        self.modulesKB = modulesKB
    }
}

public struct UnityRelease: Equatable, Sendable {
    public struct Size: Equatable, Sendable {
        public var download: Int64
        public var installed: Int64

        public init(download: Int64, installed: Int64) {
            self.download = download
            self.installed = installed
        }

        static func + (a: Size, b: Size) -> Size { Size(download: a.download + b.download, installed: a.installed + b.installed) }
    }

    public var version: String
    public var changeset: String
    /// LTS, SUPPORTED or TECH.
    public var stream: String
    public var releaseDate: Date?
    /// The editor alone, by architecture ("arm64", "x86_64").
    public var editor: [String: Size]
    /// By architecture, then module id: the module together with all its sub-modules.
    public var modules: [String: [String: Size]]

    public init(version: String, changeset: String, stream: String, releaseDate: Date?, editor: [String: Size],
                modules: [String: [String: Size]]) {
        self.version = version
        self.changeset = changeset
        self.stream = stream
        self.releaseDate = releaseDate
        self.editor = editor
        self.modules = modules
    }

    /// The modules Unity offers for this release on a Mac (on either architecture).
    public var moduleIDs: Set<String> { Set(modules.values.flatMap(\.keys)) }

    /// Requested ids Unity does not offer for this release (a typo would otherwise fail on every iMac).
    public func unknownModules(_ ids: [String]) -> [String] { ids.filter { !moduleIDs.contains($0) } }

    /// The larger of the two architectures, so one number serves Apple silicon and Intel Macs alike.
    public func diskNeed(modules ids: [String]) -> UnityDiskNeed {
        func kb(_ s: Size) -> Int64 { (s.download + s.installed + 1023) / 1024 }
        let editorKB = editor.values.map(kb).max() ?? 0
        var mods: [String: Int64] = [:]
        for id in ids {
            mods[id] = modules.values.compactMap { $0[id].map(kb) }.max() ?? 0
        }
        return UnityDiskNeed(editorKB: editorKB, modulesKB: mods)
    }

    /// Editor plus the selected modules, for the larger architecture.
    public func totalSize(modules ids: [String]) -> Size {
        let perArch = editor.map { arch, ed in ids.reduce(ed) { $0 + (modules[arch]?[$1] ?? Size(download: 0, installed: 0)) } }
        return perArch.max { $0.download + $0.installed < $1.download + $1.installed } ?? Size(download: 0, installed: 0)
    }
}

public enum UnityReleaseError: LocalizedError, Equatable {
    case invalidInput(String)
    /// The line has only alpha or beta releases (or none at all).
    case noFinalRelease(String)
    case notFound(String)
    case rateLimited
    case http(Int)
    case network(String)
    case invalidResponse(String)

    /// Unity could not be asked – unlike an answer that the version does not exist.
    public var isLookupUnavailable: Bool {
        switch self {
        case .rateLimited, .http, .network, .invalidResponse: return true
        case .invalidInput, .noFinalRelease, .notFound: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let s):
            return "„\(s)” to nie wersja Unity – podaj pełny numer (np. 6000.6.8f1) albo linię (np. 6000.6)."
        case .noFinalRelease(let line):
            return "Linia Unity \(line) nie ma jeszcze wersji końcowej (są najwyżej wersje alfa/beta) – podaj pełny numer wersji."
        case .notFound(let v):
            return "Unity nie zna wersji \(v) dla macOS – sprawdź numer (np. na unity.com/releases/editor/archive)."
        case .rateLimited:
            return "Unity Release API odrzuciło zapytanie (zbyt wiele zapytań) – spróbuj za chwilę."
        case .http(let code):
            return "Unity Release API odpowiedziało błędem HTTP \(code)."
        case .network(let why):
            return "Nie można połączyć z Unity Release API: \(why)"
        case .invalidResponse(let why):
            return "Nieczytelna odpowiedź Unity Release API: \(why)"
        }
    }
}

public enum UnityReleases {
    public static let apiURL = URL(string: "https://services.api.unity.com/unity/editor/release/v1/releases")!

    /// 6000.6, 2022.3
    public static func isLine(_ s: String) -> Bool { matches(s, "^[0-9]{4}\\.[0-9]{1,2}$") }

    /// 6000.6.8f1, 6000.0.85f2, 6000.7.0b7, 2019.4.40f1
    public static func isVersion(_ s: String) -> Bool { matches(s, "^[0-9]{4}\\.[0-9]{1,2}\\.[0-9]{1,3}[abfpc][0-9]{1,3}$") }

    /// A final release (`f`), not an alpha, beta or patch.
    public static func isFinal(_ version: String) -> Bool { matches(version, "^[0-9]{4}\\.[0-9]{1,2}\\.[0-9]{1,3}f[0-9]{1,3}$") }

    /// The 12 hex digits Unity Hub calls a changeset (the API: shortRevision).
    public static func isChangeset(_ s: String) -> Bool { matches(s, "^[0-9a-f]{12}$") }

    /// Unity Hub module ids: lowercase letters, digits, '-', '.', '+' (android-open-jdk-17.0.18+8).
    public static func isModuleID(_ s: String) -> Bool { matches(s, "^[a-z0-9][a-z0-9.+-]{0,63}$") }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// The request for `input`: a line asks only for final releases (newest first), a version for itself.
    public static func queryURL(for input: UnityVersionInput) -> URL {
        var c = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "platform", value: "MAC_OS"), URLQueryItem(name: "version", value: input.text)]
        switch input {
        case .line:
            items += ["LTS", "SUPPORTED", "TECH"].map { URLQueryItem(name: "stream", value: $0) }
            items += [URLQueryItem(name: "order", value: "RELEASE_DATE_DESC"), URLQueryItem(name: "limit", value: "10")]
        case .exact:
            items.append(URLQueryItem(name: "limit", value: "5"))
        }
        c.queryItems = items
        return c.url!
    }

    /// The release `input` names in an API answer: for a line, its newest final release.
    public static func parse(_ data: Data, for input: UnityVersionInput) throws -> UnityRelease {
        let page: APIPage
        do {
            page = try JSONDecoder().decode(APIPage.self, from: data)
        } catch {
            throw UnityReleaseError.invalidResponse(error.localizedDescription)
        }
        let candidates: [APIRelease]
        switch input {
        case .line(let line):
            candidates = page.results.filter { $0.version.hasPrefix(line + ".") && isFinal($0.version) }
        case .exact(let v):
            candidates = page.results.filter { $0.version == v }
        }
        guard let newest = candidates.max(by: { versionKey($0.version).lexicographicallyPrecedes(versionKey($1.version)) }) else {
            if case .line(let line) = input { throw UnityReleaseError.noFinalRelease(line) }
            throw UnityReleaseError.notFound(input.text)
        }
        guard isChangeset(newest.shortRevision) else {
            throw UnityReleaseError.invalidResponse("changeset „\(newest.shortRevision)” wersji \(newest.version)")
        }
        var editor: [String: UnityRelease.Size] = [:]
        var modules: [String: [String: UnityRelease.Size]] = [:]
        for d in newest.downloads ?? [] where (d.platform ?? "MAC_OS") == "MAC_OS" {
            guard let arch = d.architecture.map(architecture) else { continue }
            editor[arch] = UnityRelease.Size(download: d.downloadSize?.bytes ?? 0, installed: d.installedSize?.bytes ?? 0)
            var mods: [String: UnityRelease.Size] = [:]
            for m in d.modules ?? [] { mods[m.id] = m.totalSize }
            modules[arch] = mods
        }
        return UnityRelease(version: newest.version, changeset: newest.shortRevision, stream: newest.stream ?? "",
                            releaseDate: newest.releaseDate.flatMap(parseDate), editor: editor, modules: modules)
    }

    public typealias Loader = @Sendable (URL) async throws -> Data

    /// Asks the Unity Release API. `load` replaces the network (tests).
    public static func resolve(_ input: UnityVersionInput, load: Loader? = nil) async throws -> UnityRelease {
        let url = queryURL(for: input)
        let loader: Loader = load ?? { try await fetch($0) }
        let data = try await loader(url)
        return try parse(data, for: input)
    }

    static func fetch(_ url: URL) async throws -> Data {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": "CMCR-Manager (macOS)", "Accept": "application/json"]
        let session = URLSession(configuration: c)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw UnityReleaseError.network(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return data
        case 429: throw UnityReleaseError.rateLimited
        default: throw UnityReleaseError.http(code)
        }
    }

    /// 6000.6.8f1 → (6000, 6, 8, 'f' rank, 1); final releases rank above betas and alphas of the same patch.
    static func versionKey(_ v: String) -> [Int] {
        var parts: [Int] = []
        var number = ""
        for ch in v {
            if ch.isASCII && ch.isNumber {
                number.append(ch)
            } else {
                parts.append(Int(number) ?? 0)
                number = ""
                if ch != "." { parts.append(["a": 0, "b": 1, "c": 2, "f": 3, "p": 4][String(ch)] ?? 0) }
            }
        }
        parts.append(Int(number) ?? 0)
        return parts
    }

    static func architecture(_ api: String) -> String {
        switch api.uppercased() {
        case "ARM64": return "arm64"
        case "X86_64": return "x86_64"
        default: return api.lowercased()
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: - API answer (only the fields used here)

    struct APIPage: Decodable {
        let results: [APIRelease]
    }

    struct APIRelease: Decodable {
        let version: String
        let shortRevision: String
        let releaseDate: String?
        let stream: String?
        let downloads: [APIDownload]?
    }

    struct APIDownload: Decodable {
        let platform: String?
        let architecture: String?
        let downloadSize: APISize?
        let installedSize: APISize?
        let modules: [APIModule]?
    }

    struct APIModule: Decodable {
        let id: String
        let downloadSize: APISize?
        let installedSize: APISize?
        let subModules: [APIModule]?

        var totalSize: UnityRelease.Size {
            (subModules ?? []).reduce(UnityRelease.Size(download: downloadSize?.bytes ?? 0, installed: installedSize?.bytes ?? 0)) {
                $0 + $1.totalSize
            }
        }
    }

    struct APISize: Decodable {
        let value: Double
        let unit: String?

        var bytes: Int64 {
            let factor: Double
            switch (unit ?? "BYTE").uppercased() {
            case "KILOBYTE": factor = 1_000
            case "MEGABYTE": factor = 1_000_000
            case "GIGABYTE": factor = 1_000_000_000
            default: factor = 1
            }
            return Int64(max(0, value) * factor)
        }
    }
}
