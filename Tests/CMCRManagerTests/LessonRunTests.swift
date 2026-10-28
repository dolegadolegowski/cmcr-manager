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
}
