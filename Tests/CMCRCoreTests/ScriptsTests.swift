import Foundation
import Testing
@testable import CMCRCore

@Test func argumentsSplitLikeAShell() {
    #expect(Scripts.splitArguments("") == [])
    #expect(Scripts.splitArguments("  -projectPath   /Users/student/Gra  ") == ["-projectPath", "/Users/student/Gra"])
    #expect(Scripts.splitArguments(#"a "b c" 'd e'\ f"#) == ["a", "b c", "d e f"])
    #expect(Scripts.splitArguments(#"'$(rm -rf ~)' "x;y""#) == ["$(rm -rf ~)", "x;y"])
    #expect(Scripts.splitArguments(#""a\"b" "c\d""#) == [#"a"b"#, #"c\d"#])
    #expect(Scripts.splitArguments(#"''"#) == [""])
}

@Test func launchAppQuotesEveryArgument() {
    let body = Scripts.launchApp("Unity", arguments: #"-projectPath "/Users/student/Moja gra"; echo"#).body
    #expect(body.contains(#"/usr/bin/open -n -a "$APP" --args '-projectPath' '/Users/student/Moja gra;' 'echo'"#))
    #expect(Scripts.launchApp("Safari").body.contains(#"/usr/bin/open -a "$APP""#))
    #expect(Scripts.launchApp("Unity", arguments: "-batchmode", newInstance: false).body.contains(#"open -a "$APP" --args"#))
}

@Test func numericModesKeepFoldersOpenable() {
    #expect(Scripts.dirSafeMode("777") == "u=rwX,g=rwX,o=rwX")
    #expect(Scripts.dirSafeMode("755") == "u=rwX,g=rX,o=rX")
    #expect(Scripts.dirSafeMode("644") == "u=rwX,g=rX,o=rX")
    #expect(Scripts.dirSafeMode("0700") == "u=rwX,g=,o=")
    #expect(Scripts.dirSafeMode("u=rw,go=r") == "u=rw,go=r")
    #expect(Scripts.dirSafeMode("") == "")
    #expect(Scripts.dirSafeMode("1777") == "1777")
}

@Test func numericModeTranslationMatchesChmod() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-mode-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let sub = dir.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let file = sub.appendingPathComponent("a.txt")
    try Data("x".utf8).write(to: file)
    func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    for (numeric, dirMode, fileMode) in [("644", 0o755, 0o644), ("700", 0o700, 0o600), ("777", 0o777, 0o666)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["-R", Scripts.dirSafeMode(numeric), sub.path]
        try p.run()
        p.waitUntilExit()
        #expect(try mode(sub) == dirMode, "folder for \(numeric)")
        #expect(try mode(file) == fileMode, "file for \(numeric)")
    }
}

@Test func distributeKeyUsesOnlyTheFirstLine() {
    let body = Scripts.distributeKey("ssh-ed25519 AAAAKEY cmcr\nrm -rf ~\n").body
    #expect(body.contains("KEY='ssh-ed25519 AAAAKEY cmcr'"))
    #expect(!body.contains("rm -rf ~"))
}

@Test func statusAccessorsParseInventory() {
    let text = """
    os=26.1
    lhn=imac04-2
    serial=C02XYZ
    mac=aa:aa:aa:aa:aa:01
    mac_ethernet=bb:bb:bb:bb:bb:02
    macs=en0:bb:bb:bb:bb:bb:02,en1:aa:aa:aa:aa:aa:01
    filevault=on
    sip=off
    firewall=blockall
    womp=1
    power_schedule=wakepoweron at 7:30AM weekdays only; shutdown at 5:00PM weekdays only
    last_user=student
    last_login=2026-10-05 08:12
    unity=6000.3.7f1,2022.3.10f1
    setup_version=1.0.0
    setup_todo=2
    fda=no
    """
    var st = HostStatus()
    st.info = Parsers.keyValues(text)
    #expect(st.mac == "bb:bb:bb:bb:bb:02")
    #expect(st.primaryMAC == "aa:aa:aa:aa:aa:01")
    #expect(st.macAddresses.map(\.device) == ["en0", "en1"])
    #expect(st.macAddresses.first?.mac == "bb:bb:bb:bb:bb:02")
    #expect(st.localHostName == "imac04-2")
    #expect(st.serialNumber == "C02XYZ")
    #expect(st.fileVaultOn == true)
    #expect(st.sipEnabled == false)
    #expect(st.firewall == "blockall")
    #expect(st.wakeOnLANEnabled == true)
    #expect(st.powerSchedule?.hasPrefix("wakepoweron") == true)
    #expect(st.lastConsoleUser == "student")
    #expect(st.lastConsoleLogin != nil)
    #expect(st.unityEditors == ["6000.3.7f1", "2022.3.10f1"])
    #expect(st.setupVersion == "1.0.0")
    #expect(st.setupTodo == 2)
    #expect(st.remoteFullDiskAccess == false)
    #expect(st.sudoWithoutPassword == nil)

    var wifiOnly = HostStatus()
    wifiOnly.info = ["mac": "aa:aa:aa:aa:aa:01", "mac_ethernet": ""]
    #expect(wifiOnly.mac == "aa:aa:aa:aa:aa:01")
}

