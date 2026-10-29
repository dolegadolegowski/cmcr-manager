import Foundation

/// Checks of a batch rename of computers (ComputerName, LocalHostName, HostName) that look at the other Macs renamed in
/// the same run: `cmcrctl rename KOMP` and the app's „Zmień nazwy komputerów” (AUDIT REV-52).
public enum RenamePlan {
    /// One Mac to rename: its entry on the list and its new LocalHostName.
    public struct Rename: Sendable {
        public var machine: Machine
        public var localHostName: String

        public init(machine: Machine, localHostName: String) {
            self.machine = machine
            self.localHostName = localHostName
        }
    }

    /// The renamed Macs whose new `.local` name another Mac of the same run still has now and gives up – a renumbering
    /// (imac05 → imac06 while imac06 → imac07) or a swap – with that other Mac. Nothing makes the other Mac release the
    /// name first (cmcrctl renames in list order, the app all at once): the Mac claiming it would get a numbered name
    /// from Bonjour (imac06-2) and the updated list would point at no Mac. Such Macs are renamed in two steps.
    ///
    /// A Mac's current names: its `.local` address on the list and, in the app, the LocalHostName read from it
    /// (`currentNames`). A Mac that keeps its name gives nothing up – another Mac with the same new name is a
    /// duplicate, which the callers report as such.
    public static func namesStillHeld(_ renames: [Rename], currentNames: [UUID: String] = [:]) -> [UUID: Machine] {
        var givenUp: [String: Machine] = [:]
        for r in renames {
            let new = r.localHostName.lowercased()
            for name in current(r.machine, read: currentNames[r.machine.id]) where name != new && givenUp[name] == nil {
                givenUp[name] = r.machine
            }
        }
        var held: [UUID: Machine] = [:]
        for r in renames {
            if let holder = givenUp[r.localHostName.lowercased()], holder.id != r.machine.id {
                held[r.machine.id] = holder
            }
        }
        return held
    }

    /// The `.local` names (lowercased) a Mac has now: from its `.local` address and the LocalHostName read from it.
    static func current(_ machine: Machine, read: String?) -> Set<String> {
        var names: Set<String> = []
        let address = machine.address.lowercased()
        if address.hasSuffix(".local") { names.insert(String(address.dropLast(".local".count))) }
        if let read = read?.lowercased(), !read.isEmpty { names.insert(read) }
        return names
    }
}
