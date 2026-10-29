import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 4, group R4-core.
struct RevR4coreDescribeTests {
    /// AUDIT REV-56: zsh turns a word that begins with `=` into a command's path, so `describe` quotes it. A combining
    /// mark (U+0301), a variation selector (U+FE0F) or a spacing mark (U+0903) right after the `=` joins it into one
    /// Character, and the Character-based `hasPrefix("=")` missed it: the `logout --force` hint stayed unquoted and zsh
    /// answered „́imac3 not found”. Such a name passes the host list's validation.
    @Test func aLeadingEqualsJoinedWithAMarkIsQuoted() {
        for name in ["=\u{0301}imac3", "=\u{FE0F}imac3", "=\u{0903}imac3"] {
            let scalars = name.unicodeScalars.map { String($0.value, radix: 16) }
            #expect(!name.hasPrefix("="), "\(scalars): przypadek z błędu nie jest już odtwarzany")
            #expect(CommandLineLog.describe(["logout", name, "--force"]) == "logout '\(name)' --force", "\(scalars)")
        }
        // A mark later in the word changes nothing: zsh expands only a leading `=`.
        #expect(CommandLineLog.describe(["logout", "imac=\u{0301}3"]) == "logout imac=\u{0301}3")
    }
}