@Test func statusChecksSudoOnlyOnRequest() {
    #expect(Scripts.status().body.contains("if [ 0 = 1 ]; then"))
    #expect(Scripts.status(checkSudo: true).body.contains("if [ 1 = 1 ]; then"))
}

@Test func unityInstallsNativeEditorWithChildModules() {
    let body = Scripts.unityInstallEditor(version: "6000.3.7f1", modules: ["android"]).body
    #expect(body.contains(#"--architecture "$ARCH" '-m' 'android' '--childModules'"#))
    #expect(!Scripts.unityInstallEditor(version: "6000.3.7f1", modules: []).body.contains("childModules"))
    #expect(Scripts.unityInstallModules(version: "6000.3.7f1", modules: ["ios"]).body.contains("'--childModules'"))
}

/// Every generated script must be valid bash 3.2 (the version shipped with macOS).
@Test func allBuildersProduceValidBash() throws {
    let scripts: [(String, RemoteScript)] = [
        ("status", Scripts.status(checkSudo: true)),
        ("distributeKey", Scripts.distributeKey("ssh-ed25519 AAAA x")),
        ("launchApp", Scripts.launchApp("Safari", arguments: "a 'b c'")),
        ("quitApp", Scripts.quitApp("Safari", force: false, terminateIfRunning: true)),
        ("quitAppForce", Scripts.quitApp("/Applications/Safari.app", force: true)),
        ("uninstallApp", Scripts.uninstallApp("/Applications/X.app")),
        ("installPayload", Scripts.installPayload(remoteTar: "/tmp/x.tar")),
        ("installFromURL", Scripts.installFromURL("https://example.com/a.pkg?x=1")),
        ("brew", Scripts.brew("install oracle-jdk")),
        ("unityInstallEditor", Scripts.unityInstallEditor(version: "6000.3.7f1", modules: ["android"])),
        ("androidSDK", Scripts.androidSDK(unityVersion: "6000.3.7f1", apiLevels: ["34"])),
        ("installUpdates", Scripts.installUpdates(restart: true, recommendedOnly: true, downloadOnly: false)),
        ("masUpgrade", Scripts.masUpgrade()),
        ("pushFinalize", Scripts.pushFinalize(remoteTar: "/tmp/x.tar", destination: "/Users/{console}/Desktop",
                                              owner: "", mode: "644", asRoot: true)),
        ("pullArchive", Scripts.pullArchive(source: "~/Desktop", asRoot: false)),
        ("cleanFolder", Scripts.cleanFolder("/Users/student/Desktop", dryRun: true)),
        ("listFolder", Scripts.listFolder("/Users/{console}", asRoot: false)),
        ("prepareSharedFolder", Scripts.prepareSharedFolder("/Users/student/Public/cmcr", owner: "student")),
        ("message", Scripts.message(title: "T \"q\"", text: "zażółć", asDialog: true)),
        ("logoutGraceful", Scripts.logoutUser(force: false)),
        ("logoutForce", Scripts.logoutUser()),
        ("restart", Scripts.power(.restart)),
        ("shutdown", Scripts.power(.shutdown)),
        ("sleep", Scripts.power(.sleep)),
        ("screenSharing", Scripts.enableScreenSharing()),
    ]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-bash-n-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, script) in scripts {
        // Check the body together with the library it is sourced with.
        let file = dir.appendingPathComponent("\(name).sh")
        try (RemoteScript.library + "\n" + script.body + "\n").write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-n", file.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(p.terminationStatus == 0, "\(name): \(message)")
    }
}
