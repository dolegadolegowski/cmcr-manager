import Foundation
import Security

/// Persists hosts and settings as JSON in Application Support (override with `CMCR_CONFIG_DIR`).
public enum ConfigStore {
    public static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["CMCR_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: expandTilde(custom), isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CMCRManager", isDirectory: true)
    }

    static var hostsURL: URL { directory.appendingPathComponent("hosts.json") }
    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    public static var logURL: URL {
        if ProcessInfo.processInfo.environment["CMCR_CONFIG_DIR"] != nil {
            return directory.appendingPathComponent("actions.log")
        }
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Logs/CMCRManager/actions.log")
    }

    private static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public static func loadHosts() -> [Machine] {
        record(loadHosts(from: hostsURL), for: hostsURL)
    }

    public static func saveHosts(_ hosts: [Machine]) {
        save(hosts, to: hostsURL)
    }

    public static func loadSettings() -> AppSettings {
        record(loadSettings(from: settingsURL), for: settingsURL)
    }

    public static func saveSettings(_ settings: AppSettings) {
        save(settings, to: settingsURL)
    }

    // MARK: Damaged configuration

    struct Loaded<Value> {
        var value: Value
        var issue: String?
        /// The original could not be preserved, so it must not be overwritten.
        var protect = false
    }

    private struct LoadState {
        var issues: [String] = []
        var protected = Set<String>()
        var lastSaveError: String?
    }

    private static let loadState = Locked(LoadState())

    /// Problems found while loading the configuration (shown by the app). A damaged file is never replaced
    /// silently: its original is kept next to it as `<name>.<date>.bak`.
    public static var loadIssues: [String] { loadState.withValue { $0.issues } }

    public static var lastSaveError: String? { loadState.withValue { $0.lastSaveError } }

    public static func clearLoadIssues() { loadState.withValue { $0.issues = [] } }

    private static func record<Value>(_ r: Loaded<Value>, for url: URL) -> Value {
        loadState.withValue { s in
            if let issue = r.issue, !s.issues.contains(issue) { s.issues.append(issue) }
            if r.protect { s.protected.insert(url.path) }
        }
        return r.value
    }

    /// nil when the file does not exist yet.
    private static func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func loadHosts(from url: URL) -> Loaded<[Machine]> {
        let data: Data
        do {
            guard let d = try readIfPresent(url) else { return Loaded(value: Machine.generate()) }
            data = d
        } catch {
            return Loaded(value: Machine.generate(),
                          issue: "Nie można odczytać listy komputerów (\(url.path)): \(error.localizedDescription). Zmiany listy nie będą zapisywane.",
                          protect: true)
        }
        if let hosts = try? JSONDecoder().decode([Machine].self, from: data) { return Loaded(value: hosts) }
        let backup = backupCopy(of: url, data: data)
        let note = backupNote(backup)
        let kept = (try? JSONDecoder().decode([Lossy<Machine>].self, from: data))?.compactMap(\.value) ?? []
        if !kept.isEmpty {
            return Loaded(value: kept,
                          issue: "Część wpisów listy komputerów była uszkodzona i została pominięta (wczytano \(kept.count)). \(note)",
                          protect: backup == nil)
        }
        return Loaded(value: Machine.generate(),
                      issue: "Lista komputerów (\(url.lastPathComponent)) jest uszkodzona – wczytano listę domyślną. \(note)",
                      protect: backup == nil)
    }

    static func loadSettings(from url: URL) -> Loaded<AppSettings> {
        let data: Data
        do {
            guard let d = try readIfPresent(url) else { return Loaded(value: AppSettings()) }
            data = d
        } catch {
            return Loaded(value: AppSettings(),
                          issue: "Nie można odczytać ustawień (\(url.path)): \(error.localizedDescription). Zmiany ustawień nie będą zapisywane.",
                          protect: true)
        }
        let decoder = JSONDecoder()
        if let s = try? decoder.decode(AppSettings.self, from: data) { return Loaded(value: s) }
        let backup = backupCopy(of: url, data: data)
        let note = backupNote(backup)
        // Keep every setting that is still valid on its own.
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var good: [String: Any] = [:]
            var bad: [String] = []
            for (key, value) in object {
                if let one = try? JSONSerialization.data(withJSONObject: [key: value]),
                   (try? decoder.decode(AppSettings.self, from: one)) != nil {
                    good[key] = value
                } else {
                    bad.append(key)
                }
            }
            if let d = try? JSONSerialization.data(withJSONObject: good), let s = try? decoder.decode(AppSettings.self, from: d) {
                return Loaded(value: s,
                              issue: "Niektóre ustawienia były nieprawidłowe i przywrócono im wartości domyślne (\(bad.sorted().joined(separator: ", "))). \(note)",
                              protect: backup == nil)
            }
        }
        return Loaded(value: AppSettings(),
                      issue: "Plik ustawień (\(url.lastPathComponent)) jest uszkodzony – przywrócono ustawienia domyślne. \(note)",
                      protect: backup == nil)
    }

    private static func backupNote(_ backup: URL?) -> String {
        if let backup { return "Oryginał zachowano jako \(backup.lastPathComponent) w \(backup.deletingLastPathComponent().path)." }
        return "Nie udało się zachować kopii oryginału, więc zmiany nie będą zapisywane."
    }

    /// Copies a damaged file to `<name>.<date>.bak` (once per distinct content).
    static func backupCopy(of url: URL, data: Data) -> URL? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let existing = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(name + ".") && $0.pathExtension == "bak" }
        if let same = existing.first(where: { (try? Data(contentsOf: $0)) == data }) { return same }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        for n in 0..<100 {
            let target = dir.appendingPathComponent("\(name).\(stamp)\(n == 0 ? "" : "-\(n)").bak")
            if fm.fileExists(atPath: target.path) { continue }
            do {
                try data.write(to: target, options: .withoutOverwriting)
                return target
            } catch {
                return nil
            }
        }
        return nil
    }

    public static func exportHosts(_ hosts: [Machine], to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(hosts).write(to: url, options: .atomic)
    }

    public static func importHosts(from url: URL) throws -> [Machine] {
        try JSONDecoder().decode([Machine].self, from: Data(contentsOf: url))
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        if loadState.withValue({ $0.protected.contains(url.path) }) { return }
        ensureDirectory(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(value).write(to: url, options: .atomic)
            loadState.withValue { $0.lastSaveError = nil }
        } catch {
            let message = "Nie można zapisać \(url.path): \(error.localizedDescription)"
            loadState.withValue { $0.lastSaveError = message }
            NSLog("CMCR: %@", message)
        }
    }

    /// Writes the SSH_ASKPASS helper used to answer ssh password prompts from the Keychain-backed password.
    @discardableResult
    public static func ensureAskpass() -> String {
        ensureDirectory(directory)
        let url = directory.appendingPathComponent("askpass.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$CMCR_SSH_PASSWORD\"\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try? script.write(to: url, atomically: true, encoding: .utf8)
        }
        chmod(url.path, 0o700)
        return url.path
    }

    private static let logLock = NSLock()

    /// Appends one line to the audit log of performed actions.
    public static func log(_ line: String) {
        logLock.lock()
        defer { logLock.unlock() }
        let url = logURL
        ensureDirectory(url.deletingLastPathComponent())
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Stores admin passwords in the login Keychain.
///
/// Values are cached in memory: every SSH call needs a password, and each Keychain read of an app whose
/// signature changed (rebuild, update) can show an access prompt. Misses are remembered for a minute.
public enum Keychain {
    /// `CMCR_KEYCHAIN_SERVICE` keeps tests away from the real items.
    static let defaultService = ProcessInfo.processInfo.environment["CMCR_KEYCHAIN_SERVICE"].flatMap { $0.isEmpty ? nil : $0 } ?? "pl.cmcr.manager"
    public static let sharedAccount = "admin-shared"
    static let missLifetime: TimeInterval = 60

    private struct Cache {
        var service = Keychain.defaultService
        var values: [String: String] = [:]
        var misses: [String: Date] = [:]
    }

    private static let cache = Locked(Cache())
    private static let environmentPassword = ProcessInfo.processInfo.environment["CMCR_PASSWORD"]

    /// Keychain service of the items; tests switch it so they never touch the app's real entries.
    static var service: String {
        get { cache.withValue { $0.service } }
        set { cache.withValue { $0 = Cache(service: newValue) } }
    }

    public static func account(for host: Machine) -> String { "admin-\(host.id.uuidString)" }

    public static func get(_ account: String) -> String? {
        let (service, cached, recentMiss) = cache.withValue { c in
            (c.service, c.values[account], c.misses[account].map { Date().timeIntervalSince($0) < missLifetime } ?? false)
        }
        if let cached { return cached }
        if recentMiss { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        var value: String?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            value = String(data: data, encoding: .utf8)
        }
        cache.withValue { c in
            guard c.service == service else { return }
            if let value { c.values[account] = value } else { c.misses[account] = Date() }
        }
        return value
    }

    /// Whether an entry exists, checked without reading the secret (so it never shows an access prompt).
    public static func exists(_ account: String) -> Bool {
        let (service, cached) = cache.withValue { ($0.service, $0.values[account]) }
        if cached != nil { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    @discardableResult
    public static func set(_ value: String?, for account: String) -> Bool {
        let service = cache.withValue { $0.service }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let ok: Bool
        if let value, !value.isEmpty {
            let data = Data(value.utf8)
            let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = base
                add[kSecValueData as String] = data
                add[kSecAttrLabel as String] = "CMCR Manager – hasło administratora"
                ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
            } else {
                ok = status == errSecSuccess
            }
        } else {
            let status = SecItemDelete(base as CFDictionary)
            ok = status == errSecSuccess || status == errSecItemNotFound
        }
        cache.withValue { c in
            guard c.service == service else { return }
            c.values[account] = nil
            c.misses[account] = nil
            if ok, let value, !value.isEmpty { c.values[account] = value }
        }
        return ok
    }

    /// Forgets cached values (e.g. after the Keychain was edited outside the app).
    public static func invalidateCache() {
        cache.withValue { c in
            c.values = [:]
            c.misses = [:]
        }
    }

    /// Password to use for a host: its own entry, or the shared one. `CMCR_PASSWORD` overrides both.
    public static func password(for host: Machine) -> String? {
        if let env = environmentPassword, !env.isEmpty { return env }
        if !host.usesSharedPassword, let own = get(account(for: host)), !own.isEmpty { return own }
        return get(sharedAccount)
    }
}

/// A value guarded by a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Decodes an array element, turning a damaged one into nil instead of failing the whole array.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
