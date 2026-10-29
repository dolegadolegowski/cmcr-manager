import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Review findings in the app's views (AUDIT REV-21…REV-29, group G5-views). Pure view logic: no AppModel, no
/// configuration, no network.
@MainActor
@Suite struct RevG5viewsTests {
    // REV-21: until „Sprawdź teraz” the details show the schedule from the regular status in the same Polish words
    // as after the check, and a status that reported no repeating events says „brak”, not „nie sprawdzono”.
    @Test func theScheduleFromTheStatusReadsLikeAfterACheck() {
        let pmset = """
        Repeating power events:
          wakepoweron at 7:30AM weekdays only
          shutdown at 5:00PM weekdays only
        """
        let afterCheck = HostInspector.scheduleText(checked: ScheduleInfo(events: PowerScheduleParser.repeating(pmset)),
                                                    status: HostStatus())
        var st = HostStatus()
        // The line Scripts.status prints (pmset's lines joined with "; ").
        st.info = Parsers.keyValues("os=26.1\npower_schedule=wakepoweron at 7:30AM weekdays only; shutdown at 5:00PM weekdays only\n")
        let fromStatus = HostInspector.scheduleText(checked: nil, status: st)
        #expect(fromStatus == afterCheck)
        #expect(fromStatus == "Obudź lub włącz o 7:30 – dni robocze (Pn–Pt)\nWyłącz o 17:00 – dni robocze (Pn–Pt)")
    }

    @Test func aStatusWithoutRepeatingEventsMeansNoSchedule() {
        var st = HostStatus()
        st.info = Parsers.keyValues("os=26.1\npower_schedule=\n")
        #expect(HostInspector.scheduleText(checked: nil, status: st) == "brak")
        st.info = Parsers.keyValues("os=26.1\n")                 // no answer about the schedule
        #expect(HostInspector.scheduleText(checked: nil, status: st) == "nie sprawdzono")
        #expect(HostInspector.scheduleText(checked: nil, status: HostStatus()) == "nie sprawdzono")
        // The answer of „Sprawdź teraz” still comes first.
        st.info = Parsers.keyValues("power_schedule=\n")
        #expect(HostInspector.scheduleText(checked: ScheduleInfo(error: "Brak połączenia"), status: st) == "Brak połączenia")
    }
}
