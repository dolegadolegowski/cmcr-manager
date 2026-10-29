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

    /// The `.local` names (lowercased) of the Macs on the list that are not renamed, with the Mac that has the name: from
    /// its `.local` address, from its name on the list (the name a rename gives it by default) and from the
    /// LocalHostName read from it, when known (`readNames`: the app passes what it read, cmcrctl reads nothing). A new
    /// name among them is an error in `cmcrctl rename KOMP` and in the app's „Zmień nazwy komputerów” alike – one rule
    /// for both (AUDIT REV-58): Bonjour would rename one of the Macs (imac04-2) and the updated list would point at the
    /// other one (AUDIT KOM-15, REV-33).
    public static func namesTaken(by machines: [Machine], renaming: Set<UUID>,
                                  readNames: [UUID: String] = [:]) -> [String: String] {
        var taken: [String: String] = [:]
        for m in machines where !renaming.contains(m.id) {
            var names = current(m, read: readNames[m.id])
            let listed = ComputerNames.localHostName(from: m.name).lowercased()
            if !listed.isEmpty { names.insert(listed) }
            for name in names { taken[name] = m.name }
        }
        return taken
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

    /// How the Macs `namesStillHeld` reported can be renamed after all: one Mac per run, with the list updated after
    /// each, since every run checks the new names against the list (AUDIT REV-54).
    public enum Order: Equatable, Sendable {
        /// A renumbering: the Mac whose new name is free first, the Mac asked about last (imac05 → imac06 → imac07 →
        /// imac08: imac08, imac07, imac06).
        case steps([Machine])
        /// The names go round – a swap or a rotation (imac01 → imac02 → imac03 → imac01): none of these Macs can be
        /// renamed first, one of them needs a temporary name. Starts at the Mac asked about when it is one of them.
        case loop([Machine])
    }

    /// The order for `machine`: along the Macs that still have the name the previous one gets (`stillHeld`, from
    /// `namesStillHeld`) to a Mac whose new name is free, or back to a Mac met before.
    public static func order(of machine: Machine, stillHeld: [UUID: Machine]) -> Order {
        var chain = [machine]
        while let holder = stillHeld[chain[chain.count - 1].id] {
            if let start = chain.firstIndex(where: { $0.id == holder.id }) { return .loop(Array(chain[start...])) }
            chain.append(holder)
        }
        return .steps(chain.reversed())
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
