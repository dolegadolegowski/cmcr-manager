import Foundation
import Testing
@testable import CMCRCore

// macOS 15+ consent window for the screen preview ("CMCR Screen Agent is requesting to bypass the system private
// window picker…"): replayd's remembered consent is renewed by the preview and the setup script (cmcr_sc_approval),
// for both names macOS may keep it under – the agent's bundle id (15.1+) and its executable path (15.0).

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let clients = [ScreenAgentInfo.bundleID, ScreenAgentInfo.executablePath]
/// The SSH session's old key: left alone, never renewed any more.
private let sshClient = "/usr/libexec/sshd-keygen-wrapper"

/// Runs the CMCR-REPLAYD block with `commands` under /bin/bash in a temporary folder ($T). `pkill` is replaced by a
/// logger, so the real replayd of the account running the tests is never stopped.
private func runApprovalShell(_ commands: String) throws -> (output: String, dir: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-sc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("home"), withIntermediateDirectories: true)
    let script = """
    set -u
    export LC_ALL=C
    T="$1"
    \(Scripts.screenCaptureApprovalShell)
    pkill() { echo "pkill $*" >> "$T/pkill.log"; }
    U="$(id -un)"; H="$T/home"
    F="$H/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
    PB=/usr/libexec/PlistBuddy
    # set_date KEY[:SUBKEY] DATE – PlistBuddy cannot parse ISO dates, so the entry is merged from XML like the block does.
    set_date() {
      local k="${1%%:*}" sub="" xml
      [ "$k" != "$1" ] && sub="${1#*:}"
      if [ -n "$sub" ]; then
        $PB -c "Delete :'$k':$sub" "$F" >/dev/null 2>&1
        xml="<dict><key>$sub</key><date>$2</date></dict>"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">%s</plist>\n' "$xml" | $PB -c "Merge /dev/stdin :'$k'" "$F" >/dev/null
      else
        $PB -c "Delete :'$k'" "$F" >/dev/null 2>&1
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>%s</key><date>%s</date></dict></plist>\n' "$k" "$2" \
          | $PB -c "Merge /dev/stdin" "$F" >/dev/null
      fi
    }
    ID=\(shQuote(ScreenAgentInfo.bundleID)); EXE=\(shQuote(ScreenAgentInfo.executablePath))
    \(commands)
    """
    let url = dir.appendingPathComponent("t.sh")
    try script.write(to: url, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["--noprofile", "--norc", url.path, dir.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), dir)
}

private func approvals(_ dir: URL) throws -> [String: Any] {
    let f = dir.appendingPathComponent("home/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist")
    let data = try Data(contentsOf: f)
    return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

@Test func approvalBlockIsSharedFromTheSetupScript() throws {
    let block = Scripts.screenCaptureApprovalShell
    #expect(block.hasPrefix("# >>> CMCR-REPLAYD"))
    #expect(block.hasSuffix("# <<< CMCR-REPLAYD <<<"))
    #expect(block.contains("cmcr_sc_approval()"))
    // The agent's two names, as macOS keeps them; never the SSH session any more.
    #expect(block.contains("CMCR_SC_ID=\(ScreenAgentInfo.bundleID)\n"))
    #expect(block.contains("CMCR_SC_EXE=\(shQuote(ScreenAgentInfo.executablePath))\n"))
    #expect(!block.contains("CMCR_SC_CLIENT=") && !block.contains("sshd-keygen-wrapper\n"))
    // Keys with dots and spaces: plutil's key paths would split them, PlistBuddy (":") does not.
    #expect(!block.contains("plutil -extract") && !block.contains("plutil -replace"))
    #expect(block.contains("/usr/libexec/PlistBuddy -x -c \"Print $3\""))
    #expect(SetupScriptTemplate.text.contains(block))
    // The preview renews it before capturing; the readiness check only reads it.
    let capture = Scripts.screenCapture(ScreenCaptureOptions(maxSize: 800)).body
    #expect(capture.contains(block))
    #expect(capture.contains("scr_capture() {\n  local line tag d w h b f front=\"\" n=0 sent=0 i\n  scr_approval"))
    let readiness = Scripts.readiness(student: "student", sharedFolder: "/Users/student/Public/cmcr", publicKey: nil).body
    #expect(readiness.contains(block))
    #expect(readiness.contains("declare -f folder_state cmcr_sc_as cmcr_sc_epoch cmcr_sc_valid cmcr_sc_approval"))
    #expect(readiness.contains("declare -p CMCR_SC_ID CMCR_SC_EXE CMCR_SC_HINT"))
    // Only the student account is reported: an admin at the screen is never observed, so nothing renews theirs.
    #expect(readiness.contains("echo \"screen_alert=$(cmcr_sc_approval \"$5\" \"${SHOME:+$R$SHOME}\" \"$7\" check"))
    #expect(readiness.components(separatedBy: "cmcr_sc_approval \"").count == 2, "one readiness call, for the student")
    // Setup: a step of its own after the TCC checks.
    #expect(SetupScriptTemplate.text.contains("  step_screen_alert\n}"))
    // Setup renews only the student's consent: renewing stops that account's replayd, so an admin or teacher at
    // the screen (whom the preview does not observe) keeps their own reminder and their running screen recording.
    let step = try #require(SetupScriptTemplate.text.components(separatedBy: "step_screen_alert() {").last?
        .components(separatedBy: "\n}\n").first)
    #expect(step.contains("st=\"$(cmcr_sc_approval \"$STUDENT\" \"$h\" \"$OS_VER\" $mode)\""))
    #expect(!step.contains("CONSOLE_USER"))
}

