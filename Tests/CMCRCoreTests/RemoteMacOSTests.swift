import Foundation
import Testing
@testable import CMCRCore

// Regression tests for real-macOS behaviour of the remote scripts (review F3): locale, FileVault restarts,
// the observation notice, the attention overlay's keyboard focus and the screen-recording readiness check.

private func runTool(_ path: String, _ args: [String], env: [String: String]? = nil, stdin: String? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let env { p.environment = env }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    let input = Pipe()
    p.standardInput = input
    do { try p.run() } catch { return (-1, "\(error)") }
    if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
    try? input.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func tempFile(_ name: String, _ text: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-f3-\(UUID().uuidString)-\(name)")
    try? Data(text.utf8).write(to: url)
    return url
}

/// nil when the JXA/AppleScript source compiles.
private func compileOSA(_ source: String, language: String) -> String? {
    let src = tempFile("src.txt", source)
    let dst = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-f3-\(UUID().uuidString).scpt")
    defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
    let (code, out) = runTool("/usr/bin/osacompile", ["-l", language, "-o", dst.path, src.path])
    return code == 0 ? nil : out
}

private func bashSyntaxOK(_ script: RemoteScript) -> Bool {
    let f = tempFile("s.sh", script.render())
    defer { try? FileManager.default.removeItem(at: f) }
    return runTool("/bin/bash", ["-n", f.path]).0 == 0
}

// MARK: - locale-forwarded-parsing

@Test func remoteLibraryPinsTheCLocale() {
    let lib = RemoteScript.library
    #expect(lib.contains("export LC_ALL=C"))
    // Set before anything else runs a tool whose output is parsed.
    let pin = lib.range(of: "export LC_ALL=C")!.lowerBound
    #expect(pin < lib.range(of: "CONSOLE_USER=")!.lowerBound)
}

/// A Terminal with LANG=pl_PL forwards it over ssh (SendEnv/AcceptEnv); the scripts must still parse English.
@Test func forwardedPolishLocaleDoesNotReachParsedOutput() {
    let lib = tempFile("lib.sh", RemoteScript.library)
    defer { try? FileManager.default.removeItem(at: lib) }
    let probe = #"""
    source "$1"
    echo "lc=$LC_ALL"
    echo "load=$(sysctl -n vm.loadavg)"
    echo "date=$(date -j -f %Y-%m-%d 2026-10-03 +%a)"
    case "zażółć" in *[!A-Za-z0-9._-]*) echo "ascii=strict" ;; *) echo "ascii=loose" ;; esac
    echo "pl=zażółć gęślą jaźń"
    """#
    let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "pl_PL.UTF-8", "LC_ALL": "pl_PL.UTF-8",
               "LC_TIME": "pl_PL.UTF-8", "LC_NUMERIC": "pl_PL.UTF-8", "HOME": NSHomeDirectory()]
    let (code, out) = runTool("/bin/bash", ["--noprofile", "--norc", "-c", probe, "probe", lib.path], env: env)
    #expect(code == 0, "\(out)")
    #expect(out.contains("lc=C"))
    let load = out.split(separator: "\n").first { $0.hasPrefix("load=") } ?? ""
    #expect(!load.contains(","), "\(load)")
    #expect(out.contains("date=Sat"), "\(out)")
    // bash 3.2: [A-Za-z] stays ASCII (in en_US.UTF-8/pl_PL.UTF-8 it would accept „ą”) …
    #expect(out.contains("ascii=strict"))
    // … and Polish text passes through unchanged.
    #expect(out.contains("pl=zażółć gęślą jaźń"))
}

// MARK: - filevault-delayed-restart

@Test func delayedRestartArmsFileVaultBeforeDetaching() {
    let body = Scripts.delayedPower(.restart, minutes: 10, warning: "Zapisz pracę").body
    let arm = body.range(of: "cmcr_arm_authrestart \"przy zaplanowanym restarcie\"")
    let detach = body.range(of: "exec /bin/bash --noprofile --norc -c 'sleep")
    #expect(arm != nil && detach != nil)
    if let arm, let detach { #expect(arm.lowerBound < detach.lowerBound) }
    #expect(body.contains("fdesetup authrestart -delayminutes -1 -inputplist"))
    #expect(bashSyntaxOK(Scripts.delayedPower(.restart, minutes: 0, warning: nil)))

    for other in [PowerAction.shutdown, .sleep] {
        #expect(!Scripts.delayedPower(other, minutes: 5, warning: nil).body.contains("fdesetup authrestart"))
    }
    let cancel = Scripts.cancelDelayedPower().body
    #expect(cancel.contains("$TAG [0-9]+ restart"))
    #expect(cancel.contains("macOS nie pozwala go cofnąć"))
}

@Test func immediateRestartUsesTheSharedArmingFunction() {
    let body = Scripts.power(.restart).body
    #expect(body.contains("cmcr_arm_authrestart \"przy tym restarcie\""))
    let arm = body.range(of: "cmcr_arm_authrestart \"przy tym restarcie\"")!.lowerBound
    #expect(arm < body.range(of: "shutdown -r now")!.lowerBound)
    #expect(bashSyntaxOK(Scripts.power(.restart)))
}

@Test func updateRestartArmsFileVaultOnlyWhenARestartFollows() {
    let body = Scripts.installUpdates(restart: true, recommendedOnly: false, downloadOnly: false).body
    #expect(body.contains("NEEDS_RESTART=1"))
    #expect(body.contains(#"[ $DL = 0 ] && [ $RESTART = 1 ] && [ $NEEDS_RESTART = 1 ]"#))
    let arm = body.range(of: "cmcr_arm_authrestart \"przy restarcie po aktualizacji\"")!.lowerBound
    #expect(arm < body.range(of: "softwareupdate \"${ARGS[@]}\"")!.lowerBound)
    #expect(body.contains("exit $RC"))
    #expect(bashSyntaxOK(Scripts.installUpdates(restart: true, recommendedOnly: true, downloadOnly: false,
                                                allowMajorUpgrade: true)))
}

// MARK: - overlay-cooperative-activation

@Test func overlayAsksForActivationAfterLaunchAndReportsIt() {
    let jxa = Scripts.attentionOverlayJXA(message: "Patrzymy na tablicę – „ąę” \\ ' \"")
    #expect(compileOSA(jxa, language: "JavaScript") == nil)
    let run = jxa.range(of: "app.run;")!.lowerBound
    let timer = jxa.range(of: "scheduledTimerWithTimeIntervalRepeatsBlock")!.lowerBound
    #expect(timer < run)
    // The only activation request is the one inside the timer (after finishLaunching), never the
    // cooperative `activate()` that macOS refuses for processes started over SSH.
    #expect(jxa.components(separatedBy: "activateIgnoringOtherApps").count == 2)
    #expect(!jxa.contains("app.activate("))
    #expect(jxa.contains("CMCR:OVERLAY:active") && jxa.contains("CMCR:OVERLAY:inactive"))

    let lock = Scripts.lockScreen(message: "x", mode: .overlay, autoUnlockMinutes: 0)
    #expect(lock.body.contains(#">"$OV" 2>/dev/null &"#))
    #expect(lock.body.contains("CMCR:LOCKWARN:inactive"))
    // The lock is still recorded from the first CMCR:LOCK line, printed before the warning.
    #expect(lock.body.range(of: "echo \"CMCR:LOCK:$USED\"")!.lowerBound
            < lock.body.range(of: "echo \"CMCR:LOCKWARN:inactive\"")!.lowerBound)
    #expect(bashSyntaxOK(lock))
}

// MARK: - screen-observe-notification-best-effort

@Test func observeNoticeIsAConfirmedPanelNotABestEffortNotification() {
    let jxa = Scripts.observeNoticeJXA()
    #expect(compileOSA(jxa, language: "JavaScript") == nil)
    #expect(jxa.contains("CMCR:NOTICE:shown") && jxa.contains("CMCR:NOTICE:hidden"))
    #expect(jxa.contains(Scripts.observeNoticeText))
    // It ends itself: the timer is set up before anything is reported.
    #expect(jxa.range(of: "'terminate:'")!.lowerBound < jxa.range(of: "say(shown")!.lowerBound)

    let script = Scripts.screenCapture(ScreenCaptureOptions(maxSize: 800))
    #expect(!script.body.contains("display notification \""))
    #expect(script.body.contains("STATE notify"))
    #expect(script.body.contains("if scr_notify; then"))
    #expect(script.body.contains("0|3|4|5|\(ScriptCode.observeNotNotified))"))
    #expect(bashSyntaxOK(script))
}

/// The notice builds its panels on a real Mac (bridged selectors exist); nothing is shown in --dry-run.
@Test func observeNoticeDryRunBuildsPanels() {
    let f = tempFile("notice.js", Scripts.observeNoticeJXA())
    defer { try? FileManager.default.removeItem(at: f) }
    let (code, out) = runTool("/usr/bin/osascript", ["-l", "JavaScript", f.path, "--dry-run"])
    #expect(code == 0, "\(out)")
    #expect(out.hasPrefix("panels="), "\(out)")
}

@Test func failedNoticeIsAnIssueThatHidesTheImage() {
    var parser = ScreenStreamParser()
    let events = parser.feed(Data("CMCR1\tSTATE\tnotify\tjan\tosascript zakończył się kodem 1\nCMCR1\tINFO\tjan\t\n".utf8))
    #expect(events.first == .state(.notifyFailed("jan", "osascript zakończył się kodem 1")))
    let issue = ScreenIssue.notifyFailed("jan", "x")
    #expect(issue.hidesImage && !issue.isIdle)
    #expect(issue.exitCode == ScriptCode.observeNotNotified)
    #expect(issue.title == "Nie udało się powiadomić ucznia")
    #expect(issue.message.contains("jan") && issue.message.contains("nie jest pobierany"))

    // A single capture whose user could not be told: no image, the reason is reported, never "notified".
    let stdout = Data("CMCR1\tHELLO\troot\t0\nCMCR1\tSTATE\tnotify\tjan\tbrak potwierdzenia\nCMCR1\tINFO\tjan\t\n".utf8)
    let shot = Operations.screenshot(from: CommandResult(exitCode: ScriptCode.observeNotNotified, stdout: stdout))
    #expect(shot.imageData == nil)
    #expect(shot.notifiedUser == nil)
    #expect(shot.issue == .notifyFailed("jan", "brak potwierdzenia"))
}

// MARK: - sequoia-screen-capture-prompts

@Test func screenRecordingReadinessPrefersThePreflightOfTheRealProcessChain() {
    let base = "os=15.6\nadmin=imac07\nconsole=student\nkey=ok\nfolder=ok\nsudo=ok\ntcc=readable\ntcc_fda=2\n"
    // TCC.db still has the old sshd-keygen-wrapper grant, but the SSH chain (sshd-session) is refused.
    let stale = ReadinessReport.parse(base + "tcc_screen=2\nscreen_preflight=false\n", student: "student",
                                      sharedFolder: "/Users/student/Public/cmcr")
    #expect(stale[.screen].state == .manual)
    #expect(stale[.screen].detail.contains("/usr/libexec/sshd-session"))
    // Granted to sshd-session only: the preflight says yes.
    let granted = ReadinessReport.parse(base + "tcc_screen=-1\nscreen_preflight=true\n", student: "student",
                                        sharedFolder: "/Users/student/Public/cmcr")
    #expect(granted[.screen].state == .ok)
    // macOS 15+: the recurring consent window is explained.
    #expect(granted[.screen].detail.contains(ReadinessReport.screenCaptureAlertNote))
    let older = ReadinessReport.parse("os=14.7\nadmin=imac07\nconsole=student\nkey=ok\nfolder=ok\nsudo=ok\nscreen_preflight=true\n",
                                      student: "student", sharedFolder: "/Users/student/Public/cmcr")
    #expect(older[.screen].state == .ok && !older[.screen].detail.contains("Od macOS 15"))
    // Without a preflight the TCC rows still decide.
    let dbOnly = ReadinessReport.parse(base + "tcc_screen=2\n", student: "student", sharedFolder: "/Users/student/Public/cmcr")
    #expect(dbOnly[.screen].state == .ok)
}

@Test func tccChecksAcceptTheSshdSessionClient() {
    let readiness = Scripts.readiness(student: "student", sharedFolder: "/Users/student/Public/cmcr", publicKey: nil).body
    #expect(readiness.contains("client LIKE '%sshd-keygen-wrapper' OR client LIKE '%sshd-session'"))
    #expect(SetupScriptTemplate.text.contains("client LIKE '%sshd-keygen-wrapper' OR client LIKE '%sshd-session'"))
    #expect(SetupScriptTemplate.text.contains("tcc_ssh_value kTCCServiceScreenCapture"))
}

// MARK: - setup-schedule-stale-ok

@Test func setupScheduleComparesTheRealPmsetEvents() {
    let t = SetupScriptTemplate.text
    #expect(t.contains("sched_block()"))
    #expect(t.contains("plutil -extract power_schedule_sched raw"))
    #expect(t.contains(#""power_schedule_sched": "%s""#))
}
