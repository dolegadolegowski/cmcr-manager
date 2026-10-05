import CryptoKit
import Foundation
import Security

// Self-update from GitHub Releases.
//
// Release assets (made by scripts/release.sh):
//   CMCR-Manager-X.Y.Z.zip     – `ditto -c -k --keepParent` of the ad-hoc signed .app
//   cmcr-update.json           – manifest: version, tag, file name, size, SHA-256, min. macOS, architectures, notes
//   cmcr-update.json.sig       – base64 Ed25519 signature over the exact bytes of cmcr-update.json
//
// Trust chain: embedded public key → signature over manifest bytes → SHA-256 + size of the zip →
// bundle id / version / code signature of the extracted .app. Nothing is parsed before the signature verifies.

// MARK: - Semantic version

public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Accepts "1.2.3", "v1.2", "1.2.3-beta.2", "1.2.3+45" (build metadata is ignored).
    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let valid = pre.allSatisfy { id in
                !id.isEmpty && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
            }
            guard valid else { return nil }
            s = s[..<dash]
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for p in parts {
            guard Self.isNumeric(p), let n = Int(p) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    /// CFBundleShortVersionString of the running app (nil when started outside an .app, e.g. `swift run`).
    public static var running: SemanticVersion? {
        #if DEBUG
        if let v = ProcessInfo.processInfo.environment["CMCR_UPDATE_CURRENT_VERSION"] { return SemanticVersion(v) }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(SemanticVersion.init)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // A release ranks above any of its pre-releases (1.2.0-beta < 1.2.0).
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (isNumeric(x) ? Int(x) : nil, isNumeric(y) ? Int(y) : nil) {
            case let (i?, j?): return i < j
            case (.some, .none): return true       // numeric identifiers rank below alphanumeric ones
            case (.none, .some): return false
            case (.none, .none): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    private static func isNumeric<S: StringProtocol>(_ s: S) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

// MARK: - Errors

public enum UpdateError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case network(String)
    case http(Int, String)
    case rateLimited(Date?)
    case noManifest(String)
    case badSignature
    case invalidManifest(String)
    case wrongApplication(String)
    case versionMismatch(expected: String, found: String)
    case systemTooOld(String)
    case unsupportedArchitecture([String])
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch
    case invalidArchive(String)
    case invalidCodeSignature(String)
    case notInstallable(String)
    case helperFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Uaktualnienia nie są skonfigurowane w tej kompilacji (brak klucza publicznego do sprawdzania podpisu)."
        case .network(let m):
            return "Brak połączenia z GitHubem: \(m)"
        case .http(let code, let url):
            return "GitHub odpowiedział kodem \(code) (\(url))."
        case .rateLimited(let reset):
            let when = reset.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) }
            return "Przekroczono limit zapytań do GitHuba" + (when.map { " – spróbuj po \($0)." } ?? ".")
        case .noManifest(let tag):
            return "Wydanie \(tag) nie zawiera podpisanego manifestu uaktualnienia – pominięto je."
        case .badSignature:
            return "Podpis cyfrowy uaktualnienia jest nieprawidłowy. Uaktualnienie zostało odrzucone."
        case .invalidManifest(let m):
            return "Nieprawidłowy manifest uaktualnienia: \(m)"
        case .wrongApplication(let id):
            return "Uaktualnienie dotyczy innej aplikacji (\(id))."
        case .versionMismatch(let expected, let found):
            return "Niezgodna wersja uaktualnienia: oczekiwano \(expected), znaleziono \(found)."
        case .systemTooOld(let v):
            return "Ta wersja wymaga macOS \(v) lub nowszego."
        case .unsupportedArchitecture(let archs):
            return "Ta wersja nie obsługuje tego Maca (dostępne architektury: \(archs.joined(separator: ", ")))."
        case .sizeMismatch(let expected, let actual):
            return "Pobrany plik ma \(actual) B zamiast \(expected) B."
        case .hashMismatch:
            return "Suma kontrolna SHA-256 archiwum nie zgadza się z podpisanym manifestem. Uaktualnienie zostało odrzucone."
        case .invalidArchive(let m):
            return "Nieprawidłowe archiwum uaktualnienia: \(m)"
        case .invalidCodeSignature(let m):
            return "Podpis kodu nowej wersji jest nieprawidłowy: \(m)"
        case .notInstallable(let m):
            return m
        case .helperFailed(let m):
            return "Nie udało się uruchomić instalatora: \(m)"
        case .cancelled:
            return "Anulowano."
        }
    }
}

// MARK: - Configuration

