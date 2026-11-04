import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, group G2 (remote scripts and the setup command line). The script fixes (REV-06 …
/// REV-09) are tested end to end in Tests/e2e/suites/rev-g2-scripts.sh.
struct RevG2scriptsTests {
    /// The toggle in Przygotowanie iMaców (SetupOptionsSheet, „nazwa jak w macOS”).
    static let appToggle = "Zdalne logowanie tylko kluczem"

    static var savedKeyOnly: SetupOptions {
        var o = SetupOptions()
        o.sshKeyOnly = true
        return o
    }

    /// AUDIT REV-10: the error sent the teacher to „SSH wyłącznie z kluczem” in the app, an option that is not there.
    @Test func noKeyErrorNamesTheToggleAsTheAppShowsIt() throws {
        do {
            _ = try SetupCommandLine(parsing: ["all", "--no-key"], saved: Self.savedKeyOnly)
            Issue.record("--no-key przyjęte mimo „\(Self.appToggle)” z aplikacji")
        } catch {
            let text = error.localizedDescription
            #expect(text.contains("„\(Self.appToggle)”"), "\(text)")
            #expect(text.contains("Przygotowanie iMaców"), "\(text)")
            #expect(text.contains("--no-ssh-key-only"), "\(text)")
            #expect(!text.contains("SSH wyłącznie z kluczem"), "\(text)")
        }
    }

    @Test func helpNamesTheToggleTheDefaultComesFrom() {
        #expect(SetupCommandLine.optionsHelp.contains("„\(Self.appToggle)”"), "\(SetupCommandLine.optionsHelp)")
    }
}
