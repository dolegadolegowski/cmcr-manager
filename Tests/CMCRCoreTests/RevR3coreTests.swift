import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 3, group R3-core. The script fixes (REV-48 … REV-50) are tested end to end in
/// Tests/e2e/suites/rev-r3-core.sh.
struct RevR3coreTests {
    /// AUDIT REV-47: what `describe` prints is pasted into an interactive shell (the `logout --force` hint, actions.log).
    /// zsh and bash expand `!` even outside quotes (history), zsh a leading `=` (a command's path) and `^` with
    /// EXTENDED_GLOB: such an argument is quoted, so the pasted command runs as written.
    @Test func historyAndEqualsCharactersAreQuoted() {
        #expect(CommandLineLog.describe(["logout", "Sala!B", "--force"]) == "logout 'Sala!B' --force")
        #expect(CommandLineLog.describe(["logout", "=imac3", "--force"]) == "logout '=imac3' --force")
        #expect(CommandLineLog.describe(["logout", "imac^3"]) == "logout 'imac^3'")
        #expect(CommandLineLog.describe(["message", "Koniec!", "1"]) == "message 'Koniec!' 1")
    }

    /// Plain words stay as they are: the log keeps reading like the command that was typed.
    @Test func plainWordsStayUnquoted() {
        #expect(CommandLineLog.describe(["power", "display-sleep", "1,2", "--yes"]) == "power display-sleep 1,2 --yes")
        #expect(CommandLineLog.describe(["push", "1", "/Users/{student}/Desktop"]) == "push 1 '/Users/{student}/Desktop'")
        #expect(CommandLineLog.describe(["exec", "a=1", "imac01"]) == "exec a=1 imac01")
        #expect(CommandLineLog.describe(["logout", "pracownia-łąka_2", "--force"]) == "logout pracownia-łąka_2 --force")
        #expect(CommandLineLog.describe(["install-url", "https://example.com/a@b.pkg", "50%+1"])
                == "install-url https://example.com/a@b.pkg 50%+1")
    }
}
