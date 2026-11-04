import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Review of the audit fixes, round 8, group R8-rename: the red row of „Zmień nazwy komputerów” for a Mac whose new
/// name another renamed Mac still has names the Mac that has the name as its address, and gives the real reason when
/// the other Mac has it only as its name on the list (REV-73).
@Suite struct RevR8renameTests {
    private func mac(_ name: String, _ address: String) -> Machine {
        Machine(name: name, address: address, user: "admin")
    }

    private func renames(_ typed: [(Machine, String)]) -> [RenamePlan.Rename] {
        typed.map { RenamePlan.Rename(machine: $0.0, localHostName: ComputerNames.localHostName(from: $0.1)) }
    }

    private let addressReason = "macOS nadałby jednemu z nich inny adres."

    /// AUDIT REV-73: imac05 → imac02, while „imac02” at imac06.local becomes imac07 and „imac04” at imac02.local
    /// becomes imac08. Both Macs still have the name (RenamePlan.holders, in the order of the selected Macs), and the
    /// row named the first one: „imac02.local ma jeszcze imac02” – but imac02.local is the address of imac04.
    @Test func theMacWithTheAddressIsNamed() {
        let x = mac("imac05", "imac05.local"), y = mac("imac02", "imac06.local"), z = mac("imac04", "imac02.local")
        let read = [x.id: "imac05", y.id: "imac06", z.id: "imac02"]
        let holders = RenamePlan.holders(renames([(x, "imac02"), (y, "imac07"), (z, "imac08")]), currentNames: read)
        #expect(holders[x.id]?.map(\.id) == [y.id, z.id])
        let text = RenameComputersSheet.stillHeldText(localHostName: "imac02", holders: holders[x.id] ?? [], readNames: read)
        #expect(text?.label == "imac02.local ma jeszcze imac04")
        #expect(text?.reason == "Ten adres ma teraz imac04, którego nazwa też jest zmieniana – \(addressReason)")
        // Without the names read from the iMacs the address on the list says the same.
        let unread = RenameComputersSheet.stillHeldText(localHostName: "imac02", holders: holders[x.id] ?? [], readNames: [:])
        #expect(unread?.label == "imac02.local ma jeszcze imac04")
    }

    /// AUDIT REV-73: imac03 → imac02 while „imac02” at imac06.local becomes imac07. No Mac has imac02.local, so macOS
    /// gives nobody another address; the step waits because the list would have two Macs named imac02 if the rename of
    /// the other one failed. The row said that macOS would give one of them another address.
    @Test func aNameOnlyOnTheListIsNoAddressConflict() {
        let a = mac("imac03", "imac03.local"), b = mac("imac02", "imac06.local")
        let read = [a.id: "imac03", b.id: "imac06"]
        let holders = RenamePlan.holders(renames([(a, "imac02"), (b, "imac07")]), currentNames: read)
        let text = RenameComputersSheet.stillHeldText(localHostName: "imac02", holders: holders[a.id] ?? [], readNames: read)
        #expect(text?.label == "„imac02” jest jeszcze na liście")
        #expect(text?.reason == "Na liście jest jeszcze komputer „imac02” (imac06.local), którego nazwa też jest zmieniana "
            + "– gdyby jego zmiana się nie udała, lista miałaby dwa komputery o tej nazwie.")
        #expect(text?.reason.contains("macOS") == false)
    }

    /// The name read from the iMac counts as its address: „imac02” whose entry still has the old address imac09.local
    /// but which is imac06 now.
    @Test func theNameReadFromTheMacCountsAsItsAddress() {
        let a = mac("imac05", "imac05.local"), b = mac("imac02", "imac09.local")
        let read = [a.id: "imac05", b.id: "imac06"]
        let holders = RenamePlan.holders(renames([(a, "imac06"), (b, "imac07")]), currentNames: read)
        let text = RenameComputersSheet.stillHeldText(localHostName: "imac06", holders: holders[a.id] ?? [], readNames: read)
        #expect(text?.label == "imac06.local ma jeszcze imac02")
        #expect(text?.reason.hasSuffix(addressReason) == true)
    }

    /// A renumbering of Macs whose names on the list are their addresses keeps its wording: imac05 → imac06 while
    /// imac06 → imac07. A Mac whose new name nobody still has gets no such row.
    @Test func aRenumberingKeepsItsWording() {
        let a = mac("imac05", "imac05.local"), b = mac("imac06", "imac06.local")
        let read = [a.id: "imac05", b.id: "imac06"]
        let holders = RenamePlan.holders(renames([(a, "imac06"), (b, "imac07")]), currentNames: read)
        let text = RenameComputersSheet.stillHeldText(localHostName: "imac06", holders: holders[a.id] ?? [], readNames: read)
        #expect(text?.label == "imac06.local ma jeszcze imac06")
        #expect(text?.reason == "Ten adres ma teraz imac06, którego nazwa też jest zmieniana – \(addressReason)")
        #expect(RenameComputersSheet.stillHeldText(localHostName: "imac07", holders: holders[b.id] ?? [], readNames: read) == nil)
    }
}
