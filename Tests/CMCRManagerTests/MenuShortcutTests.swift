import SwiftUI
import Testing
@testable import CMCRManager

/// settings-shortcut (AUDIT UI-01): ⌘, is the system's „Ustawienia…” (the Settings window); every section has its
/// own shortcut and no two menu items share one.
@MainActor
@Suite struct MenuShortcutTests {
    func text(_ s: KeyboardShortcut) -> String { "\(s.modifiers.rawValue)-\(s.key.character)" }

    @Test func noSectionTakesTheSettingsShortcut() {
        let settings = text(KeyboardShortcut(",", modifiers: .command))
        #expect(!AppSection.allCases.map { text($0.keyboardShortcut) }.contains(settings))
        #expect(AppSection.setup.shortcutText == "⇧⌘,")
    }

    @Test func sectionShortcutsAreUnique() {
        let all = AppSection.allCases.map { text($0.keyboardShortcut) }
        #expect(Set(all).count == all.count)
    }

    @Test func helpOpensTheManual() {
        #expect(HelpLinks.manual.absoluteString == "https://github.com/dolegadolegowski/cmcr-manager#readme")
    }
}