public struct UpdateConfiguration: Sendable {
    public static let manifestName = "cmcr-update.json"
    public static let signatureName = "cmcr-update.json.sig"
    static let maxArchiveSize: Int64 = 512 * 1_048_576
    static let maxMetadataSize = 1_048_576

    public var repository: String
    public var trustedPublicKeys: [String]
    public var bundleIdentifier: String
    public var apiBase: URL
    public var webBase: URL

    public init(repository: String, trustedPublicKeys: [String], bundleIdentifier: String,
                apiBase: URL = URL(string: "https://api.github.com")!, webBase: URL = URL(string: "https://github.com")!) {
        self.repository = repository
        self.trustedPublicKeys = trustedPublicKeys
        self.bundleIdentifier = bundleIdentifier
        self.apiBase = apiBase
        self.webBase = webBase
    }

    /// Values compiled into the app. Debug builds accept overrides so the whole flow can be tested against a
    /// local HTTP server; release builds have no way to change the trusted keys at run time.
    public static var standard: UpdateConfiguration {
        var c = UpdateConfiguration(repository: UpdateKeys.repository,
                                    trustedPublicKeys: UpdateKeys.trustedPublicKeys,
                                    bundleIdentifier: Bundle.main.bundleIdentifier ?? "pl.cmcr.manager")
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let v = env["CMCR_UPDATE_REPO"] { c.repository = v }
        if let v = env["CMCR_UPDATE_TEST_PUBLIC_KEY"] { c.trustedPublicKeys = [v] }
        if let v = env["CMCR_UPDATE_API_BASE"].flatMap(URL.init(string:)) { c.apiBase = v }
        if let v = env["CMCR_UPDATE_WEB_BASE"].flatMap(URL.init(string:)) { c.webBase = v }
        if let v = env["CMCR_UPDATE_BUNDLE_ID"] { c.bundleIdentifier = v }
        #endif
        return c
    }

    public var isConfigured: Bool {
        !repository.hasPrefix("OWNER/") && repository.split(separator: "/").count == 2
            && trustedPublicKeys.contains { Data(base64Encoded: $0)?.count == 32 }
    }

    var latestReleaseURL: URL { apiBase.appendingPathComponent("repos/\(repository)/releases/latest") }
    var releasesURL: URL { apiBase.appendingPathComponent("repos/\(repository)/releases") }
    public var releasesPageURL: URL { webBase.appendingPathComponent("\(repository)/releases") }
    func latestAssetURL(_ name: String) -> URL { webBase.appendingPathComponent("\(repository)/releases/latest/download/\(name)") }
    func assetURL(tag: String, name: String) -> URL { webBase.appendingPathComponent("\(repository)/releases/download/\(tag)/\(name)") }
    func tagPageURL(_ tag: String) -> URL { webBase.appendingPathComponent("\(repository)/releases/tag/\(tag)") }
}

// MARK: - GitHub API model

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int64
        public let browserDownloadURL: URL
        /// "sha256:<hex>", computed by GitHub on upload (absent for very old assets).
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let publishedAt: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    func asset(_ name: String) -> Asset? { assets.first { $0.name == name } }
}

// MARK: - Manifest

public struct UpdateManifest: Codable, Equatable, Sendable {
    public var schema: Int
    public var bundleIdentifier: String
    public var version: String
    public var build: String?
    public var tag: String
    public var file: String
    public var size: Int64
    public var sha256: String
    public var minimumSystemVersion: String
    public var architectures: [String]
    public var notes: String?
    public var publishedAt: String?
}

/// A newer, signature-verified release that this Mac can run.
public struct UpdateCandidate: Equatable, Sendable {
    public let manifest: UpdateManifest
    public let version: SemanticVersion
    public let archiveURL: URL
    public let releasePageURL: URL
    public let notes: String
    public let publishedAt: Date?
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(latest: SemanticVersion?)
    case available(UpdateCandidate)
}

// MARK: - Verification

public enum UpdateVerifier {
    /// Verifies `signature` (base64, 64 bytes) over the exact manifest bytes with any trusted key.
    public static func verifySignature(manifest: Data, signature: Data, trustedKeys: [String]) throws {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sig = Data(base64Encoded: text), sig.count == 64 else { throw UpdateError.badSignature }
        for encoded in trustedKeys {
            guard let raw = Data(base64Encoded: encoded), raw.count == 32,
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { continue }
            if key.isValidSignature(sig, for: manifest) { return }
        }
        throw UpdateError.badSignature
    }

