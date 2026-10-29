import Combine
import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Values seen by a subscriber, in order.
@MainActor
private final class Recorder<Value> {
    var values: [Value] = []
}

/// Holds an operation until the test opens it.
@MainActor
private final class Gate {
    var open = false

    func wait() async {
        while !open { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}

/// Review fixes (AUDIT REV-xx) in the lesson routines and the file browser that need no AppModel.
@MainActor
@Suite struct RevG4ClassroomBrowserTests {
    // lesson-summary-nothing-to-do (AUDIT REV-14): a step that ran and had nothing to do („nikt nie jest zalogowany”)
    // does not make the Mac „pominięty”; a Mac that a phase of the routine left out does.
    @Test func stepsWithNothingToDoAreNotLeftOutMacs() {
        let a = Machine(name: "imac01", address: "imac01.local", user: "imac01")
        let b = Machine(name: "imac02", address: "imac02.local", user: "imac02")
        var start = LessonStartConfig()
        start.wake = false
        start.greet = true
        let greeting = LessonPlan.start(start, settings: AppSettings())
        #expect(greeting.steps == [.greet])
        let before = LessonRun(plan: greeting, machines: [a, b])
        for id in [a.id, b.id] { before.update(id, 0, .skipped("nikt nie jest zalogowany")) }
        #expect(before.skippedHosts == 0)
        #expect(before.outcome.clean, "\(before.outcome.text)")

        var end = LessonEndConfig()
        end.quitApps = false
        end.collect = false
        end.cleanShared = false
        end.cleanDownloads = false
        end.logout = true
        end.power = .none
        end.warn = false
        let logout = LessonPlan.end(end, settings: AppSettings())
        #expect(logout.steps == [.logout])
        let empty = LessonRun(plan: logout, machines: [a, b])
        for id in [a.id, b.id] { empty.update(id, 0, .skipped("nikt nie był zalogowany")) }
        #expect(empty.outcome.clean, "\(empty.outcome.text)")

        end.warn = true
        let plan = LessonPlan.end(end, settings: AppSettings())
        #expect(plan.steps == [.warn, .logout])
        let after = LessonRun(plan: plan, machines: [a, b])
        // imac01: the students left after the warning, nobody was left to log out.
        after.update(a.id, 0, .done("wyświetlono ostrzeżenie"))
        after.update(a.id, 1, .skipped("nikt nie był zalogowany"))
        // imac02 got the warning, then the steps after the countdown left it out (switched off meanwhile).
        after.update(b.id, 0, .done("wyświetlono ostrzeżenie"))
        after.update(b.id, 1, .skipped("pominięto – komputer niedostępny"))
        #expect(after.skippedHosts == 1)
        #expect(after.outcome.text.hasPrefix("Pominięto 1 komputer –"), "\(after.outcome.text)")
        // A Mac with a failed step is counted once, as a problem.
        after.update(b.id, 0, .failed("brak połączenia"))
        #expect(after.skippedHosts == 0)
        #expect(after.outcome.text.hasPrefix("Problemy na 1 komputerze –"), "\(after.outcome.text)")
    }

    // browser-genitive (AUDIT REV-16): „Usuń 3 elementy” in the title, but „Usuwanie 3 elementów…” in the status bar.
    @Test func statusBarTextsUseTheGenitive() {
        let names = { (n: Int) in (1...n).map { "plik\($0).txt" } }
        for (n, title) in [(2, "2 elementy"), (3, "3 elementy"), (5, "5 elementów"), (12, "12 elementów"),
                           (22, "22 elementy"), (101, "101 elementów")] {
            let what = RemoteBrowserModel.subject(names(n))
            #expect(what.title == title)
            #expect(what.activity == "\(n) elementów")
        }
        let one = RemoteBrowserModel.subject(["praca.txt"])
        #expect(one.title == "„praca.txt”")
        #expect(one.activity == "„praca.txt”")
    }
}

/// Review fixes (AUDIT REV-xx) of the classroom and file browser models that need an AppModel.
@MainActor
@Suite(.serialized, .enabled(if: AppTestEnvironment.isIsolated, "uruchamiaj przez scripts/test.sh (izolowana konfiguracja)"))
struct RevG4ClassroomBrowserModelTests {
    let classroom = ClassroomModel.shared

    // rename-list-index (AUDIT REV-18): saving the new name takes over what cmcrctl changed in hosts.json meanwhile
    // (AUDIT KON-04) and may replace the whole list; the new address must still land in the renamed Mac's entry.
    @Test func aRenameUpdatesItsOwnEntryAfterCmcrctlChangedTheList() throws {
        let a = Machine(name: "imac01", address: "imac01.local", user: "nikt")
        let b = Machine(name: "imac02", address: "imac02.local", user: "nikt")
        let c = Machine(name: "imac03", address: "imac03.local", user: "nikt")
        let model = AppTestEnvironment.makeModel([a, b, c])
        let file = ConfigStore.directory.appendingPathComponent("hosts.json")
        try JSONEncoder().encode([b, c]).write(to: file)        // cmcrctl hosts remove imac01 during the rename
        classroom.renamed(.init(machine: b, computerName: "imac22", localHostName: "imac22"), model: model,
                          updateList: true)
        #expect(model.machines.map(\.id) == [b.id, c.id])
        #expect(model.machine(b.id)?.name == "imac22")
        #expect(model.machine(b.id)?.address == "imac22.local")
        #expect(model.machine(c.id)?.address == "imac03.local", "nowy adres trafił do wpisu innego komputera")
        let saved = try JSONDecoder().decode([Machine].self, from: Data(contentsOf: file))
        #expect(saved == model.machines)
        #expect(classroom.names[b.id]?.computerName == "imac22")

        // The last entry, with an entry before it removed meanwhile (an index past the end before the fix).
        try JSONEncoder().encode([model.machines[1]]).write(to: file)
        classroom.renamed(.init(machine: c, computerName: "imac33", localHostName: "imac33"), model: model,
                          updateList: true)
        #expect(model.machines.map(\.address) == ["imac33.local"])
    }

    // question-retry-stale (AUDIT REV-20): „Powtórz na nieudanych” shows the question again on a Mac that was left
    // out; until it answers, the row waits for the answer instead of keeping „pominięto – komputer niedostępny”.
    @Test func aRepeatedQuestionWaitsForTheAnswerAgain() async throws {
        let a = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([a])
        var off = HostStatus()
        off.reachability = .offline
        model.statuses[a.id] = off
        let question = classroom.config.lastQuestion
        classroom.config.lastQuestion = "Czy skończyliście?"
        defer { classroom.config.lastQuestion = question }
        let skip = model.skipUnreachable
        model.skipUnreachable = true
        classroom.ask(model, [a], buttons: ["Tak", "Nie"])
        model.skipUnreachable = skip
        let round = try #require(classroom.question)
        let batch = try #require(round.batch)
        #expect(round.errors[a.id] == "pominięto – komputer niedostępny")
        #expect(await AppTestEnvironment.wait(5) { batch.finished })

        let shown = Recorder<String?>()
        let watch = round.$errors.sink { shown.values.append($0[a.id]) }
        defer { watch.cancel() }
        model.retry(batch, on: batch.retryableMachines)
        let again = try #require(model.batches.first { $0.title == "Pytanie: Czy skończyliście? (ponowienie)" })
        #expect(await AppTestEnvironment.wait(30) { again.finished })
        #expect(shown.values.contains { $0 == nil },
                "powtórzone pytanie nadal pokazywało „pominięto” zamiast czekać na odpowiedź: \(shown.values)")
        #expect(round.errors[a.id] != "pominięto – komputer niedostępny")
    }

    // browser-change-other-mac (AUDIT REV-15): after switching to another Mac, a change still running or finishing
    // on the Mac shown before says which Mac it is about, instead of looking like the new Mac's.
    @Test func aChangeOnTheMacShownBeforeSaysWhichMacItIsOn() async throws {
        let a = AppTestEnvironment.closedHost("imac01"), b = AppTestEnvironment.closedHost("imac02")
        let model = AppTestEnvironment.makeModel([a, b])
        let browser = model.files.browser
        browser.setHost(a.id)
        let gate = Gate()
        browser.runChange("Wyślij „Projekt” → imac01:/Users/uczen", on: a, activity: "Wysyłanie „Projekt”…") { _ in
            await gate.wait()
            return .failure("Brak miejsca na dysku")
        }
        #expect(browser.activity == "Wysyłanie „Projekt”…")
        browser.setHost(b.id)                                       // the teacher clicks imac02 in the list
        #expect(browser.activity == "imac01: Wysyłanie „Projekt”…")
        browser.setHost(a.id)
        #expect(browser.activity == "Wysyłanie „Projekt”…")
        browser.setHost(b.id)
        gate.open = true
        let batch = try #require(model.batches.first)
        #expect(await AppTestEnvironment.wait(10) { batch.finished && browser.notice != nil })
        #expect(browser.activity == nil)
        let notice = try #require(browser.notice)
        #expect(notice.isError)
        #expect(notice.text.hasPrefix("imac01: "), "\(notice.text)")
        #expect(notice.batchID == batch.id)
    }
}
