import AppKit
import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Fixes from the eighth review round in the app that need an AppModel (AUDIT REV-74, REV-75).
@MainActor
@Suite(.serialized, .enabled(if: AppTestEnvironment.isIsolated, "uruchamiaj przez scripts/test.sh (izolowana konfiguracja)"))
struct RevR8appFixTests {
    /// Runs one job on `host` that ends with `result`.
    func failedJob(on host: Machine, in model: AppModel, result: CommandResult) async throws {
        let batch = try #require(model.runBatch("Wiadomość", on: [host]) { _, _ in result })
        #expect(await AppTestEnvironment.wait(5) { batch.finished })
        #expect(batch.jobs.first?.state == .failed)
    }
}

extension RevR8appFixTests {
    // REV-74: an action that found the Mac off (ssh timed out before the script started, no route to host) marked it
    // „Niedostępny”, but kept the student of the last check: the list, „Zalogowany” in the details, the search and the
    // confirmations showed them until the next background round (up to 2 min). As after a status check (KOM-04),
    // a Mac that is off has nobody at it; what else was known (the MAC for Wake-on-LAN) stays.
    @Test(arguments: [
        CommandResult(exitCode: -1, timedOut: true),
        CommandResult(exitCode: 255, stderr: Data("ssh: connect to host imac04 port 22: Operation timed out\n".utf8)),
        CommandResult(exitCode: 255, stderr: Data("ssh: connect to host imac04 port 22: No route to host\n".utf8)),
    ])
    func anActionThatFindsTheMacOffForgetsItsStudents(result: CommandResult) async throws {
        #expect(SSH.diagnose(result).0 == .offline)
        let a = AppTestEnvironment.closedHost("imac04")
        let model = AppTestEnvironment.makeModel([a])
        RevG3appmodelTests.studentsLoggedIn(on: a, in: model)
        try await failedJob(on: a, in: model, result: result)
        #expect(model.status(a).reachability == .offline)
        #expect(model.status(a).consoleUser == nil, "niedostępny komputer pokazuje ucznia z ostatniego sprawdzenia")
        #expect(model.status(a).loggedInUsers.isEmpty)
        #expect(model.status(a).mac == "aa:bb:cc:dd:ee:ff")
    }

    // …while a Mac that answered with an error (sshd refused a session for a moment, a login failed until the password
    // is fixed) may still take the next action: its students stay, so „Pomiń komputery z zalogowanym uczniem” still
    // leaves it out (AUDIT REV-11).
    @Test(arguments: [
        CommandResult(exitCode: 255, stderr: Data("kex_exchange_identification: read: Connection reset by peer\n".utf8)),
        CommandResult(exitCode: 255, stderr: Data("imac04: Permission denied (publickey,password,keyboard-interactive).\n".utf8)),
    ])
    func anActionThatFailsOnAMacThatAnswersKeepsItsStudents(result: CommandResult) async throws {
        #expect(![.online, .offline].contains(SSH.diagnose(result).0))
        let a = AppTestEnvironment.closedHost("imac04")
        let model = AppTestEnvironment.makeModel([a])
        RevG3appmodelTests.studentsLoggedIn(on: a, in: model)
        try await failedJob(on: a, in: model, result: result)
        #expect(model.status(a).reachability == SSH.diagnose(result).0)
        #expect(model.status(a).loggedInUsers == ["jan", "ola"])
    }
}