@Test func approvalIsWrittenOnlyFromMacOS15AndOnlyWhenItLapses() throws {
    let (out, dir) = try runApprovalShell("""
    echo "old=$(cmcr_sc_approval "$U" "$H" 14.7.1)"
    echo "nohome=$(cmcr_sc_approval "$U" "$T/missing" 26.2)"
    echo "check=$(cmcr_sc_approval "$U" "$H" 26.2 check)"
    [ -e "$F" ] && echo "written-by-check"
    echo "renew=$(cmcr_sc_approval "$U" "$H" 26.2)"
    echo "again=$(cmcr_sc_approval "$U" "$H" 26.2)"
    """)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(out.contains("old=na\n"))
    #expect(out.contains("nohome=nohome\n"))
    #expect(out.contains("check=stale\n"))
    #expect(!out.contains("written-by-check"))
    #expect(out.contains("renew=renewed\n"))
    #expect(out.contains("again=ok\n"))
    let all = try approvals(dir)
    for client in clients {
        let entry = try #require(all[client] as? [String: Any], "\(client)")
        #expect(entry["kScreenCapturePrivacyHintPolicy"] as? Int == 2_592_000)
        #expect(entry["kScreenCaptureAlertableUsageCount"] as? Int == 1)
        let used = try #require(entry["kScreenCaptureApprovalLastUsed"] as? Date)
        #expect(abs(used.timeIntervalSinceNow) < 120)
        #expect(entry["kScreenCaptureApprovalLastAlerted"] as? Date == used)
        let hint = try #require(entry["kScreenCapturePrivacyHintDate"] as? Date)
        #expect(hint > Date().addingTimeInterval(50 * 365 * 86_400))
    }
    #expect(all[sshClient] == nil, "the SSH session is no longer what captures")
    // replayd is stopped before and after the one write, never for a valid consent.
    let log = try String(contentsOf: dir.appendingPathComponent("pkill.log"), encoding: .utf8)
    #expect(log == "pkill -KILL -x -U \(getuid()) replayd\npkill -KILL -x -U \(getuid()) replayd\n")
}

