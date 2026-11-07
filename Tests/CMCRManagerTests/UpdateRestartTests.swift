import Testing
@testable import CMCRManager

/// The restart after an update (log: the first "Zainstaluj i uruchom ponownie" ended with „zamknięcie anulowane”
/// in the same second and had to be clicked again): quitting that is only put off is not a cancellation.
@Suite struct UpdateRestartTests {
    @Test func quittingForAnUpdateStopsRunningWorkAndQuitsInsteadOfAsking() {
        // Update restart: confirmed in the update sheet already, so running work is stopped, not asked about again.
        #expect(QuitPlan.decide(updating: true, hasRunningWork: true, hasQuestion: false) == .stopWorkThenQuit)
        #expect(QuitPlan.decide(updating: true, hasRunningWork: false, hasQuestion: false) == .quitNow)
        // A plain quit asks when there is work, and quits right away when there is none.
        #expect(QuitPlan.decide(updating: false, hasRunningWork: true, hasQuestion: true) == .ask)
        #expect(QuitPlan.decide(updating: false, hasRunningWork: false, hasQuestion: false) == .quitNow)
    }

    @Test func theUpdaterWaitsOnlyWhenQuittingWasPutOff() {
        #expect(Updater.waitAfterTerminate(.none) == 0)
        #expect(Updater.waitAfterTerminate(.cancelled) == 0)
        let wait = Updater.waitAfterTerminate(.deferred)
        // Long enough for the work to be stopped (AppModel.quitWaitLimit), short of the 60 s the helper waits.
        #expect(wait > AppModel.quitWaitLimit)
        #expect(wait < 60)
    }
}
