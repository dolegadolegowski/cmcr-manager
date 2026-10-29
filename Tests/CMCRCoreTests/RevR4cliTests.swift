import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 4, group R4-cli: one rule for the names a batch rename may not take (cmcrctl and the
/// app's „Zmień nazwy komputerów”, REV-58) and the order in which renumbered or rotated names can be changed (REV-54).
/// The cmcrctl messages (also REV-55) are tested end to end in Tests/e2e/suites/rev-r4-cli.sh.
struct RevR4cliTests {
    private func mac(_ name: String, _ address: String) -> Machine {
        Machine(name: name, address: address, user: "admin")
    }

    private func held(_ pairs: [(Machine, String)]) -> [UUID: Machine] {
        RenamePlan.namesStillHeld(pairs.map { RenamePlan.Rename(machine: $0.0, localHostName: $0.1) })
    }

    /// AUDIT REV-58: the names the other Macs on the list have come from their `.local` address, their name on the
    /// list and – when it was read (the app) – their LocalHostName. The app used to skip the list name (a Mac listed by
    /// its IP address and not read did not block its name), cmcrctl gets no read names.
    @Test func theNamesTakenComeFromTheAddressTheListNameAndTheNameRead() {
        let listed = mac("imac03", "192.0.2.13")
        let read = mac("imac08", "192.0.2.18")
        let local = mac("imac04", "IMAC04.local")
        let renamed = mac("imac05", "imac06.local")
        let all = [listed, read, local, renamed]
        let app = RenamePlan.namesTaken(by: all, renaming: [renamed.id], readNames: [read.id: "iMac07", renamed.id: "imac09"])
        #expect(app["imac03"] == "imac03")
        #expect(app["imac07"] == "imac08")
        #expect(app["imac08"] == "imac08")
        #expect(app["imac04"] == "imac04")
        // A Mac renamed in the same run gives its names up (a chain is RenamePlan.namesStillHeld's job).
        #expect(app["imac05"] == nil && app["imac06"] == nil && app["imac09"] == nil)
        #expect(app.count == 4)
        let cli = RenamePlan.namesTaken(by: all, renaming: [renamed.id])
        #expect(cli["imac03"] == "imac03")
        #expect(cli["imac07"] == nil)
        #expect(cli.count == 3)
        // The list name counts as the LocalHostName a rename would give it.
        let polish = mac("Pracownia Łódź", "192.0.2.20")
        #expect(RenamePlan.namesTaken(by: [polish], renaming: [])["pracownia-lodz"] == "Pracownia Łódź")
    }

    /// AUDIT REV-54: names moved round three Macs (imac01 → imac02 → imac03 → imac01). Whichever Mac is reported, no
    /// Mac of the rotation can be renamed first – one of them needs a temporary name, as in a swap.
    @Test func aRotationIsALoopForEveryMacOfIt() {
        let a = mac("imac02", "imac01.local"), b = mac("imac03", "imac02.local"), c = mac("imac01", "imac03.local")
        let stillHeld = held([(a, "imac02"), (b, "imac03"), (c, "imac01")])
        #expect(stillHeld.count == 3)
        #expect(RenamePlan.order(of: a, stillHeld: stillHeld) == .loop([a, b, c]))
        #expect(RenamePlan.order(of: b, stillHeld: stillHeld) == .loop([b, c, a]))
        #expect(RenamePlan.order(of: c, stillHeld: stillHeld) == .loop([c, a, b]))
        let x = mac("imac02", "imac01.local"), y = mac("imac01", "imac02.local")
        #expect(RenamePlan.order(of: x, stillHeld: held([(x, "imac02"), (y, "imac01")])) == .loop([x, y]))
    }

    /// AUDIT REV-54: a renumbering is renamed from the Mac whose new name is free, one Mac at a time – also when the
    /// chain is longer than two (imac05 → imac06 → imac07 → imac08).
    @Test func aRenumberingIsRenamedFromItsFreeEnd() {
        let six = mac("imac06", "imac05.local"), seven = mac("imac07", "imac06.local"), eight = mac("imac08", "imac07.local")
        let stillHeld = held([(six, "imac06"), (seven, "imac07"), (eight, "imac08")])
        #expect(RenamePlan.order(of: six, stillHeld: stillHeld) == .steps([eight, seven, six]))
        #expect(RenamePlan.order(of: seven, stillHeld: stillHeld) == .steps([eight, seven]))
        #expect(RenamePlan.order(of: eight, stillHeld: stillHeld) == .steps([eight]))
    }

    /// AUDIT REV-54: a Mac whose chain runs into a loop it is not part of (two Macs claiming the same name) gets the
    /// loop – its Macs need the temporary name; the walk ends.
    @Test func aChainIntoALoopEndsAtTheLoop() {
        let p = mac("imac02", "imac01.local"), q = mac("imac01", "imac02.local"), r = mac("imac01", "imac03.local")
        let stillHeld = held([(p, "imac02"), (q, "imac01"), (r, "imac01")])
        #expect(stillHeld[r.id]?.id == p.id)
        #expect(RenamePlan.order(of: r, stillHeld: stillHeld) == .loop([p, q]))
    }
}
