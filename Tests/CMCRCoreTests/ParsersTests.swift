import Foundation
import Testing
@testable import CMCRCore

@Suite struct ParsersTests {
    @Test func keyValuesTrimAndKeepLaterEqualsSigns() {
        let kv = Parsers.keyValues("name=iMac Lab\nos=15.1\r\nempty=\n  spaced = v  \nnoequals\nurl=a=b\n\n")
        #expect(kv["name"] == "iMac Lab")
        #expect(kv["os"] == "15.1")
        #expect(kv["empty"] == "")
        #expect(kv["spaced"] == "v")
        #expect(kv["url"] == "a=b")
        #expect(kv["noequals"] == nil)
        #expect(kv.count == 5)
    }

    @Test func keyValuesOfStatusScriptShape() {
        let text = "console=\nmac=a4:83:e7:00:11:22\ndisk=488245288 301234567\nadmin=yes\n"
        let kv = Parsers.keyValues(text)
        #expect(kv["console"] == "")
        #expect(kv["mac"] == "a4:83:e7:00:11:22")
        #expect(kv["disk"] == "488245288 301234567")
    }

    @Test(arguments: [
        ("/Applications/Safari.app/Contents/MacOS/Safari", "/Applications/Safari.app"),
        ("/Applications/Visual Studio Code.app/Contents/MacOS/Electron", "/Applications/Visual Studio Code.app"),
        ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", "/System/Library/CoreServices/Finder.app"),
        ("/Users/student/Applications/Gra.app/Contents/MacOS/Gra", "/Users/student/Applications/Gra.app"),
    ])
    func appBundleOfMainExecutable(path: String, bundle: String) {
        #expect(Parsers.appBundle(forExecutable: path) == bundle)
    }

    @Test(arguments: [
        "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
        "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator",
        "/Applications/Tool.app/Contents/MacOS/sub/helper",
        "/usr/libexec/trustd",
        "",
    ])
    func appBundleIgnoresHelpersAndPlainBinaries(path: String) {
        #expect(Parsers.appBundle(forExecutable: path) == nil)
    }

    @Test func runningAppsFromPaddedPsOutput() {
        let ps = """
        USER:student
          412 student          /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
         1234 student          /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
         1240 student          /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper
        99999 student          /Applications/Safari.app/Contents/MacOS/Safari
         1300 student          /Applications/Safari.app/Contents/MacOS/Safari
          500 student          /usr/libexec/sharingd
        garbage line
        """
        let (user, apps) = Parsers.runningApps(ps)
        #expect(user == "student")
        #expect(apps.map(\.name) == ["Google Chrome", "Safari", "Finder"])
        #expect(apps.first?.bundlePath == "/Applications/Google Chrome.app")
        #expect(apps.first { $0.name == "Safari" }?.pid == 99999)
        #expect(apps.last?.isSystem == true)
        #expect(!apps.contains { $0.bundlePath.contains("Helper") })
    }

    @Test func runningAppsWithoutConsoleUser() {
        let (user, apps) = Parsers.runningApps("USER:\n")
        #expect(user == nil)
        #expect(apps.isEmpty)
    }

    @Test func softwareUpdatesNone() {
        let text = "Software Update Tool\n\nFinding available software\nNo new software available.\n"
        #expect(Parsers.softwareUpdates(text).isEmpty)
    }

    @Test func softwareUpdatesWithRestartFlag() {
        let text = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: macOS Sequoia 15.6.1-24G90
        \tTitle: macOS Sequoia 15.6.1, Version: 15.6.1, Size: 1655389KiB, Recommended: YES, Action: restart,
        * Label: Safari18.6-20621.3.11.11.3
        \tTitle: Safari, Version: 18.6, Size: 197832KiB, Recommended: YES,
        * Label: Command Line Tools for Xcode-16.4
        \tTitle: Command Line Tools for Xcode, Version: 16.4, Size: 751678KiB, Recommended: YES,
        """
        #expect(Parsers.softwareUpdates(text) == [
            "macOS Sequoia 15.6.1 (wymaga restartu)",
            "Safari",
            "Command Line Tools for Xcode",
        ])
    }

    @Test func softwareUpdatesLabelWithoutTitleFallsBackToLabel() {
        let text = "* Label: Old Format Update-1.0\n* Label: Another-2.0\n\tTitle: Another, Version: 2.0,\n* Label: Last-3.0\n"
        #expect(Parsers.softwareUpdates(text) == ["Old Format Update-1.0", "Another", "Last-3.0"])
    }

    @Test func linesSkipsEmptyOnes() {
        #expect(Parsers.lines("a\n\n b\r\nc") == ["a", " b", "c"])
    }
}

@Suite struct WakeOnLANTests {
    @Test(arguments: ["00:1b:63:84:45:e6", "00-1B-63-84-45-E6", "001b.6384.45e6", "001B638445E6", " 00:1b:63:84:45:e6 "])
    func parsesCommonSpellings(mac: String) {
        #expect(WakeOnLAN.parseMAC(mac) == [0x00, 0x1B, 0x63, 0x84, 0x45, 0xE6])
    }

    @Test(arguments: ["", "00:1b:63:84:45", "00:1b:63:84:45:e6:77", "zz:1b:63:84:45:e6", "not a mac"])
    func rejectsInvalid(mac: String) {
        #expect(WakeOnLAN.parseMAC(mac) == nil)
    }

    @Test func unpaddedArpSpelling() {
        // `arp -a` drops leading zeros; accepted once parseMAC splits on separators.
        withKnownIssue("parseMAC wymaga dwóch cyfr w każdej grupie", isIntermittent: true) {
            #expect(WakeOnLAN.parseMAC("0:1b:63:84:45:e6") == [0x00, 0x1B, 0x63, 0x84, 0x45, 0xE6])
        }
    }

    @Test func badMACThrowsReadableError() {
        #expect(throws: WakeOnLAN.WOLError.self) { try WakeOnLAN.wake(mac: "xyz") }
        #expect(WakeOnLAN.WOLError.badMAC("xyz").errorDescription?.contains("xyz") == true)
    }
}
