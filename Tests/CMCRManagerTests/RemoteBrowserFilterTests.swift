import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// browser-hidden-selection (AUDIT PLI-12): selected items that a filter hides (hidden files switched off, a search)
/// stop being selected, so „Usuń…” and „Pobierz” act only on what the teacher sees.
@MainActor
@Suite struct RemoteBrowserFilterTests {
    let entries = [
        RemoteEntry(name: ".git", kind: .directory),
        RemoteEntry(name: "Projekt", kind: .directory),
        RemoteEntry(name: "notatki.txt", kind: .file),
        RemoteEntry(name: ".DS_Store", kind: .file),
    ]
    let order = [KeyPathComparator(\RemoteEntry.name, comparator: .localizedStandard)]

    @Test func hidingFilesDropsThemFromTheSelection() {
        let all = RemoteBrowserModel.visible(entries, showHidden: true, search: "", sortOrder: order)
        let everything = Set(all.map(\.id))                                   // ⌘A with hidden files shown
        #expect(everything.count == 4)
        let shown = RemoteBrowserModel.visible(entries, showHidden: false, search: "", sortOrder: order)
        #expect(shown.map(\.name) == ["Projekt", "notatki.txt"])
        #expect(RemoteBrowserModel.keptSelection(everything, visible: shown) == Set(["Projekt", "notatki.txt"]))
    }

    @Test func aSearchDropsTheItemsItHidesFromTheSelection() {
        let all = RemoteBrowserModel.visible(entries, showHidden: false, search: "", sortOrder: order)
        let found = RemoteBrowserModel.visible(entries, showHidden: false, search: "notat", sortOrder: order)
        #expect(found.map(\.name) == ["notatki.txt"])
        #expect(RemoteBrowserModel.keptSelection(Set(all.map(\.id)), visible: found) == ["notatki.txt"])
    }

    /// AUDIT DOD-13: a direction override in a student's file name is shown, not applied (no „pracadnammoc.pdf”).
    @Test func namesFromTheIMacsShowDirectionOverrides() {
        let entry = RemoteEntry(name: "praca\u{202E}fdp.command", kind: .file)
        #expect(entry.displayName == "praca\\u{202E}fdp.command")
        #expect(RemoteEntry(name: "a\nb", kind: .file).displayName == "a\\nb")
        #expect(TerminalText.visibleDirectionOverrides("✔ praca\u{202E}fdp.command\n") == "✔ praca<U+202E>fdp.command\n")
    }
}
