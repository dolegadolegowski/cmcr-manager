import Foundation
import Testing
@testable import CMCRCore

// Core helpers behind the P2 fixes of cmcrctl (AUDIT P2, package cli). The commands themselves are covered by
// Tests/e2e/suites/p2-cli.sh.

private func p2TemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-p2cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct P2CliTests {
    /// AUDIT CLI-10: `hosts generate --replace` over an unreadable hosts.json keeps the original first.
    @Test func damagedHostsFileIsCopiedBeforeItIsReplaced() throws {
        let dir = try p2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hosts.json")
        let original = Data(#"[{"name":"sala1","address":"sala1.local","macAddress":"aa:bb:cc:dd:ee:ff"},{"name":"x"}]"#.utf8)
        try original.write(to: url)
        let backup = try #require(ConfigStore.backupHostsFile(at: url))
        #expect(backup.lastPathComponent.hasPrefix("hosts.json."))
        #expect(backup.pathExtension == "bak")
        #expect(try Data(contentsOf: backup) == original)
        // The same content is kept once.
        #expect(ConfigStore.backupHostsFile(at: url)?.lastPathComponent == backup.lastPathComponent)
    }

    @Test func noBackupWithoutAReadableHostsFile() throws {
        let dir = try p2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ConfigStore.backupHostsFile(at: dir.appendingPathComponent("hosts.json")) == nil)
    }
}