    /// Checks a signed manifest against the running app and this Mac. Returns the parsed version.
    public static func validate(_ m: UpdateManifest, bundleIdentifier: String, releaseTag: String?) throws -> SemanticVersion {
        guard m.schema == 1 else { throw UpdateError.invalidManifest("nieobsługiwany schemat \(m.schema)") }
        guard m.bundleIdentifier == bundleIdentifier else { throw UpdateError.wrongApplication(m.bundleIdentifier) }
        guard let version = SemanticVersion(m.version) else { throw UpdateError.invalidManifest("wersja \(m.version)") }
        // The tag is part of the signed data, so a re-labelled old release cannot pose as a new one.
        guard SemanticVersion(m.tag) == version else { throw UpdateError.versionMismatch(expected: m.version, found: m.tag) }
        if let releaseTag, SemanticVersion(releaseTag) != version {
            throw UpdateError.versionMismatch(expected: releaseTag, found: m.version)
        }
        guard m.file.hasSuffix(".zip"), !m.file.contains("/"), !m.file.hasPrefix(".") else {
            throw UpdateError.invalidManifest("nazwa pliku \(m.file)")
        }
        guard m.size > 0, m.size <= UpdateConfiguration.maxArchiveSize else { throw UpdateError.invalidManifest("rozmiar \(m.size)") }
        guard m.sha256.count == 64, m.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw UpdateError.invalidManifest("SHA-256")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if let min = SemanticVersion(m.minimumSystemVersion),
           SemanticVersion(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion) < min {
            throw UpdateError.systemTooOld(m.minimumSystemVersion)
        }
        guard m.architectures.contains(hostArchitecture) else { throw UpdateError.unsupportedArchitecture(m.architectures) }
        return version
    }

    /// Hardware architecture of this Mac (also when the app itself runs under Rosetta).
    public static var hostArchitecture: String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1 ? "arm64" : "x86_64"
    }

    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the downloaded archive against the signed manifest.
    public static func verifyArchive(_ url: URL, manifest m: UpdateManifest) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == m.size else { throw UpdateError.sizeMismatch(expected: m.size, actual: size) }
        guard try sha256Hex(of: url) == m.sha256 else { throw UpdateError.hashMismatch }
    }

    /// Full check of a downloaded archive: size and SHA-256, then the single .app inside it (extracted into
    /// `workDirectory`, removed afterwards).
    public static func verifyDownload(_ zip: URL, manifest m: UpdateManifest, workDirectory: URL) async throws {
        try verifyArchive(zip, manifest: m)
        let extracted = workDirectory.appendingPathComponent("check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let r = await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
        guard r.succeeded else { throw UpdateError.invalidArchive(r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let apps = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw UpdateError.invalidArchive("oczekiwano jednego pakietu .app") }
        try verifyBundle(at: apps[0], manifest: m)
    }

    /// Checks an extracted bundle: identity, version, architecture and a valid (ad-hoc) code signature.
    public static func verifyBundle(at app: URL, manifest m: UpdateManifest) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError.invalidArchive("brak Info.plist")
        }
        let id = info["CFBundleIdentifier"] as? String ?? "?"
        guard id == m.bundleIdentifier else { throw UpdateError.wrongApplication(id) }
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        guard version == m.version else { throw UpdateError.versionMismatch(expected: m.version, found: version) }
        guard let exe = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(exe)").path) else {
            throw UpdateError.invalidArchive("brak pliku wykonywalnego")
        }
        let archs = Bundle(url: app)?.executableArchitectures?.map(\.intValue) ?? []
        let needed = hostArchitecture == "arm64" ? NSBundleExecutableArchitectureARM64 : NSBundleExecutableArchitectureX86_64
        guard archs.contains(needed) else { throw UpdateError.unsupportedArchitecture(m.architectures) }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.invalidCodeSignature("brak podpisu")
        }
        var cfError: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &cfError)
        guard status == errSecSuccess else {
            _ = cfError?.takeRetainedValue()
            let reason = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            throw UpdateError.invalidCodeSignature(reason)
        }
        var signing: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing)
        let signedID = (signing as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
        guard signedID == m.bundleIdentifier else {
            throw UpdateError.invalidCodeSignature("identyfikator podpisu \(signedID ?? "brak")")
        }
    }
}

// MARK: - Feed (GitHub)

public struct UpdateFeed: Sendable {
    /// Last API answer, reused when GitHub replies 304 Not Modified (such requests do not count against
    /// the 60 requests/hour limit for anonymous clients, which a whole school behind one NAT shares).
    public struct Cache: Codable, Equatable, Sendable {
        public var etag: String
        public var body: Data
        public var includesPrereleases: Bool
    }

    public let configuration: UpdateConfiguration
    let session: URLSession

    public init(configuration: UpdateConfiguration = .standard, userAgent: String) {
        self.configuration = configuration
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        session = URLSession(configuration: c)
    }

