import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Fixes from the eighth review round in the app: the window that shows a notice or the configuration problems
/// (AUDIT REV-72).
@MainActor
@Suite struct RevR8appFixNoticeTests {
    static let notice = AppNotice(title: "Nie udało się zapisać zrzutu ekranu", message: "Wolumin jest tylko do odczytu.")

    /// Lets the main queue run what was put on it so far (a choice announced to the windows a moment later).
    static func nextTurn() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
    }

    /// A window with something attached to it – the alert SwiftUI shows as a sheet.
    static func showsAlert(_ window: NSWindow) -> NSWindow {
        let alert = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 40), styleMask: [.titled],
                             backing: .buffered, defer: false)
        alert.isReleasedWhenClosed = false
        window.beginSheet(alert)
        return alert
    }
}

extension RevR8appFixNoticeTests {
    // REV-72: the window that showed a message was minimized (the Screen Wall on a projector): its own update moved
    // the message to another window, but nothing told that window – NoticeWindows was not observed and the model did
    // not change. The message was shown by no window until some unrelated change of the model (up to the 2-minute
    // refresh in an idle classroom). Every window looks again when a message gets another window.
    @Test func aMessageThatMovesToAnotherWindowIsShownThereAtOnce() async throws {
        let windows = NoticeWindows()
        let main = RevR7appTests.window(), wall = RevR7appTests.window()
        defer { main.close(); wall.close() }
        windows.register(main)
        windows.register(wall)
        wall.orderFront(nil)
        let notice = Self.notice
        let issues = try #require(windows.configIssues(for: ["ISSUE-A"]))
        #expect(windows.presenter(for: notice) === wall)
        #expect(windows.presenter(for: issues) === wall)
        await Self.nextTurn()
        let placed = windows.placements
        // The Screen Wall is minimized: no longer visible.
        wall.orderOut(nil)
        #expect(windows.presenter(for: notice) === main)
        await Self.nextTurn()
        #expect(windows.placements != placed, "okno, które ma teraz pokazać komunikat, nie dowiedziało się o tym")
        let movedNotice = windows.placements
        #expect(windows.presenter(for: issues) === main)
        await Self.nextTurn()
        #expect(windows.placements != movedNotice, "okno, które ma teraz pokazać ostrzeżenie, nie dowiedziało się o tym")
        // The same answer again tells nobody anything: the windows do not keep updating each other.
        let settled = windows.placements
        #expect(windows.presenter(for: notice) === main)
        #expect(windows.presenter(for: issues) === main)
        await Self.nextTurn()
        #expect(windows.placements == settled)
    }

    // …a window that shows a message and goes away without updating itself (closed by code: the screen window of
    // a Mac removed from the list) makes the other windows look again too.
    @Test func aWindowThatGoesAwayWithAMessageMakesTheOthersLookAgain() async throws {
        let windows = NoticeWindows()
        let main = RevR7appTests.window(), wall = RevR7appTests.window()
        defer { main.close(); wall.close() }
        windows.register(main)
        windows.register(wall)
        wall.orderFront(nil)
        #expect(windows.presenter(for: Self.notice) === wall)
        await Self.nextTurn()
        let placed = windows.placements
        wall.orderOut(nil)
        windows.windowChanged(wall, onScreen: false)
        await Self.nextTurn()
        #expect(windows.placements != placed)
        #expect(windows.presenter(for: Self.notice) === main)
        // A window without a message going away changes nothing.
        await Self.nextTurn()
        let settled = windows.placements
        windows.windowChanged(wall, onScreen: false)
        await Self.nextTurn()
        #expect(windows.placements == settled)
    }

