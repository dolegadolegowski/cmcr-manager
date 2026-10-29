import Foundation
import Testing
@testable import CMCRCore

// Tests for the review findings of group G1 (REV-xx in AUDIT.md): SSH.diagnose, classroom.json, hosts.json.
// Each test reproduces the reported problem.

private func g1Result(_ code: Int32, _ stderr: String, started: Bool = false) -> CommandResult {
    CommandResult(exitCode: code, stderr: Data(stderr.utf8), started: started)
}

// MARK: - REV-02: a started session that breaks off

struct RevG1DiagnoseTests {
    /// AUDIT REV-02: OpenSSH reports a reset of an established session as "Read from remote host …: Connection reset
    /// by peer" (or "client_loop: send disconnect: …", "Connection reset by <ip> port 22"), and with connection
    /// sharing (the default) a session whose shared connection died ends with 255 and nothing at all on stderr. All of
    /// these were reported as the command's own exit code 255 on an online Mac, although the job keeps running there.
    @Test func aStartedSessionThatBrokeOffIsAConnectionProblem() {
        let broken = [
            "Read from remote host imac05.local: Connection reset by peer\r\n",
            "Read from remote host 10.0.0.5: Operation timed out\r\n",
            "client_loop: send disconnect: Connection reset by peer\n",
            "Connection reset by 10.0.0.5 port 22\r\n",
            "Connection closed by 10.0.0.5 port 22\n",
            "",
            " \n",
        ]
        for stderr in broken {
            let (reach, message) = SSH.diagnose(g1Result(255, stderr, started: true))
            #expect(reach == .error, "\(stderr.debugDescription)")
            #expect(message == SSH.sessionClosed, "\(stderr.debugDescription): \(message)")
        }
        // Output of the command itself before the break does not hide ssh's message.
        let afterOutput = g1Result(255, "installer: Package name is Unity\nRead from remote host imac05.local: "
                                   + "Connection reset by peer\r\n", started: true)
        #expect(SSH.diagnose(afterOutput) == (.error, SSH.sessionClosed))
    }

    /// The command's own failures stay its own (AUDIT ZAD-07): the Mac answered.
    @Test func theCommandsOwnCode255StaysOnline() {
        let nested = g1Result(255, "ssh: connect to host inny.local port 22: Operation timed out\n", started: true)
        #expect(SSH.diagnose(nested) == (.online, "Polecenie zakończone kodem 255."))
        let key = g1Result(255, "git@github.com: Permission denied (publickey).\n", started: true)
        #expect(SSH.diagnose(key).0 == .online)
        // Other codes with nothing on stderr are the command's result as before.
        #expect(SSH.diagnose(g1Result(1, "", started: true)) == (.online, "Polecenie zakończone kodem 1."))
        // Before the start an empty 255 is still a plain connection error.
        #expect(SSH.diagnose(g1Result(255, "")) == (.error, "Błąd połączenia SSH (kod 255)."))
    }
}
