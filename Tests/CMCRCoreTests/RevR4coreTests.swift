import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 4, group R4-core.
struct RevR4coreDescribeTests {
    /// AUDIT REV-56: zsh turns a word that begins with `=` into a command's path, so `describe` quotes it. A combining
    /// mark (U+0301), a variation selector (U+FE0F) or a spacing mark (U+0903) right after the `=` joins it into one
    /// Character, and the Character-based `hasPrefix("=")` missed it: the `logout --force` hint stayed unquoted and zsh
    /// answered „́imac3 not found”. Such a name passes the host list's validation.
    @Test func aLeadingEqualsJoinedWithAMarkIsQuoted() {
        for name in ["=\u{0301}imac3", "=\u{FE0F}imac3", "=\u{0903}imac3"] {
            let scalars = name.unicodeScalars.map { String($0.value, radix: 16) }
            #expect(!name.hasPrefix("="), "\(scalars): przypadek z błędu nie jest już odtwarzany")
            #expect(CommandLineLog.describe(["logout", name, "--force"]) == "logout '\(name)' --force", "\(scalars)")
        }
        // A mark later in the word changes nothing: zsh expands only a leading `=`.
        #expect(CommandLineLog.describe(["logout", "imac=\u{0301}3"]) == "logout imac=\u{0301}3")
    }
}

private func r4Result(_ code: Int32, _ stderr: String) -> CommandResult {
    CommandResult(exitCode: code, stderr: Data(stderr.utf8), started: true)
}

struct RevR4coreSessionEndTests {
    /// AUDIT REV-57: through a shared connection ssh says nothing when that connection dies, so a started session that
    /// broke off counted as such only with an empty stderr. Whatever the command wrote there before the break (progress
    /// of brew, softwareupdate, installer) made it „Polecenie zakończone kodem 255.” on an online Mac, and `exec`
    /// returned 255. Without the wrapper's end marker 255 is ssh's own code, whatever stderr holds.
    @Test func aStartedSessionWithoutItsEndBrokeOffWhateverStderrHolds() {
        for stderr in ["ruszyło\n", "installer: Preparing for installation….....\n", "Password:", "", " \n",
                       "ssh: connect to host inny.local port 22: Operation timed out\n"] {
            #expect(SSH.diagnose(r4Result(255, stderr)) == (.error, SSH.sessionClosed), "\(stderr.debugDescription)")
        }
        #expect(SSH.diagnose(r4Result(255, "Timeout, server imac04 not responding.\r\n")) == (.offline, SSH.sessionLost))
        // Other codes are the command's own as before.
        #expect(SSH.diagnose(r4Result(1, "ruszyło\n")) == (.online, "Polecenie zakończone kodem 1."))
    }

    /// AUDIT REV-53: a command that ends by itself with 255 (`exit 255`, `exit -1`) and prints nothing on stderr looked
    /// like a dropped shared connection: „Połączenie zostało przerwane…” and `exec` returned 1. The wrapper's end marker
    /// tells them apart – with it 255 is the command's own code, whatever ssh-like text the command printed.
    @Test func theCommandsOwn255IsKnownByTheReportedEnd() {
        for stderr in ["", "ssh: connect to host inny.local port 22: Operation timed out\n",
                       "Connection reset by 10.0.0.5 port 22\r\n", "Timeout, server inny.local not responding.\n"] {
            var r = r4Result(255, stderr)
            r.endCode = 255
            #expect(SSH.diagnose(r) == (.online, "Polecenie zakończone kodem 255."), "\(stderr.debugDescription)")
        }
    }

