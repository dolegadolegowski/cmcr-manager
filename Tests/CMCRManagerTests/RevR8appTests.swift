import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// A Mac checked in „Zmień nazwy komputerów” whose name stays as it is, is not renamed: its names stay taken for the
/// others (AUDIT REV-71).
@Suite struct RevR8appTests {
    @Test func aMacThatKeepsItsNameKeepsItsAddressForItself() {
        // imac03 was renamed on the Mac earlier, but its list entry still has the old address imac07.local.
        let kept = Machine(name: "imac03", address: "imac07.local", user: "imac03")
        let other = Machine(name: "imac05", address: "imac05.local", user: "imac05")
        let entries = [RenameComputersSheet.Entry(machine: kept, newName: "imac03"),
                       RenameComputersSheet.Entry(machine: other, newName: "imac07")]
        let c = RenameComputersSheet.conflicts(entries: entries, unchanged: [kept.id], machines: [kept, other],
                                               readNames: [kept.id: "imac03"])
        #expect(c.taken["imac07"] == "imac03")
        #expect(c.taken["imac03"] == "imac03")
        // The Mac that keeps its name is no conflict with itself.
        #expect(!c.duplicates.contains("imac03"))
        #expect(c.duplicates.contains("imac07"))
    }

    @Test func aMacThatKeepsItsNameIsNotRepeatedByItself() {
        let kept = Machine(name: "imac03", address: "imac03.local", user: "imac03")
        let other = Machine(name: "imac05", address: "imac05.local", user: "imac05")
        let entries = [RenameComputersSheet.Entry(machine: kept, newName: "imac03"),
                       RenameComputersSheet.Entry(machine: other, newName: "imac06")]
        let c = RenameComputersSheet.conflicts(entries: entries, unchanged: [kept.id], machines: [kept, other],
                                               readNames: [kept.id: "imac03"])
        #expect(c.duplicates.isEmpty)
        #expect(c.taken["imac06"] == nil)
    }
}
