import Foundation
import Testing
@testable import CMCRCore

private func values(of option: String, in args: [String]) -> [String] {
    var found: [String] = []
    for (i, a) in args.enumerated() where a == "-o" && i + 1 < args.count && args[i + 1].hasPrefix(option + "=") {
        found.append(String(args[i + 1].dropFirst(option.count + 1)))
    }
    return found
}

private func failure(_ code: Int32, _ stderr: String, started: Bool = false, timedOut: Bool = false) -> CommandResult {
    CommandResult(exitCode: code, stderr: Data(stderr.utf8), timedOut: timedOut, started: started)
}

private let unknownKey = """
    No ED25519 host key is known for imac07.local and you have requested strict checking.
    Host key verification failed.

    """
private let changedKey = """
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
    Host key for imac07.local has changed and you have requested strict checking.
    Host key verification failed.

    """

/// tofu-password-disclosure-spoofed-mdns: a Mac whose key was never confirmed gets no session at all.
struct HostTrustOptionTests {
    let plain = SSHSettings(askpassPath: "/tmp/askpass")

    @Test func everyConnectionChecksHostKeysStrictly() {
        // Before: StrictHostKeyChecking=accept-new – the first device answering to the name got the password.
        for password in [nil, "tajne"] {
            let o = SSH.options(plain, password: password)
            #expect(values(of: "StrictHostKeyChecking", in: o) == ["yes"])
            #expect(!o.contains("StrictHostKeyChecking=accept-new"))
            #expect(values(of: "UpdateHostKeys", in: o) == ["no"])
            let files = values(of: "UserKnownHostsFile", in: o)
            #expect(files.count == 1)
            #expect(files.first?.contains("\"\(HostTrust.appKnownHostsFile.path)\"") == true)
        }
    }

    @Test func sshReadsTheQuotedTrustedFiles() async {
        // `ssh -G` prints the resulting configuration without connecting; -F /dev/null skips ~/.ssh/config.
        let r = await ProcessRunner.run(SSH.sshPath, ["-F", "/dev/null", "-G"] + SSH.options(plain, password: "x")
                                        + ["-p", "22", "nikt@imac07.local"], stdin: Data())
        #expect(r.succeeded, "\(r.stderrText)")
        #expect(r.stdoutText.contains("stricthostkeychecking true"))
        #expect(r.stdoutText.contains("userknownhostsfile \(HostTrust.appKnownHostsFile.path) \(expandTilde("~/.ssh/known_hosts"))\n"))
        let spaced = await ProcessRunner.run(SSH.sshPath, ["-F", "/dev/null", "-G", "-o",
            "UserKnownHostsFile=" + HostTrust.optionValue(["/tmp/Application Support/known_hosts", "/tmp/a%b"]), "x@y"], stdin: Data())
        #expect(spaced.stdoutText.contains("userknownhostsfile /tmp/Application Support/known_hosts /tmp/a%b\n"))
    }

    @Test func trustedFilesAreTheAppsOwnOrTheConfiguredOnes() {
        #expect(HostTrust.files(plain) == [HostTrust.appKnownHostsFile.path, expandTilde("~/.ssh/known_hosts")])
        var s = plain
        s.extraOptions = ["UserKnownHostsFile=/tmp/lab_known_hosts"]
        #expect(HostTrust.files(s) == ["/tmp/lab_known_hosts"])
        // The user's own option still comes first and wins.
        #expect(values(of: "UserKnownHostsFile", in: SSH.options(s, password: nil)).first == "/tmp/lab_known_hosts")
    }

    @Test func knownHostsPathsAreQuotedForSsh() {
        #expect(HostTrust.optionValue(["/Users/x/Library/Application Support/CMCRManager/known_hosts", "/tmp/a%b"])
                == "\"/Users/x/Library/Application Support/CMCRManager/known_hosts\" \"/tmp/a%%b\"")
        #expect(HostTrust.optionValue(["/tmp/a\"b"]) == "\"/tmp/a\\\"b\"")
    }

    @Test func terminalSessionsAskWithTheFingerprint() {
        let host = Machine(name: "imac04", address: "imac04.local", user: "imac04")
        let a = SSH.interactiveArguments(for: host, settings: plain)
        #expect(values(of: "StrictHostKeyChecking", in: a) == ["ask"])
        #expect(values(of: "UserKnownHostsFile", in: a).count == 1)
        #expect(a.last == "imac04@imac04.local")
    }

    @Test func knownHostsNames() {
        #expect(HostTrust.knownHostsName(Machine(name: "a", address: "iMac07.local", user: "x")) == "imac07.local")
        #expect(HostTrust.knownHostsName(Machine(name: "a", address: "127.0.0.1", user: "x", port: 2724)) == "[127.0.0.1]:2724")
        var s = plain
        s.extraOptions = ["HostKeyAlias=pracownia-7"]
        #expect(HostTrust.knownHostsName(Machine(name: "a", address: "x.local", user: "x"), settings: s) == "pracownia-7")
    }
}

