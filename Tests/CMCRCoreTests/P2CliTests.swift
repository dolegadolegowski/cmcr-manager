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

struct P2CliWakeTests {
    /// AUDIT KOM-13: cmcrctl wake prefers the Ethernet MAC, like the app.
    @Test func ethernetMACFirstThenListThenDefaultRoute() {
        let info = ["mac_ethernet": "AA-BB-CC-00-11-22", "mac": "a4:83:e7:00:00:01", "ip": "10.0.5.23"]
        #expect(WakeOnLAN.candidateMACs(listed: "0:1b:63:84:45:e6", lastStatus: info)
                == ["aa:bb:cc:00:11:22", "00:1b:63:84:45:e6"])
        #expect(WakeOnLAN.lastSeenBroadcasts(info) == ["10.0.5.255"])
        // Without a wired port: the list's MAC, then the default route's.
        #expect(WakeOnLAN.candidateMACs(listed: "0:1b:63:84:45:e6", lastStatus: ["mac": "a4:83:e7:00:00:01"])
                == ["00:1b:63:84:45:e6", "a4:83:e7:00:00:01"])
    }

    @Test func repeatsAndInvalidAddressesAreDropped() {
        let info = ["mac_ethernet": "", "mac": "aa:bb:cc:00:11:22"]
        #expect(WakeOnLAN.candidateMACs(listed: "AA:BB:CC:00:11:22", lastStatus: info) == ["aa:bb:cc:00:11:22"])
        #expect(WakeOnLAN.candidateMACs(listed: "xyz", lastStatus: [:]).isEmpty)
        #expect(WakeOnLAN.lastSeenBroadcasts([:]).isEmpty)
    }

    /// What `cmcrctl status` stores for a Mac without a MAC (HostStatus.mac, as in the app): the wired port first.
    @Test func statusRemembersTheEthernetMAC() {
        var st = HostStatus()
        st.info = ["mac": "a4:83:e7:00:00:01", "mac_ethernet": "aa:bb:cc:00:11:22"]
        #expect(st.mac == "aa:bb:cc:00:11:22")
        st.info["mac_ethernet"] = ""
        #expect(st.mac == "a4:83:e7:00:00:01")
    }
}
