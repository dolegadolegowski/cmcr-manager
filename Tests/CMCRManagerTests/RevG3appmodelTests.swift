import AppKit
import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Fixes from the review of the audit branch in the app model (AUDIT REV-11, REV-12, REV-13, REV-17, REV-22).
@MainActor
@Suite(.serialized, .enabled(if: AppTestEnvironment.isIsolated, "uruchamiaj przez scripts/test.sh (izolowana konfiguracja)"))
struct RevG3appmodelTests {
    /// Every ssh connection of `model` fails at once with `message` on stderr, as ssh itself reports it. The
    /// ProxyCommand runs on this Mac: nothing goes to the network. Without shared connections, because ssh sends
    /// the ProxyCommand's stderr to /dev/null when ControlPersist is set.
    static func failConnections(of model: AppModel, with message: String) {
        model.settings.reuseConnections = false
        model.settings.extraSSHOptions = "UserKnownHostsFile=\(AppTestEnvironment.knownHostsFile.path)\n"
            + "ProxyCommand=/bin/sh -c 'echo \"\(message)\" >&2; exit 255'"
    }

    /// The last check found `jan` at the screen and `ola` in the background.
    static func studentsLoggedIn(on m: Machine, in model: AppModel) {
        var st = HostStatus()
        st.reachability = .online
        st.info = ["console": "jan", "sessions": "jan,ola", "mac": "aa:bb:cc:dd:ee:ff"]
        model.statuses[m.id] = st
    }
}

extension RevG3appmodelTests {
    // REV-11: a Mac whose check failed but which may still take the next action (sshd busy, a refused login that a
    // password fix or an unlocked Keychain undoes) keeps the students logged in before, so „Pomiń komputery
    // z zalogowanym uczniem” still leaves it out of a restart or logout.
    @Test(arguments: [
        ("kex_exchange_identification: read: Connection reset by peer", Reachability.error),
        ("Permission denied (publickey,password,keyboard-interactive).", Reachability.authFailed),
    ])
    func aMacThatMayStillTakeTheActionKeepsItsStudents(failure: String, expected: Reachability) async throws {
        let a = AppTestEnvironment.closedHost("imac07")
        let model = AppTestEnvironment.makeModel([a])
        Self.studentsLoggedIn(on: a, in: model)
        Self.failConnections(of: model, with: failure)
        model.refreshStatus([a])
        #expect(await AppTestEnvironment.wait(30) { ![.online, .checking].contains(model.status(a).reachability) })
        #expect(model.status(a).reachability == expected, "\(model.status(a).message)")
        #expect(model.status(a).loggedInUsers == ["jan", "ola"],
                "komputer z błędem sprawdzenia liczy się jako „nikt nie jest zalogowany” – restart nie pominie ucznia")
        #expect(model.status(a).mac == "aa:bb:cc:dd:ee:ff")
    }
}

extension RevG3appmodelTests {
    // REV-12: „Zbierz prace” and cmcr-pull stream the remote „ls -l” to stderr; a later local failure (a full or
    // read-only disk) is a result never streamed – it goes into the log and the summary, not the last listing line.
    @Test func aLocalFailureAfterStreamedErrorOutputIsInTheLogAndTheSummary() async throws {
        let a = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([a])
        let listing = "remote: ls -l /Users/Shared/Prace\n-rw-r--r--  1 student  staff  2048 29 paź 10:01 projekt.key\n"
        let reason = "Nie można zapisać w /Volumes/Pendrive/Prace/imac01: No space left on device"
        let batch = try #require(model.runBatch("Zbierz prace", on: [a]) { _, job in
            OutputSink(job).callback(.stderr, Data(listing.utf8))
            return .failure(reason)
        })
        #expect(await AppTestEnvironment.wait(5) { batch.finished })
        let job = try #require(batch.jobs.first)
        #expect(job.output.contains(reason), "\(job.output)")
        #expect(job.summary.contains(reason), "podsumowanie: \(job.summary)")
        #expect(!job.summary.contains("projekt.key"))
        #expect(job.output.components(separatedBy: "projekt.key").count == 2, "\(job.output)")

        // The result repeats what was streamed and adds its own line: only that line is added.
        let both = try #require(model.runBatch("Pobieranie", on: [a]) { _, job in
            OutputSink(job).callback(.stderr, Data(listing.utf8))
            return CommandResult(exitCode: 1, stderr: Data((listing + "tar: Error exit delayed from previous errors\n").utf8))
        })
        #expect(await AppTestEnvironment.wait(5) { both.finished })
        let other = try #require(both.jobs.first)
        #expect(other.output.components(separatedBy: "projekt.key").count == 2, "\(other.output)")
        #expect(other.output.contains("tar: Error exit delayed"), "\(other.output)")
        #expect(other.summary.hasPrefix("tar: Error exit delayed"), "podsumowanie: \(other.summary)")
    }
}
