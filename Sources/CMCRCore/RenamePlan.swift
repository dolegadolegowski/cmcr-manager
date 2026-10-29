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

    /// The new `.local` names (lowercased) that more than one of the renamed Macs would get: an error for each of those
    /// Macs, in `cmcrctl rename KOMP` and the app's „Zmień nazwy komputerów” alike, reported before the order of a
    /// renumbering or a swap (AUDIT REV-62) – advice about the order cannot be completed while two Macs want one name,
    /// and Bonjour would rename all but one of them (imac04-2).
    public static func repeatedNames(_ localHostNames: [String]) -> Set<String> {
        var seen: Set<String> = [], twice: Set<String> = []
        for name in localHostNames.map({ $0.lowercased() }) where !seen.insert(name).inserted {
            twice.insert(name)
        }
        return twice
    }

    /// The renamed Macs whose new `.local` name another Mac of the same run still has now and gives up – a renumbering
    /// (imac05 → imac06 while imac06 → imac07) or a swap – with that other Mac. Nothing makes the other Mac release the
    /// name first (cmcrctl renames in list order, the app all at once): the Mac claiming it would get a numbered name
    /// from Bonjour (imac06-2) and the updated list would point at no Mac. Such Macs are renamed one per run, in the
    /// order `advice(for:stillHeld:newNames:in:)` gives.
    ///
    /// A Mac's current names: its `.local` address on the list and, in the app, the LocalHostName read from it
    /// (`currentNames`). A Mac that keeps its name gives nothing up – another Mac with the same new name is a
    /// duplicate, which the callers report as such (`repeatedNames`), before this.
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

    /// One run of the order `steps(for:stillHeld:)` gives: one Mac renamed, with the list updated after it.
    public enum Step: Equatable, Sendable {
        /// The Mac gets its new name.
        case rename(Machine)
        /// The Mac gets a temporary name first: the names go round.
        case temporary(Machine)
        /// The Mac that got the temporary name gets its new name.
        case target(Machine)
    }

    /// The whole order for `machine`, one Mac per run (AUDIT REV-61). A renumbering goes from its free end. Names that
    /// go round start with a temporary name for the first Mac of the loop (the Mac asked about when it is one of
    /// them); that frees the name of the Mac before it in the loop, so the others follow backwards round the loop and
    /// the first Mac gets its new name last. A Mac whose chain runs into a loop it is not part of comes after the
    /// loop, with the Macs between them.
    public static func steps(for machine: Machine, stillHeld: [UUID: Machine]) -> [Step] {
        switch order(of: machine, stillHeld: stillHeld) {
        case .steps(let chain):
            return chain.map(Step.rename)
        case .loop(let loop):
            var before: [Machine] = []
            var m = machine
            while !loop.contains(where: { $0.id == m.id }), let holder = stillHeld[m.id] {
                before.append(m)
                m = holder
            }
            return [.temporary(loop[0])] + loop.dropFirst().reversed().map(Step.rename) + [.target(loop[0])]
                + before.reversed().map(Step.rename)
        }
    }

    /// Where the advice is read: each step is a run of `cmcrctl rename KOMP`, or the app's „Zmień nazwy komputerów”
    /// with one Mac selected.
    public enum Tool: Sendable {
        case cmcrctl, app
    }

    /// How to rename `machine`, whose new name another Mac renamed in the same run still has – advice that works when
    /// followed (AUDIT REV-54, REV-61): the whole order of `steps(for:stillHeld:)`, one Mac per run, with the list
    /// updated after each – otherwise the list keeps the old address of the Mac renamed before, and the next step is
    /// refused as taken (AUDIT REV-55). cmcrctl names --update-list, and --name for the temporary name and, at the end,
    /// for the new name (the list has the temporary name by then); the app selects one Mac at a time and updates the
    /// list itself when its „Zaktualizuj nazwy i adresy na liście” is on – one order in both (AUDIT REV-63).
    /// `newNames`: the name each Mac gets (default: its name on the list, as in cmcrctl).
    public static func advice(for machine: Machine, stillHeld: [UUID: Machine], newNames: [UUID: String] = [:],
                              in tool: Tool) -> String {
        let eachRun = tool == .cmcrctl ? "za każdym razem z --update-list"
            : "zaznaczając za każdym razem tylko jeden komputer, z włączoną aktualizacją listy komputerów"
        let byName = tool == .cmcrctl ? " (--name)" : ""
        let loop: [Machine]
        switch order(of: machine, stillHeld: stillHeld) {
        case .steps(let chain):
            return (chain.count > 2 ? "Zmień nazwy po kolei" : "Zmień nazwy w dwóch krokach")
                + ", \(eachRun): najpierw " + chain.map(\.name).joined(separator: ", potem ") + "."
        case .loop(let l) where l.count == 2 && l[0].id == machine.id:
            // A swap: either Mac can go first.
            return "Przy zamianie nazw nadaj najpierw jednemu z nich nazwę tymczasową\(byName), potem zmień nazwę drugiego, "
                + "a na końcu nadaj pierwszemu docelową nazwę\(byName), \(eachRun)."
        case .loop(let l):
            loop = l
        }
        let names = loop.map(\.name)
        var phrases: [String] = []
        var afterRename = false
        for step in steps(for: machine, stillHeld: stillHeld) {
            switch step {
            case .temporary(let m):
                phrases.append("nadaj \(m.name) nazwę tymczasową\(byName)")
            case .rename(let m):
                phrases.append(afterRename ? m.name : "zmień nazwę \(m.name)")
            case .target(let m):
                phrases.append("nadaj komputerowi z nazwą tymczasową docelową nazwę \(newNames[m.id] ?? m.name)\(byName)")
            }
            if case .rename = step { afterRename = true } else { afterRename = false }
        }
        return "Komputery \(names.dropLast().joined(separator: ", ")) i \(names[names.count - 1]) zamieniają się nazwami"
            + (loop.count > 2 ? " w kółko" : "") + ". Zmień nazwy po kolei, \(eachRun): najpierw "
            + phrases.dropLast().joined(separator: ", potem ") + ", a na końcu \(phrases[phrases.count - 1])."
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
