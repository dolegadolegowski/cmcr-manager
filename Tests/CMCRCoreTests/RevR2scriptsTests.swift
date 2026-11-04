import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 2, group R2-scripts (remote scripts and the one-time setup script). The script
/// fixes (REV-39 … REV-41) are tested end to end in Tests/e2e/suites/rev-r2-scripts.sh.
struct RevR2scriptsTests {
    /// AUDIT REV-42: the SSH detail is one Core text shown in the app's popover, in the cell's tooltip and by
    /// `cmcrctl readiness`. Only the popover has the fix button under it, so the text must not point „(niżej)”.
    @Test func theMissingKeyDetailDoesNotPointBelow() {
        let report = ReadinessReport.parse("os=14.7\nadmin=imac07\nconsole=student\nkey=missing\nfolder=ok\nsudo=ok\n",
                                           student: "student", sharedFolder: "/Users/student/Public/cmcr")
        let ssh = report[.ssh]
        #expect(ssh.state == .warning)
        #expect(!ssh.detail.contains("niżej"), "\(ssh.detail)")
        #expect(!ssh.detail.contains("poniżej"), "\(ssh.detail)")
        // The fixes themselves are still named.
        #expect(ssh.detail.contains("„Zainstaluj klucz logowania”"), "\(ssh.detail)")
        #expect(ssh.detail.contains("„Roześlij klucz”"), "\(ssh.detail)")
    }
}
