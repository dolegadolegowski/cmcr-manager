import Foundation
import Testing
@testable import CMCRCore

@Suite struct MachineTests {
    @Test func generateMirrorsCmcrHelpersLoop() {
        let hosts = Machine.generate()
        #expect(hosts.count == 15)
        #expect(hosts.map(\.name) == (1...15).map { String(format: "imac%02d", $0) })
        #expect(hosts[3].destination == "imac04@imac04.local")
        #expect(hosts.allSatisfy { $0.port == 22 && $0.usesSharedPassword && $0.macAddress.isEmpty })
        #expect(Set(hosts.map(\.id)).count == 15)
    }

    @Test func generateWithOptions() {
        let hosts = Machine.generate(prefix: "lab", start: 9, count: 3, digits: 3, domain: "")
        #expect(hosts.map(\.name) == ["lab009", "lab010", "lab011"])
        #expect(hosts.map(\.address) == ["lab009", "lab010", "lab011"])
        #expect(hosts.map(\.user) == ["lab009", "lab010", "lab011"])
        #expect(Machine.generate(count: 0).isEmpty)
        #expect(Machine.generate(prefix: "m", start: 7, count: 1, digits: 0).first?.name == "m7")
        #expect(Machine.generate(prefix: "pc", count: 1, domain: "szkola.lan").first?.destination == "pc01@pc01.szkola.lan")
    }

    @Test(arguments: [("imac04", 4), ("imac15", 15), ("lab-120", 120), ("7", 7)])
    func numberFromName(name: String, number: Int) {
        #expect(Machine(name: name, address: "x", user: "u").number == number)
    }

    @Test(arguments: ["imac", "imac04b", ""])
    func noNumberInName(name: String) {
        #expect(Machine(name: name, address: "x", user: "u").number == nil)
    }

    @Test func decodingFillsDefaults() throws {
        let m = try JSONDecoder().decode(Machine.self, from: Data(#"{"address":"imac03.local"}"#.utf8))
        #expect(m.name == "imac03.local")
        #expect(m.user == NSUserName())
        #expect(m.port == 22)
        #expect(m.macAddress == "")
        #expect(m.notes == "")
        #expect(m.usesSharedPassword)
    }

    @Test func decodingRequiresAddress() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Machine.self, from: Data(#"{"name":"imac03"}"#.utf8))
        }
    }

    @Test func roundTripKeepsEveryField() throws {
        let m = Machine(name: "imac05", address: "10.0.0.5", user: "admin", port: 2222, macAddress: "aa:bb:cc:dd:ee:ff",
                        notes: "sala 12 – „okno”", usesSharedPassword: false)
        let back = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(m))
        #expect(back == m)
    }

    @Test func decodesHostsFileWithUnknownKeys() throws {
        let json = #"[{"id":"11111111-1111-1111-1111-111111111111","name":"a","address":"a.local","user":"a","future":1}]"#
        let hosts = try JSONDecoder().decode([Machine].self, from: Data(json.utf8))
        #expect(hosts.first?.id.uuidString == "11111111-1111-1111-1111-111111111111")
    }
}

@Suite struct AppSettingsTests {
    @Test func emptyJSONGivesDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s == AppSettings())
        #expect(s.studentUser == "student")
        #expect(s.sharedFolder == "/Users/student/Public/cmcr")
        #expect(s.localFolder == "~/Public/cmcr")
        #expect(s.connectTimeout == 5)
        #expect(s.maxParallel == 8)
        #expect(s.observeOnlyStandardAccounts)
        #expect(s.notifyOnObserve)
        #expect(s.snippets.isEmpty)
    }

    @Test func partialJSONKeepsOtherDefaults() throws {
        let json = #"{"studentUser":"uczen","maxParallel":3,"notifyOnObserve":false,"somethingNew":"x"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.studentUser == "uczen")
        #expect(s.maxParallel == 3)
        #expect(!s.notifyOnObserve)
        #expect(s.screenshotQuality == AppSettings().screenshotQuality)
        #expect(s.sharedFolder == AppSettings().sharedFolder)
    }

    @Test func roundTrip() throws {
        var s = AppSettings()
        s.extraSSHOptions = "ProxyJump=bastion"
        s.snippets = [Snippet(category: "K", name: "N", command: "echo 'x'", asRoot: true)]
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func resolveReplacesStudentPlaceholder() {
        var s = AppSettings()
        s.studentUser = "uczen"
        #expect(s.resolve("/Users/{student}/Public/{student}") == "/Users/uczen/Public/uczen")
        #expect(s.resolve("/Users/{console}/Desktop") == "/Users/{console}/Desktop")
    }

    @Test func extraSSHOptionListSkipsCommentsAndDashO() {
        var s = AppSettings()
        s.extraSSHOptions = "ProxyJump=bastion\n  # komentarz\n\n-o ServerAliveInterval=30\n-oCompression=yes\r\n  IdentitiesOnly=yes  "
        #expect(s.extraSSHOptionList == ["ProxyJump=bastion", "ServerAliveInterval=30", "Compression=yes", "IdentitiesOnly=yes"])
        #expect(AppSettings().extraSSHOptionList.isEmpty)
    }

    @Test func observeAllowedUserList() {
        var s = AppSettings()
        s.observeAllowedUsers = " student , ,uczen,,"
        #expect(s.observeAllowedUserList == ["student", "uczen"])
        #expect(AppSettings().observeAllowedUserList.isEmpty)
    }

    @Test func sshSettingsFromAppSettings() {
        var s = AppSettings()
        s.identityFile = "~/.ssh/id_lab"
        s.connectTimeout = 9
        s.extraSSHOptions = "A=b"
        let ss = SSHSettings(s, askpassPath: "/tmp/askpass")
        #expect(ss.identityFile == "~/.ssh/id_lab")
        #expect(ss.connectTimeout == 9)
        #expect(ss.extraOptions == ["A=b"])
        let options = SSH.options(ss, password: nil)
        #expect(options.contains("BatchMode=yes"))
        #expect(options.contains("ConnectTimeout=9"))
        #expect(options.contains(expandTilde("~/.ssh/id_lab")))
        #expect(SSH.options(ss, password: "x").contains("BatchMode=no"))
    }
}

@Suite struct HostStatusTests {
    @Test func derivedFields() {
        var st = HostStatus()
        st.info = Parsers.keyValues("os=15.1\nconsole=\nmac=aa:bb:cc:dd:ee:ff\ndisk=1048576000 524288000\nadmin=yes\nboot=0\n")
        #expect(st.osVersion == "15.1")
        #expect(st.consoleUser == nil)
        #expect(st.mac == "aa:bb:cc:dd:ee:ff")
        #expect(st.isAdmin)
        #expect(st.diskText == "500 / 1000 GB wolne")
        #expect(st.bootDate == Date(timeIntervalSince1970: 0))
    }
}
