import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 4, group R4-cli: one rule for the names a batch rename may not take (cmcrctl and the
/// app's „Zmień nazwy komputerów”, REV-58). The cmcrctl side is tested end to end in Tests/e2e/suites/rev-r4-cli.sh.
struct RevR4cliTests {
    private func mac(_ name: String, _ address: String) -> Machine {
        Machine(name: name, address: address, user: "admin")
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
}
