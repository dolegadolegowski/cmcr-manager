import Foundation
import Testing
@testable import CMCRCore

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func bashSyntaxCheck(_ text: String) throws -> Bool {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-setup-test-\(UUID().uuidString).sh")
    try text.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-n", url.path]
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}

private let testKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDdtiSxiX/5C8QZGgQhHVN+qsuG6QgBNdbXqFQMUqFft cmcr-test"

@Test func embeddedSetupScriptMatchesRepository() throws {
    let file = try String(contentsOf: repoRoot.appendingPathComponent("setup/cmcr-imac-setup.sh"), encoding: .utf8)
    #expect(SetupScript.template == file, "Run scripts/embed-setup.sh after changing setup/cmcr-imac-setup.sh")
}

@Test func setupScriptVersionIsParsedFromTemplate() {
    let parts = SetupScript.version.split(separator: ".")
    #expect(parts.count == 3 && parts.allSatisfy { Int($0) != nil })
    #expect(SetupScript.template.contains("CMCR_SETUP_VERSION=\"\(SetupScript.version)\""))
}

@Test func standaloneCopyOnlyReplacesDefaultsBlock() throws {
    var o = SetupOptions()
    o.enableVNC = true
    o.setHostname = true
    o.scheduleMode = .set
    var settings = AppSettings()
    settings.studentUser = "uczen"
    settings.sharedFolder = "/Users/{student}/Public/cmcr"
    let text = SetupScript.standalone(o, settings: settings, publicKey: testKey + "\n")
    #expect(text.contains("OPT_PUBKEYS='\(testKey)'"))
    #expect(text.contains("OPT_STUDENT='uczen'"))
    #expect(text.contains("OPT_SHARED='/Users/uczen/Public/cmcr'"))
    #expect(text.contains("OPT_VNC=1"))
    #expect(text.contains("OPT_HOSTNAME='auto'"))
    #expect(text.contains("OPT_POWER_SCHEDULE='MTWRF 07:30 17:00 shutdown'"))
    #expect(try bashSyntaxCheck(text))

    func outsideBlock(_ s: String) -> [String] {
        var inside = false
        return s.components(separatedBy: "\n").filter { line in
            if line.hasPrefix("# >>> CMCR-DEFAULTS") { inside = true }
            defer { if line.hasPrefix("# <<< CMCR-DEFAULTS") { inside = false } }
            return !inside && !line.hasPrefix("# <<< CMCR-DEFAULTS")
        }
    }
    #expect(outsideBlock(text) == outsideBlock(SetupScript.template))

    var noKey = o
    noKey.installKey = false
    #expect(SetupScript.standalone(noKey, settings: settings, publicKey: testKey).contains("OPT_PUBKEYS=''"))
}

@Test func remoteArgumentsFollowOptionsAndHost() {
    let host = Machine(name: "imac07", address: "imac07.local", user: "imac07")
    var o = SetupOptions()
    var a = SetupScript.arguments(o, host: host, settings: AppSettings(), publicKey: testKey, mode: .apply)
    #expect(Array(a.prefix(6)) == ["--admin", "imac07", "--student", "student", "--shared-folder", "/Users/student/Public/cmcr"])
    #expect(a.contains("--no-guide"))
    #expect(a.contains(testKey))
    #expect(!a.contains("--hostname") && !a.contains("--verify") && !a.contains("--power-schedule"))

    o.setHostname = true
    o.restrictSSH = false
    o.sudo = .requirePassword
    o.scheduleMode = .off
    o.updates = .download
    o.installKey = false
    a = SetupScript.arguments(o, host: host, settings: AppSettings(), publicKey: testKey, mode: .verify)
    #expect(a.contains("--no-ssh-acl") && a.contains("--no-sudo-nopasswd") && a.contains("--verify"))
    #expect(a.firstIndex(of: "--hostname").map { a[$0 + 1] } == "imac07")
    #expect(a.firstIndex(of: "--power-schedule").map { a[$0 + 1] } == "off")
    #expect(a.firstIndex(of: "--updates").map { a[$0 + 1] } == "download")
    #expect(!a.contains("--pubkey"))
}