    /// Finds the newest signed release. `current == nil` (development build) reports any release as newer.
    public func check(current: SemanticVersion?, includePrereleases: Bool, cache: Cache?) async throws -> (UpdateCheckResult, Cache?) {
        guard configuration.isConfigured else { throw UpdateError.notConfigured }
        var newCache = cache
        let release: GitHubRelease?
        do {
            (release, newCache) = try await latestRelease(includePrereleases: includePrereleases, cache: cache)
        } catch UpdateError.rateLimited(let reset) where !includePrereleases {
            // Fall back to the web download URL of the newest release – not subject to the API limit.
            do {
                return (try await fromLatestDownload(current: current), cache)
            } catch {
                throw UpdateError.rateLimited(reset)
            }
        }
        guard let release else { return (.upToDate(latest: nil), newCache) }
        guard let manifestAsset = release.asset(UpdateConfiguration.manifestName),
              let signatureAsset = release.asset(UpdateConfiguration.signatureName) else {
            throw UpdateError.noManifest(release.tagName)
        }
        let manifestData = try await fetch(manifestAsset.browserDownloadURL)
        let signature = try await fetch(signatureAsset.browserDownloadURL)
        let manifest = try decodeVerified(manifestData, signature: signature)
        let version = try UpdateVerifier.validate(manifest, bundleIdentifier: configuration.bundleIdentifier, releaseTag: release.tagName)
        guard let archive = release.asset(manifest.file) else { throw UpdateError.invalidManifest("brak pliku \(manifest.file) w wydaniu") }
        if let digest = archive.digest, digest.hasPrefix("sha256:"), digest.dropFirst(7).lowercased() != manifest.sha256 {
            throw UpdateError.hashMismatch
        }
        if let current, version <= current { return (.upToDate(latest: version), newCache) }
        return (.available(UpdateCandidate(manifest: manifest, version: version, archiveURL: archive.browserDownloadURL,
                                           releasePageURL: release.htmlURL,
                                           notes: Self.releaseNotes(signed: manifest.notes, releaseBody: release.body),
                                           publishedAt: release.publishedAt.flatMap(Self.parseDate))), newCache)
    }

    /// The notes in the signed manifest (Polish, written for the teachers) win over the release body on GitHub,
    /// which nobody signed and which `gh release create --generate-notes` fills with an English changelog.
    static func releaseNotes(signed: String?, releaseBody: String?) -> String {
        [signed, releaseBody].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
    }

    func latestRelease(includePrereleases: Bool, cache: Cache?) async throws -> (GitHubRelease?, Cache?) {
        var request = URLRequest(url: includePrereleases ? configuration.releasesURL : configuration.latestReleaseURL)
        if includePrereleases {
            request.url = URL(string: request.url!.absoluteString + "?per_page=20")
        }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let usable = cache.flatMap { $0.includesPrereleases == includePrereleases ? $0 : nil }
        if let usable { request.setValue(usable.etag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await send(request)
        let body: Data
        var newCache = usable
        switch response.statusCode {
        case 200:
            body = data
            if let etag = response.value(forHTTPHeaderField: "ETag") {
                newCache = Cache(etag: etag, body: data, includesPrereleases: includePrereleases)
            }
        case 304 where usable != nil:
            body = usable!.body
        case 404:
            return (nil, nil)                                   // no releases yet
        case 403, 429:
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
            throw UpdateError.rateLimited(reset.map { Date(timeIntervalSince1970: $0) })
        default:
            throw UpdateError.http(response.statusCode, request.url?.absoluteString ?? "")
        }
        let decoder = JSONDecoder()
        do {
            if includePrereleases {
                let all = try decoder.decode([GitHubRelease].self, from: body).filter { !$0.draft }
                let newest = all.compactMap { r in SemanticVersion(r.tagName).map { (r, $0) } }.max { $0.1 < $1.1 }
                return (newest?.0, newCache)
            }
            return (try decoder.decode(GitHubRelease.self, from: body), newCache)
        } catch {
            throw UpdateError.invalidManifest("odpowiedź GitHub API: \(error.localizedDescription)")
        }
    }

    func fromLatestDownload(current: SemanticVersion?) async throws -> UpdateCheckResult {
        let manifestData = try await fetch(configuration.latestAssetURL(UpdateConfiguration.manifestName))
        let signature = try await fetch(configuration.latestAssetURL(UpdateConfiguration.signatureName))
        let manifest = try decodeVerified(manifestData, signature: signature)
        let version = try UpdateVerifier.validate(manifest, bundleIdentifier: configuration.bundleIdentifier, releaseTag: nil)
        if let current, version <= current { return .upToDate(latest: version) }
        return .available(UpdateCandidate(manifest: manifest, version: version,
                                          archiveURL: configuration.assetURL(tag: manifest.tag, name: manifest.file),
                                          releasePageURL: configuration.tagPageURL(manifest.tag),
                                          notes: manifest.notes ?? "",
                                          publishedAt: manifest.publishedAt.flatMap(Self.parseDate)))
    }

    /// Verify first, parse second.
    func decodeVerified(_ manifest: Data, signature: Data) throws -> UpdateManifest {
        try UpdateVerifier.verifySignature(manifest: manifest, signature: signature, trustedKeys: configuration.trustedPublicKeys)
        do {
            return try JSONDecoder().decode(UpdateManifest.self, from: manifest)
        } catch {
            throw UpdateError.invalidManifest(error.localizedDescription)
        }
    }

    func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await send(URLRequest(url: url))
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { throw UpdateError.noManifest(url.lastPathComponent) }
            throw UpdateError.http(response.statusCode, url.absoluteString)
        }
        guard data.count <= UpdateConfiguration.maxMetadataSize else { throw UpdateError.invalidManifest("plik zbyt duży") }
        return data
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError.network("brak odpowiedzi HTTP") }
            return (data, http)
        } catch let e as UpdateError {
            throw e
        } catch is CancellationError {
            throw UpdateError.cancelled
        } catch {
            if (error as? URLError)?.code == .cancelled { throw UpdateError.cancelled }
            throw UpdateError.network(error.localizedDescription)
        }
    }

    static func parseDate(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }
}