struct HostTrustDiagnosisTests {
    @Test func anUnknownKeyIsExplainedWithoutSuggestingToDeleteKeys() {
        let (reach, message) = SSH.diagnose(failure(255, unknownKey))
        #expect(reach == .error)
        #expect(message.contains("nie jest jeszcze zaufany"))
        #expect(message.contains("hasło nie zostało wysłane"))
        #expect(message.contains("Sprawdź klucz komputera"))
        #expect(HostTrust.refusal(failure(255, unknownKey)) == .unknown)
    }

    @Test func aChangedKeyWarnsAboutImpersonation() {
        let (reach, message) = SSH.diagnose(failure(255, changedKey))
        #expect(reach == .error)
        #expect(message.contains("się zmienił"))
        #expect(message.contains("podszywać"))
        #expect(!message.contains("Zapomnij klucz hosta"))
        #expect(HostTrust.refusal(failure(255, changedKey)) == .changed)
    }

    @Test func outputOfAScriptThatRanIsNotAKeyRefusal() {
        // A remote command may itself print ssh's message (e.g. git over ssh inside the script).
        let r = failure(1, "Host key verification failed.\n", started: true)
        #expect(SSH.diagnose(r).1 == "Polecenie zakończone kodem 1.")
    }

    @Test func readinessNamesNewAndChangedKeys() {
        #expect(ReadinessReport.unreachable(failure(255, unknownKey)).connectionFailure == .hostKeyUnknown)
        #expect(ReadinessReport.unreachable(failure(255, unknownKey)).items[.ssh]?.short == "niezaufany klucz")
        #expect(ReadinessReport.unreachable(failure(255, changedKey)).connectionFailure == .hostKeyChanged)
    }

    /// job-timeout-marks-offline: a slow command on a Mac that answered is not "offline".
    @Test func aTimeoutAfterTheStartKeepsTheMacOnline() {
        #expect(SSH.diagnose(failure(-1, "", started: true, timedOut: true)).0 == .online)
        #expect(SSH.diagnose(failure(-1, "", started: true, timedOut: true)).1.contains("zbyt długo"))
        #expect(SSH.diagnose(failure(-1, "", started: false, timedOut: true)).0 == .offline)
    }
}

struct HostTrustScanTests {
    @Test func fingerprintListingsAreParsed() {
        let listing = "256 SHA256:mUdx/Jo/hb8cu40XVf9nu2zwGmrMpP1Luh0Lk04XNww [127.0.0.1]:2724 (ED25519)\n"
            + "3072 SHA256:abcRSA imac07.local (RSA)\n"
        let parsed = HostTrust.parseFingerprintListing(listing)
        #expect(parsed.map(\.type) == ["ED25519", "RSA"])
        #expect(parsed.first?.fingerprint == "SHA256:mUdx/Jo/hb8cu40XVf9nu2zwGmrMpP1Luh0Lk04XNww")
        let found = HostTrust.parseFoundListing("# Host [127.0.0.1]:2724 found: line 1 \n[127.0.0.1]:2724 ED25519 SHA256:xyz\n")
        #expect(found == [HostTrust.Key(type: "ED25519", fingerprint: "SHA256:xyz")])
        #expect(HostTrust.algorithms(for: ["ED25519", "RSA"]) == ["ssh-ed25519", "rsa-sha2-512", "rsa-sha2-256"])
    }

    @Test func scanStates() {
        let host = Machine(name: "imac07", address: "imac07.local", user: "imac07")
        var scan = HostTrust.Scan(host: host)
        #expect(scan.state == nil)
        scan.keys = [HostTrust.Key(type: "ED25519", fingerprint: "SHA256:nowy", line: "imac07.local ssh-ed25519 AAAA")]
        #expect(scan.state == .new)
        scan.trusted = [HostTrust.Key(type: "ED25519", fingerprint: "SHA256:nowy")]
        #expect(scan.state == .trusted)
        scan.trusted = [HostTrust.Key(type: "ED25519", fingerprint: "SHA256:stary")]
        #expect(scan.state == .changed(previous: scan.trusted))
    }

