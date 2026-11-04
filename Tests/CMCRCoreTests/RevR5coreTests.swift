import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 5, group R5-core.
struct RevR5coreSessionEndTests {
    /// AUDIT REV-60: the wrapper's end marker travels on stderr (SSH extended data), and sshd sends it ahead of the stdout
    /// it still holds (up to a window, about 2 MB). A connection that broke off after the marker, before that tail, ended
    /// with ssh's 255, and the marker's code replaced it: `exec` returned 0 without a word and a job ended „OK” with its
    /// output cut off. ssh's 255 stays a session that broke off, whatever other code the marker carries.
    @Test(arguments: [Int32(0), 1, 2, 130])
    func theMarkersCodeDoesNotReplaceSshs255(marker: Int32) async {
        let r = await r5Stream([(.stderr, start), (.stdout, "początek wyniku…"), (.stderr, "CMCR:SESSION-ENDED \(marker)\n"),
                                (.stderr, "Connection to 127.0.0.1 closed by remote host.\r\n"),
                                (.stderr, "client_loop: send disconnect: Broken pipe\r\n")], code: 255)
        #expect(r.exitCode == 255)
        #expect(r.endCode == marker)
        #expect(r.started)
        #expect(!r.succeeded)
        #expect(SSH.diagnose(r) == (.error, SSH.sessionClosed))
    }

    /// Through a shared connection (the default) ssh says nothing when the link drops after the marker.
    @Test func aSilentBreakAfterTheMarkerIsABrokenSession() async {
        let r = await r5Stream([(.stderr, start), (.stdout, "wynik"), (.stderr, "CMCR:SESSION-ENDED 0\n")], code: 255)
        #expect(!r.succeeded)
        #expect(SSH.diagnose(r) == (.error, SSH.sessionClosed))
        // The keepalive gave up after the marker: the Mac stopped answering while the output was on its way.
        var lost = CommandResult(exitCode: 255, stderr: Data("Timeout, server imac04 not responding.\r\n".utf8), started: true)
        lost.endCode = 0
        #expect(SSH.diagnose(lost) == (.offline, SSH.sessionLost))
    }

    /// A line like the marker in the command's own stderr (tar quoting a student's file name, a log being shown) does not
    /// turn a connection lost later into the command's success.
    @Test func aMarkerLikeLineOfTheCommandDoesNotHideALostConnection() async {
        let r = await r5Stream([(.stderr, start + "tar: CMCR:SESSION-ENDED 0\n"), (.stderr, "tar: dalej…\n")], code: 255)
        #expect(r.endCode == 0)
        #expect(r.exitCode == 255)
        #expect(!r.succeeded)
        #expect(SSH.diagnose(r) == (.error, SSH.sessionClosed))
    }

    /// What the fix keeps: the command's own 255 (AUDIT REV-53) and a session that closed cleanly.
    @Test func theCommandsOwnCodesStay() async {
        let own = await r5Stream([(.stderr, start), (.stderr, "CMCR:SESSION-ENDED 255\n")], code: 255)
        #expect(SSH.diagnose(own) == (.online, "Polecenie zakończone kodem 255."))
        let clean = await r5Stream([(.stderr, start), (.stdout, "wynik\n"), (.stderr, "CMCR:SESSION-ENDED 0\n")], code: 0)
        #expect(clean.succeeded)
        let failed = await r5Stream([(.stderr, start), (.stderr, "błąd\nCMCR:SESSION-ENDED 3\n")], code: 3)
        #expect(failed.exitCode == 3)
        #expect(SSH.diagnose(failed) == (.online, "Polecenie zakończone kodem 3."))
    }
}

private let start = RemoteScript.startMarker + "\n"

/// One ssh attempt through `SSH.runWithRetry`, as `SSH.run` makes it, that streams `chunks` in this order and ends with
/// `code`.
private func r5Stream(_ chunks: [(OutputChannel, String)], code: Int32) async -> CommandResult {
    let started = OutputFlag()
    var r = await SSH.runWithRetry(on: Machine(name: "imac99", address: "imac99.invalid", user: "imac99"),
                                   settings: SSHSettings(askpassPath: "/tmp/askpass", reuseConnections: false),
                                   retry: .none, handle: nil, stdoutFile: nil, started: started,
                                   onOutput: nil) { _, output in
        var stdout = Data(), stderr = Data()
        for (channel, text) in chunks {
            output(channel, Data(text.utf8))
            if channel == .stdout { stdout.append(Data(text.utf8)) } else { stderr.append(Data(text.utf8)) }
        }
        return CommandResult(exitCode: code, stdout: stdout, stderr: stderr)
    }
    r.started = started.isSet
    return r
}