// MARK: - Download with progress

public final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias Progress = @Sendable (_ received: Int64, _ expected: Int64) -> Void

    private let destination: URL
    private let maxBytes: Int64
    private let onProgress: Progress?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private var tooLarge = false

    private init(destination: URL, maxBytes: Int64, onProgress: Progress?) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.onProgress = onProgress
    }

    public static func download(_ url: URL, to destination: URL, maxBytes: Int64, userAgent: String,
                                progress: Progress? = nil) async throws -> URL {
        let delegate = FileDownloader(destination: destination, maxBytes: maxBytes, onProgress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                delegate.lock.lock()
                delegate.continuation = cont
                delegate.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes {
            lock.lock(); tooLarge = true; lock.unlock()
            downloadTask.cancel()
            return
        }
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so move it right here.
        let result: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            result = .failure(UpdateError.http(http.statusCode, downloadTask.originalRequest?.url?.absoluteString ?? ""))
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(UpdateError.invalidArchive(error.localizedDescription))
            }
        }
        lock.lock(); outcome = result; lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let result: Result<URL, Error>
        if tooLarge {
            result = .failure(UpdateError.invalidArchive("plik większy niż zapowiedziany"))
        } else if let error {
            result = .failure((error as? URLError)?.code == .cancelled ? UpdateError.cancelled : UpdateError.network(error.localizedDescription))
        } else {
            result = outcome ?? .failure(UpdateError.network("brak danych"))
        }
        lock.unlock()
        cont?.resume(with: result)
    }
}

// MARK: - Install location

public enum InstallLocation: Equatable, Sendable {
    case writable(URL)
    case requiresAdmin(URL)
    case unsupported(String)

    public static func of(_ bundleURL: URL) -> InstallLocation {
        let path = bundleURL.path
        guard bundleURL.pathExtension == "app" else {
            return .unsupported("Aplikacja nie działa z pakietu .app (np. „swift run”) – instalacja uaktualnień jest niedostępna.")
        }
        if path.contains("/AppTranslocation/") {
            return .unsupported("macOS uruchomił aplikację z tymczasowej kopii (App Translocation). Przenieś „CMCR Manager” do folderu Aplikacje i uruchom ją ponownie.")
        }
        if (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return .unsupported("Aplikacja działa z woluminu tylko do odczytu (np. obrazu DMG). Przenieś ją do folderu Aplikacje.")
        }
        let fm = FileManager.default
        let parent = bundleURL.deletingLastPathComponent().path
        let contents = bundleURL.appendingPathComponent("Contents").path
        if fm.isWritableFile(atPath: parent), fm.isWritableFile(atPath: path), fm.isWritableFile(atPath: contents) {
            return .writable(bundleURL)
        }
        return .requiresAdmin(bundleURL)
    }

    public var url: URL? {
        switch self {
        case .writable(let u), .requiresAdmin(let u): return u
        case .unsupported: return nil
        }
    }
}

// MARK: - Installer helper

