import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 3, group R3-cli. The cmcrctl fixes (REV-44, REV-46, REV-51 and the cmcrctl side of
/// REV-52) are tested end to end in Tests/e2e/suites/rev-r3-cli.sh.
struct RevR3cliTests {
    private func mac(_ name: String, _ address: String) -> Machine {
        Machine(name: name, address: address, user: "admin")
    }

    private func renames(_ pairs: [(Machine, String)]) -> [RenamePlan.Rename] {
        pairs.map { RenamePlan.Rename(machine: $0.0, localHostName: $0.1) }
    }

    /// AUDIT REV-52: in a swap each Mac would claim the address the other one still announces – both are reported.
    @Test func aSwapIsReportedForBothMacs() {
        let a = mac("imac02", "imac01.local"), b = mac("imac01", "imac02.local")
        let held = RenamePlan.namesStillHeld(renames([(a, "imac02"), (b, "imac01")]))
        #expect(held[a.id]?.id == b.id)
        #expect(held[b.id]?.id == a.id)
    }

    /// AUDIT REV-52: renumbering upwards – imac05 → imac06 while imac06 → imac07. Only the Mac claiming a name that
    /// another renamed Mac has now is reported; the last one of the chain moves to a free name.
    @Test func aRenumberingChainIsReportedWhereANameIsStillHeld() {
        let five = mac("imac06", "imac05.local"), six = mac("imac07", "imac06.local")
        let held = RenamePlan.namesStillHeld(renames([(five, "imac06"), (six, "imac07")]))
        #expect(held[five.id]?.id == six.id)
        #expect(held[six.id] == nil)
        #expect(held.count == 1)
        // In the other direction too: the order the renames run in is not relied on (the app runs them at once).
        let a = mac("imac05", "imac06.local"), b = mac("imac06", "imac07.local")
        let down = RenamePlan.namesStillHeld(renames([(a, "imac05"), (b, "imac06")]))
        #expect(down[b.id]?.id == a.id)
        #expect(down[a.id] == nil)
    }

    /// AUDIT REV-52: the name read from the Mac (the app) counts like its `.local` address – also for a Mac whose list
    /// address is not a `.local` name.
    @Test func theNameReadFromTheMacCounts() {
        let x = mac("imac07", "10.0.5.6"), y = mac("imac06", "imac05.local")
        let rs = renames([(x, "imac07"), (y, "imac06")])
        #expect(RenamePlan.namesStillHeld(rs).isEmpty)
        let held = RenamePlan.namesStillHeld(rs, currentNames: [x.id: "iMac06"])
        #expect(held[y.id]?.id == x.id)
    }

    /// AUDIT REV-52: what is not a chain stays allowed – a Mac renamed to its own current name, renamed Macs whose
    /// current names nobody claims, case of the names, and addresses that are not `.local` names.
    @Test func renamesWithoutAChainAreNotReported() {
        let four = mac("imac04", "IMAC04.local"), seven = mac("imac07", "imac06.local")
        #expect(RenamePlan.namesStillHeld(renames([(four, "imac04"), (seven, "imac07")])).isEmpty)
        let ip = mac("imac01", "192.168.1.10"), other = mac("imac02", "imac03.local")
        #expect(RenamePlan.namesStillHeld(renames([(ip, "imac01"), (other, "imac02")])).isEmpty)
        // A Mac keeping its name gives nothing up: a second Mac with that new name is a duplicate, reported as such.
        let keeps = mac("imac08", "imac08.local"), twice = mac("imac08", "imac09.local")
        #expect(RenamePlan.namesStillHeld(renames([(keeps, "imac08"), (twice, "imac08")])).isEmpty)
        // Case does not hide a chain.
        let up = mac("iMac06", "imac05.local"), next = mac("imac07", "IMAC06.local")
        #expect(RenamePlan.namesStillHeld(renames([(up, "iMac06"), (next, "imac07")]))[up.id]?.id == next.id)
    }
}
