import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 5, group R5-rename: a name repeated among the renamed Macs is reported before the
/// order of a renumbering or a swap (REV-62). The cmcrctl messages are tested end to end in
/// Tests/e2e/suites/rev-r5-rename.sh.
struct RevR5renameTests {
    /// AUDIT REV-62: the `.local` names more than one renamed Mac would get – compared without case, as Bonjour does –
    /// are an error for each of those Macs (cmcrctl used to report only the second one, and only when its name was not
    /// still held by another renamed Mac).
    @Test func aNameRepeatedAmongTheRenamedMacsIsFoundForAllOfThem() {
        #expect(RenamePlan.repeatedNames(["imac02", "imac01", "IMAC02", "imac03"]) == ["imac02"])
        #expect(RenamePlan.repeatedNames(["imac05", "imac06", "imac05", "imac05"]) == ["imac05"])
        #expect(RenamePlan.repeatedNames(["imac01", "imac02"]).isEmpty)
        #expect(RenamePlan.repeatedNames([]).isEmpty)
    }
}
