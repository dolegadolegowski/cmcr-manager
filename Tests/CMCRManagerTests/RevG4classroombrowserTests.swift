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
}