@Test func hostnameFollowsAddressNotListName() {
    // The list name is free text; renaming must keep the address the app connects to.
    let renamed = Machine(name: "iMac 7 (okno)", address: "imac07.local", user: "imac07")
    #expect(SetupScript.hostname(for: renamed) == "imac07")
    #expect(SetupScript.hostname(for: Machine(name: "imac7", address: "iMac07.LOCAL", user: "imac07")) == "iMac07")
    #expect(SetupScript.hostname(for: Machine(name: "imac07", address: "192.168.1.27", user: "imac07")) == nil)
    #expect(SetupScript.hostname(for: Machine(name: "imac07", address: "imac07.szkola.pl", user: "imac07")) == nil)
    #expect(SetupScript.hostname(for: Machine(name: "imac07", address: "imac_07.local", user: "imac07")) == nil)
    #expect(SetupScript.hostname(for: Machine(name: "imac07", address: "-imac.local", user: "imac07")) == nil)
    #expect(SetupScript.hostname(for: Machine(name: "imac07", address: ".local", user: "imac07")) == nil)

    var o = SetupOptions()
    o.setHostname = true
    var a = SetupScript.arguments(o, host: renamed, settings: AppSettings(), publicKey: nil, mode: .apply)
    #expect(a.firstIndex(of: "--hostname").map { a[$0 + 1] } == "imac07")
    let byIP = Machine(name: "Sala 12", address: "10.0.0.12", user: "imac12")
    a = SetupScript.arguments(o, host: byIP, settings: AppSettings(), publicKey: nil, mode: .apply)
    #expect(!a.contains("--hostname"))
}

@Test func versionsCompareNumerically() {
    #expect(SetupScript.compareVersions("1.10.0", "1.9.2") == .orderedDescending)
    #expect(SetupScript.compareVersions("0.9.0", "1.0.0") == .orderedAscending)
    #expect(SetupScript.compareVersions("1.0", "1.0.0") == .orderedSame)
    #expect(SetupScript.compareVersions("2.0.0-beta", "2.0.0") == .orderedSame)
}

@Test func remoteScriptRunsEmbeddedCopyAsRoot() throws {
    let host = Machine(name: "imac07", address: "imac07.local", user: "imac07")
    let script = SetupScript.remote(SetupOptions(), host: host, settings: AppSettings(), publicKey: testKey, mode: .dryRun)
    #expect(script.asRoot)
    #expect(script.body.contains(Data(SetupScript.template.utf8).base64EncodedString()))
    #expect(script.body.contains("'--dry-run'"))
    #expect(try bashSyntaxCheck(script.render()))
}

@Test func setupCommandLineParsesOptions() throws {
    let cl = try SetupCommandLine(parsing: ["3", "--enable-vnc", "--power-schedule", "MTWRF 07:15 16:30 sleep",
                                            "--updates", "auto", "--no-key", "--verify", "--display-sleep", "15"])
    #expect(cl.positional == ["3"])
    #expect(cl.mode == .verify)
    #expect(cl.options.enableVNC && !cl.options.installKey)
    #expect(cl.options.powerScheduleArgument == "MTWRF 07:15 16:30 sleep")
    #expect(cl.options.updates == .auto)
    #expect(cl.options.displaySleepMinutes == 15)

    #expect(throws: SetupCommandLine.ParseError.self) { try SetupCommandLine(parsing: ["--bogus"]) }
    #expect(throws: SetupCommandLine.ParseError.self) { try SetupCommandLine(parsing: ["--power-schedule", "MTWXF 07:30"]) }
    #expect(throws: SetupCommandLine.ParseError.self) { try SetupCommandLine(parsing: ["--power-schedule", "MTWRF 25:00"]) }
    #expect(throws: SetupCommandLine.ParseError.self) { try SetupCommandLine(parsing: ["--updates"]) }
    #expect(throws: SetupCommandLine.ParseError.self) { try SetupCommandLine(parsing: ["--ssh-key-only", "--no-key"]) }
}

