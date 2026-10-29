import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// duplicate-host-id (AUDIT KON-02): two entries with one id (a copied hosts.json entry) must not stop the app
/// when a lesson starts or the computers are renamed.
@MainActor
@Suite struct LessonRunTests {
    @Test func aRepeatedMacDoesNotCrashTheLessonTable() {
        let m = Machine(name: "imac01", address: "imac01.local", user: "imac01")
        var copy = m
        copy.name = "imac02"
        let plan = LessonPlan.end(LessonEndConfig(), settings: AppSettings())
        let run = LessonRun(plan: plan, machines: [m, copy])
        #expect(run.states.count == 1)
        #expect(run.state(m.id, 0) == .pending || plan.steps.isEmpty)
    }

    /// countdown-range-crash (AUDIT ZAJ-16): the countdown text is drawn also in the moment after its end.
    @Test func theCountdownRangeIsValidAfterTheEnd() throws {
        let run = LessonRun(plan: LessonPlan.end(LessonEndConfig(), settings: AppSettings()), machines: [])
        #expect(run.countdownRange() == nil)
        let now = Date()
        run.countdownEnd = now.addingTimeInterval(-0.4)
        let late = try #require(run.countdownRange(now: now))
        #expect(late.lowerBound == now && late.upperBound == now)
        run.countdownEnd = now.addingTimeInterval(60)
        #expect(run.countdownRange(now: now) == now...now.addingTimeInterval(60))
    }

    /// lesson-summary (AUDIT ZAJ-13): „Gotowe na wszystkich komputerach” only when the routine ran everywhere.
    @Test func theSummarySaysWhenMacsWereLeftOutOrTheRoutineStopped() {
        let a = Machine(name: "imac01", address: "imac01.local", user: "imac01")
        let b = Machine(name: "imac02", address: "imac02.local", user: "imac02")
        var end = LessonEndConfig()
        end.warn = false
        end.logout = true
        let plan = LessonPlan.end(end, settings: AppSettings())
        let run = LessonRun(plan: plan, machines: [a, b])
        for i in plan.steps.indices {
            run.update(a.id, i, .done("ok"))
            run.update(b.id, i, .skipped("pominięto – komputer niedostępny"))
        }
        #expect(!run.outcome.clean)
        #expect(run.outcome.text.hasPrefix("Pominięto 1 komputer"))
        for i in plan.steps.indices { run.update(b.id, i, .done("ok")) }
        #expect(run.outcome.clean)
        run.cancel()
        #expect(run.outcome.text.hasPrefix("Przerwano"))
    }

    /// screen-menu (AUDIT ZAJ-17): a frame of one chosen screen does not hide the screen menu.
    @Test func choosingOneScreenKeepsTheScreenCount() {
        #expect(ScreenCenter.knownDisplayCount(1, previous: 3, shown: .number(2)) == 3)
        #expect(ScreenCenter.knownDisplayCount(2, previous: 3, shown: .all) == 2)
        #expect(ScreenCenter.knownDisplayCount(1, previous: 1, shown: .main) == 1)
    }
}
