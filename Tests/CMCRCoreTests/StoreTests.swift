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

    /// duplicate-host-id (AUDIT KON-02): a copied entry keeps the "id" of the original; two Macs with one id crash
    /// the lesson routines (Dictionary(uniqueKeysWithValues:)) and share one row, status and own password.
    @Test func repeatedIDsGetNewOnesWithAWarning() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hosts.json")
        let id = "11111111-2222-3333-4444-555555555555"
        try Data("""
        [{"id":"\(id)","name":"imac01","address":"imac01.local","user":"imac01","usesSharedPassword":false},
         {"id":"\(id)","name":"imac02","address":"imac02.local","user":"imac02","usesSharedPassword":false},
         {"id":"\(id)","name":"imac03","address":"imac03.local","user":"imac03"}]
        """.utf8).write(to: url)
        let r = ConfigStore.loadHosts(from: url)
        #expect(r.value.map(\.name) == ["imac01", "imac02", "imac03"])
        #expect(Set(r.value.map(\.id)).count == 3)
        #expect(r.value[0].id.uuidString == id, "pierwszy wpis zachowuje identyfikator (i swoje hasło)")
        // A copy cannot use the first entry's own password (the Keychain item belongs to the old id).
        #expect(r.value[1].usesSharedPassword)
        #expect(!r.value[0].usesSharedPassword)
        #expect(r.issue?.contains("imac02") == true && r.issue?.contains("imac03") == true, "\(r.issue ?? "-")")
        #expect(r.renumbered)
        let imported = try ConfigStore.importHosts(from: url)
        #expect(Set(imported.map(\.id)).count == 3)
        let decoded = try ConfigStore.decodeHosts(Data(contentsOf: url))
        #expect(Set(decoded.map(\.id)).count == 3)
        // A list without repeated ids is left exactly as it is.
        let fine = Machine.generate(count: 3)
        #expect(Machine.withUniqueIDs(fine).hosts == fine)
        #expect(Machine.withUniqueIDs(fine).renamed.isEmpty)
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

    /// AUDIT KON-03: a failed save is reported to the caller (the app shows it, cmcrctl stops with an error).
    @Test func aFailedSaveIsReported() throws {
        let dir = try temporaryDirectory()
        defer {
            chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("hosts.json")
        #expect(ConfigStore.save([Machine](), to: url) == nil)
        chmod(dir.path, 0o500)
        let problem = ConfigStore.save(Machine.generate(), to: url)
        #expect(problem?.contains(url.path) == true)
        // Not checked: ConfigStore.lastSaveError – it is global, and the successful saves of other suites running at
        // the same time (RevG1coreTests, the rest of this suite) reset it, so comparing it here was a race.
        #expect(try JSONDecoder().decode([Machine].self, from: Data(contentsOf: url)).isEmpty)
    }

    /// AUDIT KON-04: a save does not undo what cmcrctl wrote since the list was read; the change is also noticed
    /// without a save (the app checks when it becomes active).
    @Test func savingMergesChangesWrittenByAnotherProgram() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hosts.json")
        let start = Array(Machine.generate().prefix(3))
        #expect(ConfigStore.syncHosts(start, at: url).problem == nil)
        #expect(ConfigStore.hostsChangedOutside(keeping: start, at: url) == nil)

        // cmcrctl hosts add, while the app keeps the list in memory.
        let added = Machine(name: "imac16", address: "imac16.local", user: "imac16")
        let enc = JSONEncoder()
        try enc.encode(start + [added]).write(to: url)
        #expect(ConfigStore.hostsChangedOutside(keeping: start, at: url)?.map(\.name) == start.map(\.name) + ["imac16"])

        // Second change by cmcrctl, then the app saves its own edit: both survive, in memory and in the file.
        var cli = start + [added]
        cli.removeFirst()
        try enc.encode(cli).write(to: url)
        var mine = start + [added]
        mine[1].port = 2222
        let saved = ConfigStore.syncHosts(mine, at: url)
        #expect(saved.problem == nil)
        #expect(saved.hosts.map(\.name) == ["imac02", "imac03", "imac16"])
        #expect(saved.hosts.first?.port == 2222)
        #expect(try JSONDecoder().decode([Machine].self, from: Data(contentsOf: url)) == saved.hosts)
        #expect(ConfigStore.hostsChangedOutside(keeping: saved.hosts, at: url) == nil)
    }

    /// AUDIT KON-13: a broken list file names the place, as cmcrctl does, not Foundation's generic text.
    @Test func importingABrokenListNamesThePlace() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lista.json")
        let good = try String(data: JSONEncoder().encode([Machine(name: "imac01", address: "imac01.local", user: "imac01")]),
                              encoding: .utf8)!
        try (String(good.dropLast()) + #",{"name":"imac02"}]"#).write(to: url, atomically: true, encoding: .utf8)
        #expect {
            try ConfigStore.importHosts(from: url)
        } throws: { error in
            error.localizedDescription.contains("wpis nr 2")
        }
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

/// action-log-crash (AUDIT WSP-01): appending to the action log reports a failed write instead of raising an
/// Objective-C exception (which ended the app on a full disk); the e2e suite core-runtime covers the real limit.
struct ActionLogTests {
    @Test func appendingCreatesAndExtendsWithoutTruncating() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("actions.log")
        #expect(ConfigStore.append(Data("a\n".utf8), to: url))
        #expect(ConfigStore.append(Data("b\n".utf8), to: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\nb\n")
    }

    /// AUDIT PLI-17: a file name with a line break cannot add a forged entry to the action log.
    @Test func anEntryStaysOnOneLine() {
        let name = "praca\n2026-10-28T10:00:00Z Podgląd ekranu → imac05"
        let text = String(decoding: ConfigStore.logEntry("Usuń „\(name)” z /Users/student", at: Date(timeIntervalSince1970: 0)), as: UTF8.self)
        #expect(text.split(separator: "\n").count == 1)
        #expect(text.hasPrefix("1970-01-01T00:00:00Z Usuń „praca\\n2026"))
    }

    @Test func aFailedWriteIsReportedNotRaised() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A folder where the log should be: open() fails – reported as false, nothing thrown.
        let url = dir.appendingPathComponent("actions.log", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(!ConfigStore.append(Data("x\n".utf8), to: url))
    }
}