public enum UpdateInstaller {
    public struct Request: Sendable {
        public var archive: URL
        public var sha256: String
        public var target: URL
        public var version: String
        public var bundleIdentifier: String
        public var relaunch: Bool
        /// Process the helper waits for before touching the bundle (the app itself); nil = do not wait.
        public var pid: Int32? = ProcessInfo.processInfo.processIdentifier
        public var uid = getuid()
        /// Seconds the relaunched version has to confirm that it started before the helper rolls back.
        public var confirmTimeout = 45
        public var confirmFile = UpdateInstaller.confirmFile
        public var statusFile = UpdateInstaller.statusFile

        public init(archive: URL, sha256: String, target: URL, version: String, bundleIdentifier: String, relaunch: Bool) {
            self.archive = archive
            self.sha256 = sha256
            self.target = target
            self.version = version
            self.bundleIdentifier = bundleIdentifier
            self.relaunch = relaunch
        }

        public var arguments: [String] {
            var a = ["--zip", archive.path, "--sha256", sha256, "--target", target.path,
                     "--version", version, "--bundle-id", bundleIdentifier, "--uid", String(uid),
                     "--confirm", confirmFile.path, "--status", statusFile.path,
                     "--confirm-timeout", String(confirmTimeout)]
            if let pid { a = ["--pid", String(pid)] + a }
            if !relaunch { a.append("--no-relaunch") }
            return a
        }
    }

    /// Written by every launch of the app (see `confirmLaunch`); the helper waits for it before deleting the backup.
    public static var confirmFile: URL { stateDirectory.appendingPathComponent("pl.cmcr.manager.update-confirm") }
    /// Written by the helper when the update failed (read by the version that runs afterwards).
    public static var statusFile: URL { stateDirectory.appendingPathComponent("pl.cmcr.manager.update-status") }

