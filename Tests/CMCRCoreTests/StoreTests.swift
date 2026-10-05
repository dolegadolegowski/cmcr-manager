import Foundation
import Security
import Testing
@testable import CMCRCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func backups(in dir: URL, of name: String) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix(name + ".") && $0.pathExtension == "bak" }
}

struct ConfigRecoveryTests {
    @Test func missingFilesGiveDefaultsSilently() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hosts = ConfigStore.loadHosts(from: dir.appendingPathComponent("hosts.json"))
        #expect(hosts.value.count == 15)
        #expect(hosts.issue == nil)
        let settings = ConfigStore.loadSettings(from: dir.appendingPathComponent("settings.json"))
        #expect(settings.value == AppSettings())
        #expect(settings.issue == nil)
    }

    @Test func damagedHostEntriesAreSkippedAndTheOriginalKept() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hosts.json")
        let original = Data(#"[{"name":"pracownia-1","address":"10.0.0.1","user":"admin"},{"name":"bez adresu"}]"#.utf8)
        try original.write(to: url)
        let r = ConfigStore.loadHosts(from: url)
        #expect(r.value.map(\.name) == ["pracownia-1"])
        #expect(r.issue?.contains("pominięta") == true)
        #expect(!r.protect)
        let saved = backups(in: dir, of: "hosts.json")
        #expect(saved.count == 1)
        #expect(try Data(contentsOf: #require(saved.first)) == original)
        // The same damaged file is backed up only once.
        _ = ConfigStore.loadHosts(from: url)
        #expect(backups(in: dir, of: "hosts.json").count == 1)
    }

    @Test func unreadableHostListFallsBackToDefaultsWithABackup() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hosts.json")
        try Data("to nie jest JSON".utf8).write(to: url)
        let r = ConfigStore.loadHosts(from: url)
        #expect(r.value.count == 15)
        #expect(r.issue?.contains("uszkodzona") == true)
        #expect(backups(in: dir, of: "hosts.json").count == 1)
    }

    @Test func fileThatCannotBeReadIsProtectedFromOverwriting() throws {
        let dir = try temporaryDirectory()
        defer {
            chmod(dir.appendingPathComponent("hosts.json").path, 0o600)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("hosts.json")
        try Data("[]".utf8).write(to: url)
        chmod(url.path, 0)
        let r = ConfigStore.loadHosts(from: url)
        #expect(r.protect)
        #expect(r.issue != nil)
    }

    @Test func validSettingsSurviveOneBadValue() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"studentUser": 5, "connectTimeout": 9, "reuseConnections": false}"#.utf8).write(to: url)
        let r = ConfigStore.loadSettings(from: url)
        #expect(r.value.connectTimeout == 9)
        #expect(!r.value.reuseConnections)
        #expect(r.value.studentUser == AppSettings().studentUser)
        #expect(r.issue?.contains("studentUser") == true)
        #expect(backups(in: dir, of: "settings.json").count == 1)
    }

    @Test func connectionSharingDefaultsToOn() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"connectTimeout": 4}"#.utf8))
        #expect(s.reuseConnections)
        #expect(s.connectTimeout == 4)
    }
}

/// Uses a throw-away Keychain service so the app's real entries are never touched.
private func keychainUsable() -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "pl.cmcr.manager.tests.probe",
        kSecAttrAccount as String: "probe-\(UUID().uuidString)",
        kSecValueData as String: Data("x".utf8),
    ]
    guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { return false }
    var delete = query
    delete[kSecValueData as String] = nil
    SecItemDelete(delete as CFDictionary)
    return true
}

@Suite(.serialized, .enabled(if: keychainUsable(), "Pęk kluczy jest niedostępny"))
struct KeychainCacheTests {
    @Test func secretsAreCachedAndExistenceNeedsNoRead() {
        let original = Keychain.service
        let service = "pl.cmcr.manager.tests.\(UUID().uuidString)"
        Keychain.service = service
        defer { Keychain.service = original }
        let account = "test-\(UUID().uuidString)"
        let direct: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        defer { SecItemDelete(direct as CFDictionary) }

        #expect(Keychain.get(account) == nil)
        #expect(!Keychain.exists(account))
        #expect(Keychain.set("sekret ąę", for: account))
        #expect(Keychain.get(account) == "sekret ąę")
        #expect(Keychain.exists(account))

        // Removed behind the cache's back: still served from memory, until invalidated.
        SecItemDelete(direct as CFDictionary)
        #expect(Keychain.get(account) == "sekret ąę")
        Keychain.invalidateCache()
        #expect(Keychain.get(account) == nil)

        // A miss is remembered too.
        var add = direct
        add[kSecValueData as String] = Data("nowe".utf8)
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(Keychain.get(account) == nil)
        #expect(Keychain.exists(account))
        Keychain.invalidateCache()
        #expect(Keychain.get(account) == "nowe")

        // Setting updates the cache; clearing removes the entry.
        #expect(Keychain.set("trzecie", for: account))
        #expect(Keychain.get(account) == "trzecie")
        #expect(Keychain.set(nil, for: account))
        #expect(Keychain.get(account) == nil)
        #expect(!Keychain.exists(account))
    }
}