@Test func setupOptionsDecodeOlderFiles() throws {
    let o = try JSONDecoder().decode(SetupOptions.self, from: Data(#"{"enableVNC": true}"#.utf8))
    #expect(o.enableVNC && o.installKey && o.wakeOnLAN && o.scheduleMode == .unchanged)
    var changed = SetupOptions()
    changed.sudo = .passwordless
    changed.displaySleepMinutes = 20
    let round = try JSONDecoder().decode(SetupOptions.self, from: JSONEncoder().encode(changed))
    #expect(round == changed)
}

@Test func setupReportIsParsedFromOutput() throws {
    let output = """
    ✔ Konto administracyjne: imac07.
    -----BEGIN CMCR SETUP JSON-----
    {"schema": 1, "version": "1.0.0", "mode": "apply", "host": "imac07", "via_ssh": true,
     "fda_remote": "no", "screen_capture_remote": "unknown", "result": "todo",
     "changed_count": 3, "pending_count": 0, "todo_count": 2, "fail_count": 0,
     "steps": [{"id": "ssh", "status": "changed", "message": "Włączono"}, {"id": "tcc_fda", "status": "todo", "message": "Ręcznie"}]}
    -----END CMCR SETUP JSON-----
    """
    let r = try #require(SetupReport.parse(output))
    #expect(r.viaSsh == true && r.fdaRemote == "no" && r.result == "todo")
    #expect(r.manualSteps.map(\.id) == ["tcc_fda"])
    #expect(r.summary == "Zmieniono 3 ustawienia; kroki ręczne przy komputerze: 2.")
    #expect(SetupReport.parse("bez raportu") == nil)
}

@Test func polishPluralForms() {
    #expect(polishCount(1, "ustawienie", "ustawienia", "ustawień") == "1 ustawienie")
    #expect(polishCount(3, "ustawienie", "ustawienia", "ustawień") == "3 ustawienia")
    #expect(polishCount(12, "ustawienie", "ustawienia", "ustawień") == "12 ustawień")
    #expect(polishCount(22, "ustawienie", "ustawienia", "ustawień") == "22 ustawienia")
}

@Test func readinessReportMarksReadyMac() {
    let text = """
    os=15.6
    admin=imac07
    console=student
    key=ok
    folder=ok
    wol=on
    vnc=off
    filevault=off
    fda=yes
    setup=\(SetupScript.version)
    setup_result=todo
    sudo=ok
    tcc=readable
    tcc_fda=2
    tcc_screen=2
    """
    let r = ReadinessReport.parse(text, student: "student", sharedFolder: "/Users/student/Public/cmcr")
    #expect(r.isReady)
    #expect(r[.vnc].state == .off)
    #expect(r[.screen].state == .ok)
    #expect(r.fixableBySetup.isEmpty && r.needsVisit.isEmpty)
}

@Test func readinessReportExplainsProblems() {
    let text = """
    admin=imac07
    console=
    key=missing
    folder=perm root 755
    wol=off
    vnc=on
    filevault=on
    fda=no
    setup=0.9.0
    sudo=badpassword
    """
    let r = ReadinessReport.parse(text, student: "student", sharedFolder: "/Users/student/Public/cmcr")
    #expect(!r.isReady)
    #expect(r[.ssh].state == .warning)
    #expect(r[.sudo].state == .problem && r[.sudo].short == "złe hasło")
    #expect(r[.folder].state == .warning && r[.folder].detail.contains("root"))
    #expect(r[.wol].state == .problem)
    #expect(r[.fda].state == .manual)
    #expect(r[.screen].state == .unknown)
    #expect(r[.filevault].state == .warning)
    #expect(r[.setup].state == .warning && r[.setup].short == "v0.9.0")
    #expect(r.needsVisit == [.fda])
    #expect(r.fixableBySetup == [.ssh, .folder, .wol, .setup])

    let off = ReadinessReport.unreachable("Komputer nie odpowiada.")
    #expect(off[.ssh].state == .problem && off[.ssh].detail == "Komputer nie odpowiada.")
    #expect(off[.wol].state == .unknown)
}

@Test func readinessSetupVersionNewerThanAppIsNotOutdated() {
    let base = "admin=imac07\nkey=ok\nfolder=ok\nsudo=ok\n"
    let newer = ReadinessReport.parse(base + "setup=1.10.0\n", student: "student", sharedFolder: "/Users/student/Public/cmcr",
                                      expectedVersion: "1.9.0")
    #expect(newer[.setup].state == .ok)
    #expect(newer[.setup].detail.contains("nowszą") && !newer[.setup].detail.contains("starszą"))
    #expect(!newer.fixableBySetup.contains(.setup))
    let older = ReadinessReport.parse(base + "setup=1.9.0\n", student: "student", sharedFolder: "/Users/student/Public/cmcr",
                                      expectedVersion: "1.10.0")
    #expect(older[.setup].state == .warning && older[.setup].detail.contains("starszą"))
}

@Test func unreachableReportClassifiesConnectionFailure() {
    func result(_ stderr: String, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: 255, stderr: Data(stderr.utf8), timedOut: timedOut)
    }
    let changed = ReadinessReport.unreachable(result("""
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        Host key verification failed.
        """))
    #expect(changed.connectionFailure == .hostKeyChanged && changed[.ssh].state == .problem)
    #expect(ReadinessReport.unreachable(result("imac07@imac07.local: Permission denied (publickey,password).")).connectionFailure == .authFailed)
    #expect(ReadinessReport.unreachable(result("ssh: connect to host imac07.local port 22: Operation timed out")).connectionFailure == .offline)
    #expect(ReadinessReport.unreachable(result("", timedOut: true)).connectionFailure == .offline)
    #expect(ReadinessReport.unreachable(result("ssh: connect to host imac07.local port 22: Connection refused")).connectionFailure == .other)
    #expect(ReadinessReport.parse("key=ok\n", student: "student", sharedFolder: "/Users/student/Public/cmcr").connectionFailure == nil)
}

@Test func readinessScriptIsValidBash() throws {
    let s = Scripts.readiness(student: "student", sharedFolder: "/Users/student/Public/cmcr", publicKey: testKey)
    #expect(!s.asRoot)
    #expect(s.body.contains("KEYBLOB='AAAAC3NzaC1lZDI1NTE5AAAAIDdtiSxiX/5C8QZGgQhHVN+qsuG6QgBNdbXqFQMUqFft'"))
    #expect(try bashSyntaxCheck(s.render()))
}

@Test func studentWithoutHomeNeedsVisitNotRootFolder() throws {
    let r = ReadinessReport.parse("admin=imac07\nfolder=nohome\nsudo=ok\n", student: "student",
                                  sharedFolder: "/Users/student/Public/cmcr")
    #expect(r[.folder].state == .manual && r[.folder].detail.contains("zalogował"))
    #expect(!r.fixableBySetup.contains(.folder) && r.needsVisit.contains(.folder))
    let fix = Scripts.createStudentFolder("/Users/student/Public/cmcr", owner: "student")
    #expect(fix.asRoot && fix.body.contains("DIR=\"$R\"'/Users/student/Public/cmcr'"))
    #expect(try bashSyntaxCheck(fix.render()))
}

@Test func sharedFolderOutsideHomesIsReported() {
    var s = AppSettings()
    #expect(SetupScript.sharedFolderProblem(s) == nil)
    s.sharedFolder = "/tmp/cmcr"
    #expect(SetupScript.sharedFolderProblem(s) != nil)
    s.sharedFolder = "/Users/student/../root"
    #expect(SetupScript.sharedFolderProblem(s) != nil)
}