    /// The user's temporary folder (the same for the old and the new version of the app).
    static var stateDirectory: URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["CMCR_UPDATE_STATE_DIR"] { return URL(fileURLWithPath: dir) }
        #endif
        return FileManager.default.temporaryDirectory
    }
    public static var logURL: URL { ConfigStore.logURL.deletingLastPathComponent().appendingPathComponent("update.log") }

    /// The app reports its start in two steps: "<version> <pid>" as the very first thing (before anything that
    /// can wait for the user, such as the Keychain asking whether the updated app may read the saved password)
    /// and "<version>" once launching has finished. After the first step the helper waits as long as that
    /// process lives, so a slow start is not rolled back, while a crash during the start still is.
    public static func confirmLaunch(version: String, finished: Bool, to file: URL = confirmFile) {
        let text = finished ? version : "\(version) \(ProcessInfo.processInfo.processIdentifier)"
        try? Data(text.utf8).write(to: file, options: .atomic)
    }

    /// Same-user install: the helper is a child that outlives the app and waits for it to exit.
    /// Returns the helper process, so the app can stop it again when quitting was cancelled after all.
    @discardableResult
    public static func launch(_ request: Request) throws -> Process {
        let log = try openLog()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", helperScript, "cmcr-updater"] + request.arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        do { try p.run() } catch { throw UpdateError.helperFailed(error.localizedDescription) }
        return p
    }

    /// Install into a folder the user cannot write (e.g. /Applications owned by root): macOS asks for an
    /// administrator name and password, the helper runs as root in the background and relaunches the app as
    /// the user. The script travels base64-encoded in the command, so no root-executed file sits on disk.
    public static func launchPrivileged(_ request: Request, prompt: String) async throws {
        _ = try openLog()                     // create the log as the user, so root only appends to it
        let r = await ProcessRunner.run("/usr/bin/osascript", ["-e", privilegedAppleScript(request, prompt: prompt)], timeout: 600)
        guard r.succeeded else {
            if r.stderrText.contains("-128") { throw UpdateError.cancelled }
            throw UpdateError.helperFailed(r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// `do shell script … with administrator privileges` that starts the helper as root in the background.
    public static func privilegedAppleScript(_ request: Request, prompt: String) -> String {
        let b64 = Data(helperScript.utf8).base64EncodedString()
        let command = "/bin/bash -c \"$(echo \(b64) | /usr/bin/base64 -D)\" cmcr-updater "
            + request.arguments.map(shQuote).joined(separator: " ")
            + " >> \(shQuote(logURL.path)) 2>&1 &"
        return "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
    }

    static func openLog() throws -> FileHandle {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: url.path) else { throw UpdateError.helperFailed("nie można otworzyć \(url.path)") }
        h.seekToEndOfFile()
        return h
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Exchanges two directories atomically (APFS/HFS+). Used by the helper via `cmcrctl __swap-bundles`.
    public static func swap(_ a: String, _ b: String) -> Int32 {
        renamex_np(a, b, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
    }

    /// Runs after the app has quit: re-checks the archive, stages the new bundle next to the old one, swaps
    /// them atomically, relaunches, waits for the new version to confirm it started and rolls back otherwise.
    public static let helperScript = #"""
    set -u
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    PID= ZIP= SHA= DST= VERSION= BUNDLE_ID= USER_ID= CONFIRM= STATUS= RELAUNCH=1 WAIT_CONFIRM=45
    while [ $# -gt 0 ]; do
      case "$1" in
        --pid) PID=$2; shift 2 ;;
        --zip) ZIP=$2; shift 2 ;;
        --sha256) SHA=$2; shift 2 ;;
        --target) DST=$2; shift 2 ;;
        --version) VERSION=$2; shift 2 ;;
        --bundle-id) BUNDLE_ID=$2; shift 2 ;;
        --uid) USER_ID=$2; shift 2 ;;
        --confirm) CONFIRM=$2; shift 2 ;;
        --status) STATUS=$2; shift 2 ;;
        --confirm-timeout) WAIT_CONFIRM=$2; shift 2 ;;
        --no-relaunch) RELAUNCH=0; shift ;;
        *) echo "cmcr-updater: nieznany argument $1"; exit 64 ;;
      esac
    done

    log() { printf '%s [uaktualnienie %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$VERSION" "$*"; }
    WORK=$(mktemp -d /tmp/cmcr-update.XXXXXX) || exit 1
    NAME=$(basename "$DST"); DIR=$(dirname "$DST"); STAMP=$(date +%Y%m%d-%H%M%S)
    NEW="$DIR/.$NAME.new-$STAMP"; OLD="$DIR/.$NAME.old-$STAMP"

    # Commands that must run as the user who started the update, never as root.
    as_user() {
      if [ "$(id -u)" = 0 ] && [ -n "$USER_ID" ] && [ "$USER_ID" != 0 ]; then
        launchctl asuser "$USER_ID" sudo -u "#$USER_ID" -- "$@"
      else
        "$@"
      fi
    }
    # The status file lives in the user's temporary folder, so it is written with the user's rights – unless it
    # sits in a folder only root can write (`sudo cmcrctl app-update install`), which the user cannot even enter.
    status() {
      [ -z "$STATUS" ] && return 0
      if [ "$(id -u)" = 0 ] && [ -n "$(find "$(dirname "$STATUS")" -maxdepth 0 -user 0 ! -perm +022 2>/dev/null)" ]; then
        printf '%s\n' "$*" > "$STATUS"
      else
        as_user /bin/sh -c 'printf "%s\n" "$2" > "$1"' cmcr-status "$STATUS" "$*"
      fi
    }
    finish() { rm -rf "$WORK"; [ -e "$NEW" ] && rm -rf "$NEW"; exit "$1"; }
    die() {
      log "BŁĄD: $*"
      status "failed $*"
      [ "$RELAUNCH" = 1 ] && [ -d "$DST" ] && as_user open "$DST"
      finish 1
    }
    swap() {   # atomic exchange of two sibling directories; falls back to three renames
      [ -x "$WORK/cmcrctl" ] && "$WORK/cmcrctl" __swap-bundles "$1" "$2" && return 0
      local tmp="$DIR/.$NAME.swap-$STAMP"
      mv "$2" "$tmp" || return 1
      mv "$1" "$2" || { mv "$tmp" "$2"; return 1; }
      mv "$tmp" "$1"
    }

    case "$DST" in /*.app) ;; *) log "nieprawidłowy cel: $DST"; finish 64 ;; esac
    [ -d "$DST" ] || { log "brak $DST"; finish 64; }
    [[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { log "nieprawidłowa suma SHA-256"; finish 64; }
    [[ "$WAIT_CONFIRM" =~ ^[0-9]+$ ]] || WAIT_CONFIRM=45

    if [ -n "$PID" ]; then
      log "czekam na zamknięcie aplikacji (PID $PID)"
      for _ in $(seq 1 600); do ps -p "$PID" >/dev/null 2>&1 || break; sleep 0.1; done
      ps -p "$PID" >/dev/null 2>&1 && { RELAUNCH=0; die "aplikacja nadal działa po 60 s – nic nie zmieniono"; }
    fi

    # 1. Integrity once more, on a private copy (the download folder is writable by the user).
    cp "$ZIP" "$WORK/update.zip" || die "nie można odczytać archiwum"
    [ "$(shasum -a 256 "$WORK/update.zip" | awk '{print $1}')" = "$SHA" ] || die "suma SHA-256 archiwum się nie zgadza"
    ditto -x -k "$WORK/update.zip" "$WORK/x" || die "nie można rozpakować archiwum"
    APPS=$(find "$WORK/x" -mindepth 1 -maxdepth 1 -name '*.app' -type d | wc -l | tr -d ' ')
    [ "$APPS" = 1 ] || die "archiwum musi zawierać dokładnie jeden pakiet .app"
    SRC=$(find "$WORK/x" -mindepth 1 -maxdepth 1 -name '*.app' -type d)

    # 2. Stage next to the target (same volume, so the swap is a rename) with the old owner.
    ditto "$SRC" "$NEW" || die "brak uprawnień do zapisu w $DIR"
    [ "$(id -u)" = 0 ] && chown -R "$(stat -f '%u:%g' "$DST")" "$NEW"
    xattr -dr com.apple.quarantine "$NEW" 2>/dev/null
    plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$NEW/Contents/Info.plist" 2>/dev/null; }
    [ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] || die "inny identyfikator pakietu: $(plist CFBundleIdentifier)"
    [ "$(plist CFBundleShortVersionString)" = "$VERSION" ] || die "inna wersja w pakiecie: $(plist CFBundleShortVersionString)"
    codesign --verify --deep --strict "$NEW" || die "podpis kodu nowej wersji jest nieprawidłowy"
    SELFTEST=$(as_user "$NEW/Contents/MacOS/$(plist CFBundleExecutable)" --cmcr-self-test 2>&1 | tail -n 1)
    [ "$SELFTEST" = "$VERSION" ] || die "nowa wersja nie przeszła testu uruchomienia: $SELFTEST"
    cp "$NEW/Contents/Resources/bin/cmcrctl" "$WORK/cmcrctl" 2>/dev/null

    # 3. Swap. Afterwards $NEW holds the previous version, which becomes the backup.
    swap "$NEW" "$DST" || die "nie można podmienić aplikacji (Ustawienia › Prywatność i ochrona › Zarządzanie aplikacjami?)"
    mv "$NEW" "$OLD" || log "uwaga: kopia zapasowa pozostaje w $NEW"
    [ -d "$OLD" ] || OLD="$NEW"
    touch "$DST"
    log "zainstalowano w $DST (kopia poprzedniej wersji: $OLD)"

    rollback() {
      log "przywracanie poprzedniej wersji: $*"
      status "rolledback $*"
      pkill -f "$DST/Contents/MacOS/" 2>/dev/null; sleep 1
      if swap "$OLD" "$DST"; then rm -rf "$OLD"; else log "BŁĄD: przywracanie nie powiodło się – poprzednia wersja: $OLD"; fi
      as_user open "$DST"
      rm -rf "$WORK"; exit 2
    }

    # 4. Relaunch and wait until the new version confirms that it started. The app writes "<version> <pid>" as
    #    soon as its process runs and "<version>" when launching has finished (UpdateInstaller.confirmLaunch);
    #    in between it may wait for the user (Keychain dialog), so then only the death of that process counts.
    KEEP_OLD=0
    if [ "$RELAUNCH" = 1 ]; then
      confirmed() { [ "$(cat "$CONFIRM" 2>/dev/null)" = "$VERSION" ]; }
      starting_pid() { set -- $(cat "$CONFIRM" 2>/dev/null); [ "${1:-}" = "$VERSION" ] && [[ "${2:-}" =~ ^[0-9]+$ ]] && echo "$2"; }
      alive() { case "$(ps -o stat= -p "$1" 2>/dev/null)" in ''|Z*) return 1 ;; esac; }
      rm -f "$CONFIRM"
      as_user open "$DST" || rollback "nie można uruchomić nowej wersji"
      APP_PID=
      for _ in $(seq 1 $((WAIT_CONFIRM * 10))); do
        confirmed && break
        APP_PID=$(starting_pid) && break
        sleep 0.1
      done
      if ! confirmed; then
        [ -n "$APP_PID" ] || rollback "nowa wersja nie potwierdziła uruchomienia w ciągu $WAIT_CONFIRM s"
        log "nowa wersja uruchamia się (PID $APP_PID) – czekam na zakończenie startu"
        for _ in $(seq 1 3600); do
          confirmed && break
          alive "$APP_PID" || { confirmed && break; rollback "nowa wersja zakończyła działanie w trakcie uruchamiania"; }
          sleep 0.5
        done
        confirmed || { KEEP_OLD=1; log "nowa wersja nadal się uruchamia po 30 min – zostaje, kopia poprzedniej: $OLD"; }
      fi
      rm -f "$CONFIRM"
    fi
    [ "$KEEP_OLD" = 1 ] || rm -rf "$OLD"
    rm -rf "$WORK"
    rm -f "$STATUS"
    log "gotowe"
    exit 0
    """#
}
