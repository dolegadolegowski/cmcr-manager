import Foundation
import Testing
@testable import CMCRCore

@Suite struct HostEntryTests {
    @Test(arguments: ["imac04", "imac04.local", "10.0.1.4", "fe80::1%en0", "uczeń", "admin_2"])
    func acceptsSSHParts(value: String) {
        #expect(HostEntry.problem(value, as: .sshPart) == nil)
    }

    @Test(arguments: ["", " ", "a b", "imac04\t", "a\nb", "-oProxyCommand=x", "-", "x@y", "\u{7}"])
    func rejectsSSHParts(value: String) {
        #expect(HostEntry.problem(value, as: .sshPart) != nil)
    }

    @Test func namesMayHaveSpacesButNoCommasOrControls() {
        #expect(HostEntry.problem("iMac nauczyciela", as: .name) == nil)
        #expect(HostEntry.problem("a,b", as: .name)?.contains("przecinek") == true)
        #expect(HostEntry.problem("a\nb", as: .name) != nil)
        #expect(HostEntry.problem("", as: .name) != nil)
        #expect(HostEntry.problem("-x", as: .name) != nil)
    }

    @Test func domainMayBeEmpty() {
        #expect(HostEntry.problem("", as: .domain) == nil)
        #expect(HostEntry.problem("lab.szkola.pl", as: .domain) == nil)
        #expect(HostEntry.problem("lab szkola", as: .domain) != nil)
        #expect(HostEntry.problem("-x", as: .domain) != nil)
    }

    @Test(arguments: [
        ("00:1b:63:84:45:e6", "00:1b:63:84:45:e6"), ("00-1B-63-84-45-E6", "00:1b:63:84:45:e6"),
        ("001b.6384.45e6", "00:1b:63:84:45:e6"), (" 001B638445E6 ", "00:1b:63:84:45:e6"),
        // `arp -a` drops leading zeros in each group.
        ("0:1b:63:84:45:e6", "00:1b:63:84:45:e6"), ("0:1b:3:4:5:e", "00:1b:03:04:05:0e"),
    ])
    func normalizesMACs(raw: String, expected: String) {
        #expect(HostEntry.normalizedMAC(raw) == expected)
    }

    @Test(arguments: ["", "0:1b:63:84:45", "0:1b:63:84:45:e6:7", "000:1b:63:84:45:e6", "zz:1b:63:84:45:e6", "0::63:84:45:e6", "+1:1b:63:84:45:e6",
                           "+01b638445e6"])
    func rejectsInvalidMACs(raw: String) {
        #expect(HostEntry.normalizedMAC(raw) == nil)
    }
}