@Test func lapsedApprovalIsRenewedKeepingOtherAppsAndTheUsageCount() throws {
    let (out, dir) = try runApprovalShell(#"""
    mkdir -p "$(dirname "$F")"
    cat > "$F" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>$ID</key><dict>
      <key>kScreenCaptureAlertableUsageCount</key><integer>42</integer>
      <key>kScreenCaptureApprovalLastUsed</key><date>2026-01-01T00:00:00Z</date>
      <key>kScreenCapturePrivacyHintDate</key><date>2099-01-01T00:00:00Z</date>
    </dict>
    <key>/usr/libexec/sshd-keygen-wrapper</key><dict><key>kScreenCaptureAlertableUsageCount</key><integer>9</integer></dict>
    <key>/Applications/Zoom/zoom</key><dict><key>kScreenCaptureAlertableUsageCount</key><integer>7</integer></dict>
    </dict></plist>
    PLIST
    echo "lapsed=$(cmcr_sc_approval "$U" "$H" 15.6 check)"
    echo "renew=$(cmcr_sc_approval "$U" "$H" 15.6)"
    echo "fresh=$(cmcr_sc_approval "$U" "$H" 15.6 check)"
    set_date "$EXE:kScreenCapturePrivacyHintDate" 2026-12-01T00:00:00Z
    echo "hint=$(cmcr_sc_approval "$U" "$H" 15.6 check)"
    set_date "$EXE:kScreenCapturePrivacyHintDate" 2099-01-01T00:00:00Z
    echo "restored=$(cmcr_sc_approval "$U" "$H" 15.6 check)"
    set_date "$ID:kScreenCaptureApprovalLastUsed" 3024-01-01T00:00:00Z
    echo "future=$(cmcr_sc_approval "$U" "$H" 15.6 check)"
    echo "renew2=$(cmcr_sc_approval "$U" "$H" 15.6)"
    """#)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(out.contains("lapsed=stale\n"))
    #expect(out.contains("renew=renewed\n"))
    #expect(out.contains("fresh=ok\n"))
    #expect(out.contains("hint=stale\n"), "a reminder date that is close counts as lapsed – for either name")
    #expect(out.contains("restored=ok\n"))
    #expect(out.contains("future=stale\n"), "a last-use date far in the future is not trusted")
    #expect(out.contains("renew2=renewed\n"))
    let all = try approvals(dir)
    #expect((all["/Applications/Zoom/zoom"] as? [String: Any])?["kScreenCaptureAlertableUsageCount"] as? Int == 7)
    #expect((all[sshClient] as? [String: Any])?["kScreenCaptureAlertableUsageCount"] as? Int == 9)
    let entry = try #require(all[ScreenAgentInfo.bundleID] as? [String: Any])
    #expect(entry["kScreenCaptureAlertableUsageCount"] as? Int == 42)
    #expect(abs((entry["kScreenCaptureApprovalLastUsed"] as? Date ?? .distantPast).timeIntervalSinceNow) < 120)
    let path = try #require(all[ScreenAgentInfo.executablePath] as? [String: Any])
    #expect(path["kScreenCaptureAlertableUsageCount"] as? Int == 1)
}

@Test func approvalHandlesMacOS150BrokenFilesAndMissingAccess() throws {
    let (out, dir) = try runApprovalShell("""
    echo "v150=$(cmcr_sc_approval "$U" "$H" 15.0.1)"
    $PB -x -c "Print :'$ID'" "$F" | sed -n 's|.*<date>\\(.*\\)</date>.*|id \\1|p'
    $PB -x -c "Print :'$EXE'" "$F" | sed -n 's|.*<date>\\(.*\\)</date>.*|exe \\1|p'
    echo "v150again=$(cmcr_sc_approval "$U" "$H" 15.0)"
    echo garbage > "$F"
    echo "broken=$(cmcr_sc_approval "$U" "$H" 26.0)"
    D="$(dirname "$F")"; chmod 000 "$D"
    echo "denied=$(cmcr_sc_approval "$U" "$H" 26.0)"
    chmod 755 "$D"
    echo "other=$(cmcr_sc_approval root "$H" 26.0)"
    """)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(out.contains("v150=renewed\nid 2099-01-01T00:00:00Z\nexe 2099-01-01T00:00:00Z\n"), "macOS 15.0 keeps only the date of the next question")
    #expect(out.contains("v150again=ok\n"))
    #expect(out.contains("broken=renewed\n"))
    #expect(out.contains("denied=denied\n"))
    // Without root the script cannot act as another account (and never writes there as itself).
    if getuid() != 0 { #expect(out.contains("other=error\n")) }
}

@Test func readinessExplainsTheConsentWindowByState() {
    let base = "os=26.2\nadmin=imac07\nconsole=student\nkey=ok\nfolder=ok\nsudo=ok\nscreen_alert_user=student\n"
        + "agent_installed=1\nagent_version=\(ScreenAgentInfo.version)\nagent_loaded=1\n"
        + "agent_ping=AGENT \(ScreenAgentInfo.version) perm=granted locked=0 console=1 asleep=0 user=student\nagent_ping_rc=0\n"
    func detail(_ extra: String) -> String {
        ReadinessReport.parse(base + extra, student: "student", sharedFolder: "/Users/student/Public/cmcr")[.screen].detail
    }
    #expect(detail("screen_alert=ok\n").contains("jest wyłączone (konto student)"))
    #expect(detail("screen_alert=ok\n").contains("usługi podglądu"))
    #expect(!detail("screen_alert=denied\n").contains("sshd-session"))
    #expect(detail("screen_alert=denied\n").contains("„\(ScreenAgentInfo.displayName)” może dalej widzieć ekran"))
    #expect(detail("screen_alert=stale\n").contains("odnowi ją sam przed najbliższym podglądem"))
    #expect(detail("screen_alert=denied\n").contains("nie mają pełnego dostępu do dysku"))
    #expect(detail("screen_alert=denied\n").contains("setup/mdm/cmcr-screen-capture-alert.mobileconfig"))
    // The MDM key is device-wide: every mention says so.
    #expect(detail("screen_alert=denied\n").contains("dla wszystkich aplikacji i kont na Macu"))
    #expect(ReadinessReport.screenCaptureAlertNote.contains("dla wszystkich aplikacji i kont na Macu"))
    #expect(detail("screen_alert=nohome\n").contains("Konto student nie ma jeszcze katalogu domowego"))
    #expect(detail("").contains(ReadinessReport.screenCaptureAlertNote))
    #expect(ReadinessReport.screenCaptureAlertNote.contains("CMCR Manager zapobiega temu sam"))
    let fda = ReadinessReport.parse(base + "fda=no\n", student: "student", sharedFolder: "/Users/student/Public/cmcr")[.fda]
    #expect(fda.state == .manual && fda.detail.contains("pyta ucznia o zgodę na podgląd ekranu"))
}

@Test func mdmProfilesAreValidAndUseTheDocumentedKeys() throws {
    func profile(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("setup/mdm/\(name)"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
    func payloads(_ p: [String: Any]) -> [[String: Any]] { p["PayloadContent"] as? [[String: Any]] ?? [] }
    var uuids: [String] = []

    let alert = try profile("cmcr-screen-capture-alert.mobileconfig")
    #expect(alert["PayloadType"] as? String == "Configuration")
    #expect(alert["PayloadScope"] as? String == "System")
    let restrictions = try #require(payloads(alert).first)
    #expect(restrictions["PayloadType"] as? String == "com.apple.applicationaccess")
    #expect(restrictions["forceBypassScreenCaptureAlert"] as? Bool == true)
    #expect((alert["PayloadDescription"] as? String)?.contains("na całym Macu") == true)
    #expect((alert["PayloadDescription"] as? String)?.contains("dla wszystkich aplikacji") == true)
    uuids += [alert["PayloadUUID"], restrictions["PayloadUUID"]].compactMap { $0 as? String }

    let fda = try profile("cmcr-ssh-full-disk-access.mobileconfig")
    let pppc = try #require(payloads(fda).first)
    #expect(pppc["PayloadType"] as? String == "com.apple.TCC.configuration-profile-policy")
    let services = try #require(pppc["Services"] as? [String: Any])
    #expect(services.keys.sorted() == ["SystemPolicyAllFiles"], "a PPPC profile cannot allow ScreenCapture")
    let entries = try #require(services["SystemPolicyAllFiles"] as? [[String: Any]])
    #expect(entries.map { $0["Identifier"] as? String } == [sshClient, "/usr/libexec/sshd-session"])
    for e in entries {
        #expect(e["Authorization"] as? String == "Allow" && e["Allowed"] == nil)
        #expect(e["IdentifierType"] as? String == "path")
        #expect((e["CodeRequirement"] as? String)?.hasSuffix("\" and anchor apple") == true)
    }
    uuids += [fda["PayloadUUID"], pppc["PayloadUUID"]].compactMap { $0 as? String }
    #expect(Set(uuids).count == 4 && uuids.allSatisfy { UUID(uuidString: $0) != nil })
}
