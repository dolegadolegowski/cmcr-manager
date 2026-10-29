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
