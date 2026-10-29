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

    // REV-23: Przejdź › section, ⇧⌘, and a notification click show the main window. The Settings window (or a screen
    // window) left on screen while the main window is closed is not it – a new main window must be opened instead.
    @Test func onlyAWindowOfTheMainGroupCountsAsTheMainWindow() {
        #expect(MainWindow.isMain(identifier: "main-AppWindow-1", shown: true))
        #expect(!MainWindow.isMain(identifier: "main-AppWindow-1", shown: false))     // closed
        #expect(!MainWindow.isMain(identifier: "com_apple_SwiftUI_Settings_window", shown: true))
        #expect(!MainWindow.isMain(identifier: "screen-wall-AppWindow-1", shown: true))
        #expect(!MainWindow.isMain(identifier: "screen-window-AppWindow-2", shown: true))
        #expect(!MainWindow.isMain(identifier: nil, shown: true))
    }

    // REV-25: the generator's footer names the fields by their labels and reads as a sentence, also for an empty
    // prefix (HostEntry.problem says „pusta wartość”).
    @Test func theGeneratorFooterNamesTheFieldAndReadsAsASentence() {
        #expect(HostListGeneratorSheet.patternProblem(prefix: "", domain: "local") == "Wpisz początek nazwy, zanim utworzysz listę.")
        #expect(HostListGeneratorSheet.patternProblem(prefix: "im ac", domain: "local")
                == "Początek nazwy: zawiera spację – popraw go, zanim utworzysz listę.")
        #expect(HostListGeneratorSheet.patternProblem(prefix: "imac", domain: "lo cal")
                == "Domena sieci: zawiera spację – popraw ją, zanim utworzysz listę.")
        for prefix in ["", "-x", "imac;", "im,ac"] {
            let text = HostListGeneratorSheet.patternProblem(prefix: prefix, domain: "local") ?? ""
            #expect(!text.isEmpty && !text.contains("pusta wartość") && !text.contains("Przedrostek"), "\(text)")
        }
    }

    // REV-26: in the restart sheet a Mac's FileVault badge and the warning above give the same answer: where the
    // one-time unlock can be armed (authrestart=yes), neither says the Mac will stop at the unlock screen.
    @Test func theFileVaultBadgeAgreesWithTheWarning() {
        let stops = "Po ponownym uruchomieniu komputer zatrzyma się na ekranie odblokowania dysku."
        let armed = PowerConfirmSheet.fileVaultHelp(autoUnlock: true)
        #expect(armed != stops && armed.contains("fdesetup authrestart") && armed.contains("bez hasła FileVault"))
        #expect(PowerConfirmSheet.fileVaultHelp(autoUnlock: false) == stops)
        #expect(PowerConfirmSheet.fileVaultHelp(autoUnlock: nil) == stops)        // not known yet

        let all = PowerConfirmSheet.fileVaultWarning(count: 2, autoUnlock: 2)
        #expect(all.hasPrefix("FileVault jest włączony na 2 komputerach.") && all.contains("powinny uruchomić się bez hasła FileVault"))
        let none = PowerConfirmSheet.fileVaultWarning(count: 2, autoUnlock: 0)
        #expect(!none.contains("authrestart") && none.contains("pojawi się ekran odblokowania dysku"))
        // Some of them: the warning must not promise either answer for all of them.
        let some = PowerConfirmSheet.fileVaultWarning(count: 3, autoUnlock: 1)
        #expect(some.contains("Na 1 komputerze aplikacja uzbroi jednorazowe odblokowanie dysku"), "\(some)")
        #expect(some.contains("Na 2 komputerach po ponownym uruchomieniu pojawi się ekran odblokowania dysku"), "\(some)")
    }
}