    // …and when a window comes back on screen (restored from the Dock), a message the window chosen for it does not
    // show – nothing is attached to that window – is placed anew, in the window the user works in now, instead of
    // waiting for some other change.
    @Test func aWindowThatComesBackShowsAMessageNoWindowShows() async throws {
        let windows = NoticeWindows()
        let main = RevR7appTests.window(), wall = RevR7appTests.window()
        defer { main.close(); wall.close() }
        windows.register(main)
        windows.register(wall)
        main.orderFront(nil)
        #expect(windows.presenter(for: Self.notice) === main)
        wall.orderFront(nil)
        await Self.nextTurn()
        let placed = windows.placements
        windows.windowChanged(wall, onScreen: true)
        #expect(windows.presenter(for: Self.notice) === wall)
        await Self.nextTurn()
        #expect(windows.placements != placed)
    }

    // A message that a window shows stays there when another window comes on screen: no alert jumps between windows.
    @Test func aShownMessageStaysWhereItIs() async throws {
        let windows = NoticeWindows()
        let main = RevR7appTests.window(), wall = RevR7appTests.window()
        defer { main.close(); wall.close() }
        windows.register(main)
        windows.register(wall)
        main.orderFront(nil)
        #expect(windows.presenter(for: Self.notice) === main)
        let alert = Self.showsAlert(main)
        defer { main.endSheet(alert) }
        #expect(main.attachedSheet === alert)
        wall.orderFront(nil)
        await Self.nextTurn()
        let placed = windows.placements
        windows.windowChanged(wall, onScreen: true)
        #expect(windows.presenter(for: Self.notice) === main)
        await Self.nextTurn()
        #expect(windows.placements == placed)
    }

    // The windows look again when the choice changes: NoticeAlert and ConfigIssuesNotice observe NoticeWindows.
    @Test func everyWindowObservesTheChoice() {
        func observes(_ modifier: Any) -> Bool {
            Mirror(reflecting: modifier).children.contains { $0.value is ObservedObject<NoticeWindows> }
        }
        #expect(observes(NoticeAlert()))
        #expect(observes(ConfigIssuesNotice(window: WeakWindow(), visible: true)))
    }
}

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

extension RevR8appFixTests {
    // REV-75: classroom.json – the lesson scenarios, the power schedule, the attention mode, the question timeout –
    // that could not be saved (read-only configuration folder, full disk) was not reported: ClassroomStore.saveConfig
    // dropped the reason, the change looked saved and was gone after the next start. It is shown like a failed save of
    // hosts.json or settings.json (AUDIT KON-03): once per file, also when another file fails or saves in between.
    @Test func aFailedSaveOfTheClassroomSettingsIsShown() throws {
        let model = AppTestEnvironment.makeModel([AppTestEnvironment.closedHost("imac01")])
        let classroom = ClassroomModel.shared
        model.notice = nil
        let dir = ConfigStore.directory.path
        chmod(dir, 0o500)
        defer { chmod(dir, 0o700) }
        var config = classroom.config
        config.questionTimeoutMinutes += 1
        classroom.save(config)
        let notice = try #require(model.notice, "błąd zapisu classroom.json nie został pokazany")
        #expect(notice.title == "Nie udało się zapisać konfiguracji")
        #expect(notice.message.contains("classroom.json"), "\(notice.message)")
        model.notice = nil
        config.questionTimeoutMinutes += 1
        classroom.save(config)
        #expect(model.notice == nil, "ten sam błąd nie powinien wracać przy każdej zmianie")

        // The host list fails too: reported once as well, and neither warning comes back after the other.
        model.machines[0].port = 2
        #expect(model.notice?.message.contains("hosts.json") == true, "\(model.notice?.message ?? "brak komunikatu")")
        model.notice = nil
        classroom.save(config)
        #expect(model.notice == nil, "błąd zapisu classroom.json wrócił po błędzie zapisu hosts.json")
        model.machines[0].port = 3
        #expect(model.notice == nil, "błąd zapisu hosts.json wrócił po błędzie zapisu classroom.json")

        chmod(dir, 0o700)
        classroom.save(classroom.config)
        model.machines[0].port = 4
        #expect(model.notice == nil)
        let file = ConfigStore.directory.appendingPathComponent("classroom.json")
        #expect(try JSONDecoder().decode(ClassroomConfig.self, from: Data(contentsOf: file)) == classroom.config)
    }
}