    @Test func trustRefusesKeysOfAnotherName() async {
        let host = Machine(name: "imac07", address: "imac07.local", user: "imac07")
        var scan = HostTrust.Scan(host: host)
        scan.keys = [HostTrust.Key(type: "ED25519", fingerprint: "SHA256:x", line: "imac08.local ssh-ed25519 AAAA")]
        var s = SSHSettings(askpassPath: "/tmp/askpass")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-kh-\(UUID().uuidString)")
        s.extraOptions = ["UserKnownHostsFile=\(file.path)"]
        let r = await HostTrust.trust(scan, settings: s)
        #expect(!r.succeeded)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

/// mux-noise-mm-send-fd
struct MuxDescriptorTests {
    @Test func descriptorPassingNoiseIsFiltered() {
        let noisy = Data("mm_send_fd: sendmsg(1): Message too long\nmux_client_request_session: send fds failed\nprawdziwy błąd\n".utf8)
        #expect(String(decoding: SSHNoise.filter(noisy), as: UTF8.self) == "prawdziwy błąd\n")
    }

    @Test func aRefusedDescriptorHandOverKeepsTheSharedConnection() {
        let r = failure(255, "mm_send_fd: sendmsg(2): Message too long\nmux_client_request_session: send fds failed\n")
        #expect(SSH.connectFailure(r) == .sharedConnection)
        // Without a retry the raw message stays, but the teacher reads Polish, not ssh's English.
        #expect(SSH.diagnose(r).1 == "Nie udało się przekazać sesji przez wspólne połączenie SSH – spróbuj ponownie.")
    }

    @Test func commandsNearAn8KiBBoundaryArePaddedPastIt() {
        for length in [8104, 8120, 8150, 16_320, 24_510, 7700] {
            let command = String(repeating: "x", count: length)
            let padded = RemoteScript.avoidingMuxWindow(command)
            let offset = padded.utf8.count % 8192
            #expect(offset >= 150 && offset < 8192 - 600, "długość \(length) → \(padded.utf8.count)")
            #expect(padded.hasPrefix(command))
            #expect(padded.dropFirst(length).allSatisfy { $0 == " " })
        }
        for length in [100, 3000, 6000, 8400, 12_000] {
            let command = String(repeating: "x", count: length)
            #expect(RemoteScript.avoidingMuxWindow(command) == command)
        }
        let real = RemoteScript(String(repeating: "echo x; ", count: 760)).remoteCommand()
        #expect(!(8192 - 600 ..< 8192).contains(real.utf8.count % 8192))
    }
}

/// cmcr-go-command-injection
struct TerminalScriptTests {
    @Test func hostFieldsNeverRunAsShellCode() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-go-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p1 = dir.appendingPathComponent("P1").path, p2 = dir.appendingPathComponent("P2").path
        let p3 = dir.appendingPathComponent("P3").path
        let host = Machine(name: "Sala 3/iMac", address: "imac$(touch \(p1)).local\";touch \(p3);\"",
                           user: "u`touch \(p2)`")
        let script = SSH.terminalScript(for: host, settings: SSHSettings(askpassPath: "/tmp/askpass"))
        // Run everything up to ssh (which would only reject the address).
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.contains { $0.hasPrefix("exec /usr/bin/ssh ") })
        let safe = lines.map { $0.hasPrefix("exec /usr/bin/ssh ") ? "true" : String($0) }
            .filter { $0 != "clear" }.joined(separator: "\n")
        let r = await ProcessRunner.run("/bin/zsh", ["-c", safe])
        #expect(r.succeeded)
        #expect(r.stdoutText == "cmcr-go → \(host.destination)\n")
        for p in [p1, p2, p3] { #expect(!FileManager.default.fileExists(atPath: p), "wykonano kod z adresu: \(p)") }
    }

    @Test func fileNamesStayInTheTemporaryFolder() {
        #expect(SSH.terminalFileName(for: Machine(name: "imac04", address: "a", user: "b")) == "cmcr-go-imac04.command")
        #expect(SSH.terminalFileName(for: Machine(name: "Sala 3/iMac", address: "a", user: "b")) == "cmcr-go-Sala_3_iMac.command")
        let hidden = Machine(name: "../..", address: "a", user: "b")
        #expect(SSH.terminalFileName(for: hidden) == "cmcr-go-\(hidden.id.uuidString).command")
    }

    @Test func hostEntriesRejectShellCharacters() {
        for bad in ["imac$(id).local", "imac`id`", "imac;id", "a|b", "a&b", "a\"b", "a'b", "a\\b", "a(b)", "a{b}", "a<b>"] {
            #expect(HostEntry.problem(bad, as: .sshPart) != nil, "\(bad)")
        }
        #expect(HostEntry.problem("imac07.local", as: .sshPart) == nil)
        #expect(HostEntry.problem("fe80::1%en0", as: .sshPart) == nil)
        let ok = Machine(name: "imac01", address: "imac01.local", user: "imac01")
        let bad = Machine(name: "imac02", address: "imac02$(id).local", user: "imac02")
        let issues = HostValidation.issues(in: [ok, bad])
        #expect(issues[ok.id] == nil)
        #expect(issues[bad.id] == [.invalidCharacters])
    }
}
