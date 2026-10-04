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
        guard let data = try? Data(contentsOf: hostsURL),
              let hosts = try? JSONDecoder().decode([Machine].self, from: data) else {
            return Machine.generate()
        }
        return hosts
    }

    public static func saveHosts(_ hosts: [Machine]) {
        save(hosts, to: hostsURL)
    }

    public static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    public static func saveSettings(_ settings: AppSettings) {
        save(settings, to: settingsURL)
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
        ensureDirectory(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(value) {
            try? data.write(to: url, options: .atomic)
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
public enum Keychain {
    static let service = "pl.cmcr.manager"
    public static let sharedAccount = "admin-shared"

    public static func account(for host: Machine) -> String { "admin-\(host.id.uuidString)" }

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func set(_ value: String?, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "CMCR Manager – hasło administratora"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Password to use for a host: its own entry, or the shared one. `CMCR_PASSWORD` overrides both.
    public static func password(for host: Machine) -> String? {
        if let env = ProcessInfo.processInfo.environment["CMCR_PASSWORD"], !env.isEmpty { return env }
        if !host.usesSharedPassword, let own = get(account(for: host)), !own.isEmpty { return own }
        return get(sharedAccount)
    }
}