    /// The wrapper itself (run here by a local bash instead of over ssh) reports how the script ended, also after
    /// output without a newline; nothing of the marker reaches the output or the result.
    @Test(arguments: [("exit 255", "", Int32(255)), ("echo wynik; exit -1", "", 255),
                      ("printf 'bez końca linii' >&2; exit 255", "bez końca linii", 255),
                      ("echo błąd >&2; exit 3", "błąd\n", 3), ("true", "", 0)])
    func theWrapperReportsHowTheScriptEnded(body: String, stderr: String, code: Int32) async {
        let script = RemoteScript(body)
        let (r, shown) = await r4Run { output in
            await ProcessRunner.run("/bin/sh", ["-c", script.remoteCommand()], stdin: Data("\n".utf8), timeout: 30,
                                    onOutput: output)
        }
        #expect(r.exitCode == code)
        #expect(r.started)
        #expect(r.endCode == code)
        #expect(r.stderrText == stderr)
        #expect(shown == stderr)
        if code != 0 { #expect(SSH.diagnose(r) == (.online, "Polecenie zakończone kodem \(code).")) }
    }

    /// The marker is written right after the command's last output, and a read may end inside it: the streamed output
    /// and the result show only the command's text.
    @Test func aMarkerSplitBetweenReadsIsNotShown() async {
        let (r, shown) = await r4Stream([start + "postęp 10%\npostęp bez", " końca", "CMCR:SESS", "ION-ENDED 7", "\n"],
                                        code: 7)
        #expect(shown == "postęp 10%\npostęp bez końca")
        #expect(r.stderrText == "postęp 10%\npostęp bez końca")
        #expect(r.endCode == 7)
        #expect(SSH.diagnose(r) == (.online, "Polecenie zakończone kodem 7."))
    }

    /// Text that only looks like the marker is the command's own: it is shown (what was held back, at the end of the
    /// session) and does not count as the end.
    @Test func textLikeTheMarkerIsKept() async {
        let (r, shown) = await r4Stream([start + "Naciśnij C", "MCR:SESSION-ENDED 1"], code: 255)
        #expect(shown == "Naciśnij CMCR:SESSION-ENDED 1")
        #expect(r.endCode == nil)
        #expect(SSH.diagnose(r) == (.error, SSH.sessionClosed))
        let lookalikes = "CMCR:SESSION-ENDED wkrótce\nCMCR:SESSION-ENDED 1234\nCMCR:SESSION-ENDED\n"
        let (r2, shown2) = await r4Stream([start + lookalikes], code: 255)
        #expect(shown2 == lookalikes)
        #expect(r2.stderrText == lookalikes)
        #expect(r2.endCode == nil)
    }

    /// ssh's 255 after the script reported its end: the script's own code counts only when it is 255 too. The marker
    /// travels on stderr and can arrive ahead of the last stdout, so with any other code the session broke off and the
    /// output may be cut off (AUDIT REV-60, RevR5coreTests).
    @Test func theReportedCodeCountsOverSshs255OnlyWhenItIs255() async {
        let (r, _) = await r4Stream([start, "gotowe\n", "CMCR:SESSION-ENDED 0\n"], code: 255)
        #expect(r.exitCode == 255)
        #expect(!r.succeeded)
        #expect(SSH.diagnose(r) == (.error, SSH.sessionClosed))
        let (r1, _) = await r4Stream([start, "CMCR:SESSION-ENDED 2\n"], code: 255)
        #expect(SSH.diagnose(r1) == (.error, SSH.sessionClosed))
        let (r2, _) = await r4Stream([start, "CMCR:SESSION-ENDED 255\n"], code: 255)
        #expect(SSH.diagnose(r2) == (.online, "Polecenie zakończone kodem 255."))
    }
}

private let start = RemoteScript.startMarker + "\n"

/// Collects what `SSH.runWithRetry` streams to its caller on stderr.
private final class R4Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// One attempt through `SSH.runWithRetry`, as `SSH.run` makes it; returns the result and the streamed stderr.
private func r4Run(_ attempt: @escaping (@escaping @Sendable (OutputChannel, Data) -> Void) async -> CommandResult) async
    -> (CommandResult, String) {
    let collected = R4Collected()
    let started = OutputFlag()
    var r = await SSH.runWithRetry(on: Machine(name: "imac99", address: "imac99.invalid", user: "imac99"),
                                   settings: SSHSettings(askpassPath: "/tmp/askpass", reuseConnections: false),
                                   retry: .none, handle: nil, stdoutFile: nil, started: started,
                                   onOutput: { channel, d in if channel == .stderr { collected.add(d) } }) { _, output in
        await attempt(output)
    }
    r.started = started.isSet
    return (r, collected.text)
}

/// An ssh attempt that streams `chunks` on stderr, in this order, and ends with `code`.
private func r4Stream(_ chunks: [String], code: Int32) async -> (CommandResult, String) {
    await r4Run { output in
        for c in chunks { output(.stderr, Data(c.utf8)) }
        return CommandResult(exitCode: code, stderr: Data(chunks.joined().utf8))
    }
}
