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
            for name in names(of: m, read: readNames[m.id]) { taken[name] = m.name }
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

    /// Why a renamed Mac cannot get its new name, whatever the order: an error of its own, in `cmcrctl rename KOMP`
    /// and in the app's „Zmień nazwy komputerów” alike. No order of a renumbering or a swap is given that runs through
    /// such a Mac (AUDIT REV-64).
    public enum Rejection: Equatable, Sendable {
        /// The name gives no valid LocalHostName.
        case invalid
        /// Another Mac on the list has the `.local` name (`namesTaken`).
        case taken(by: String)
        /// Another renamed Mac would get the same `.local` name (`repeatedNames`).
        case repeated

        /// Why, as the advice puts it („popraw nazwę imac07 (adres ma już imac08)”).
        var reason: String {
            switch self {
            case .invalid: "niepoprawna nazwa"
            case .taken(let owner): "adres ma już \(owner)"
            case .repeated: "adres powtarza się"
            }
        }
    }

    /// The renamed Macs that cannot get their new names whatever the order, checked as both callers report them: an
    /// invalid name, then a name another Mac on the list has (`taken`, from `namesTaken`), then a name repeated among
    /// the renamed Macs.
    public static func rejections(_ renames: [Rename], taken: [String: String]) -> [UUID: Rejection] {
        let repeated = repeatedNames(renames.map(\.localHostName))
        var rejected: [UUID: Rejection] = [:]
        for r in renames {
            let name = r.localHostName.lowercased()
            if !ComputerNames.isValidLocalHostName(r.localHostName) {
                rejected[r.machine.id] = .invalid
            } else if let owner = taken[name] {
                rejected[r.machine.id] = .taken(by: owner)
            } else if repeated.contains(name) {
                rejected[r.machine.id] = .repeated
            }
        }
        return rejected
    }

    /// The renamed Macs whose new `.local` name another Mac of the same run still has now and gives up – a renumbering
    /// (imac05 → imac06 while imac06 → imac07) or a swap – with that other Mac. Nothing makes the other Mac release the
    /// name first (cmcrctl renames in list order, the app all at once): the Mac claiming it would get a numbered name
    /// from Bonjour (imac06-2) and the updated list would point at no Mac. Such Macs are renamed one per run, in the
    /// order `advice(for:stillHeld:newNames:in:)` gives.
    ///
    /// A Mac's current names are the names `namesTaken` counts for a Mac that is not renamed: its `.local` address
    /// on the list, its name on the list (the name a rename gives it by default) and, in the app, the LocalHostName
    /// read from it (`currentNames`). Each step of the order checks its new name against all of them – also against
    /// the name on the list of a Mac renamed in a later step (AUDIT REV-69): the app's advice gave „najpierw imac03 na
    /// imac02, potem imac02 na imac03” while „imac02” at imac06.local was still on the list, and refused its first step.
    /// In cmcrctl the name on the list is the new name, which a Mac keeps. A Mac that keeps its name gives nothing
    /// up – another Mac with the same new name is a duplicate, which the callers report as such (`repeatedNames`),
    /// before this. The first of the Macs that still have the name (`holders`).
    public static func namesStillHeld(_ renames: [Rename], currentNames: [UUID: String] = [:]) -> [UUID: Machine] {
        holders(renames, currentNames: currentNames).compactMapValues(\.first)
    }

    /// Every Mac of the same run that still has the new name of each renamed Mac now and gives it up
    /// (`namesStillHeld`), in the order of `renames`. One Mac's name on the list is often another Mac's `.local`
    /// address, and a step is refused while any of them has the name, so the order waits for all of them (AUDIT
    /// REV-69): imac05 → imac02 after „imac02” at imac06.local and after „imac04” at imac02.local, not only the first.
    public static func holders(_ renames: [Rename], currentNames: [UUID: String] = [:]) -> [UUID: [Machine]] {
        var givenUp: [String: [Machine]] = [:]
        for r in renames {
            let new = r.localHostName.lowercased()
            for name in names(of: r.machine, read: currentNames[r.machine.id]) where name != new {
                givenUp[name, default: []].append(r.machine)
            }
        }
        var holders: [UUID: [Machine]] = [:]
        for r in renames {
            let others = givenUp[r.localHostName.lowercased(), default: []].filter { $0.id != r.machine.id }
            if !others.isEmpty { holders[r.machine.id] = others }
        }
        return holders
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
    /// `namesStillHeld`) to a Mac whose new name is free, or back to a Mac met before. One Mac per name;
    /// `steps(for:holders:)` waits for every Mac that still has it.
    public static func order(of machine: Machine, stillHeld: [UUID: Machine]) -> Order {
        var chain = [machine]
        while let holder = stillHeld[chain[chain.count - 1].id] {
            if let start = chain.firstIndex(where: { $0.id == holder.id }) { return .loop(Array(chain[start...])) }
            chain.append(holder)
        }
        return .steps(chain.reversed())
    }

    /// One run of the order `steps(for:holders:)` gives: one Mac renamed, with the list updated after it.
    public enum Step: Equatable, Sendable {
        /// The Mac gets its new name.
        case rename(Machine)
        /// The Mac gets a temporary name first: the names go round.
        case temporary(Machine)
        /// The Mac that got the temporary name gets its new name.
        case target(Machine)

        /// The Mac renamed in this step.
        public var machine: Machine {
            switch self {
            case .rename(let m), .temporary(let m), .target(let m): m
            }
        }
    }

    /// The whole order for `machine`, one Mac per run (AUDIT REV-61). A renumbering goes from its free end. Names that
    /// go round start with a temporary name for the first Mac of the loop (the Mac asked about when it is one of
    /// them); that frees the name of the Mac before it in the loop, so the others follow backwards round the loop and
    /// the first Mac gets its new name last. A Mac whose chain runs into a loop it is not part of comes after the
    /// loop, with the Macs between them. `stillHeld`: one Mac per name, as in cmcrctl, where a renamed Mac gives up
    /// only its `.local` address.
    public static func steps(for machine: Machine, stillHeld: [UUID: Machine]) -> [Step] {
        steps(for: machine, holders: stillHeld.mapValues { [$0] })
    }

    /// The whole order for `machine` when a new name may still be held by several Macs (`holders`, AUDIT REV-69): each
    /// Mac comes after every Mac that still has its new name, as in `steps(for:stillHeld:)`. A Mac met again on the
    /// way gets a temporary name there – the names go round – and its new name after the Macs it waits for; where
    /// names go round in two loops, two Macs may get temporary names.
    public static func steps(for machine: Machine, holders: [UUID: [Machine]]) -> [Step] {
        walk(from: machine, holders: holders).steps
    }

    /// The steps for `machine` and the loops met on the way, each from the Mac that gets the temporary name.
    private static func walk(from machine: Machine, holders: [UUID: [Machine]]) -> (steps: [Step], loops: [[Machine]]) {
        var steps: [Step] = [], loops: [[Machine]] = [], path: [Machine] = []
        var done: Set<UUID> = [], temporary: Set<UUID> = []
        func visit(_ m: Machine) {
            if done.contains(m.id) { return }
            if let start = path.firstIndex(where: { $0.id == m.id }) {
                // The Macs on the way from m wait for one another back to m – the names go round: a temporary name
                // frees m's names now, its new name comes after the Macs it waits for.
                loops.append(Array(path[start...]))
                if temporary.insert(m.id).inserted { steps.append(.temporary(m)) }
                return
            }
            path.append(m)
            for holder in holders[m.id] ?? [] { visit(holder) }
            path.removeLast()
            done.insert(m.id)
            steps.append(temporary.contains(m.id) ? .target(m) : .rename(m))
        }
        visit(machine)
        return (steps, loops)
    }

    /// Where the advice is read: each step is a run of `cmcrctl rename KOMP`, or the app's „Zmień nazwy komputerów”
    /// with one Mac selected.
    public enum Tool: Sendable {
        case cmcrctl, app
    }

    /// How to rename `machine`, whose new name another Mac renamed in the same run still has – advice that works when
    /// followed (AUDIT REV-54, REV-61): the whole order of `steps(for:holders:)`, one Mac per run, with the list
    /// updated after each – otherwise the list keeps the old address of the Mac renamed before, and the next step is
    /// refused as taken (AUDIT REV-55). cmcrctl names --update-list, and --name for the temporary name and, at the end,
    /// for the new name (the list has the temporary name by then); the app selects one Mac at a time and updates the
    /// list itself when its „Zaktualizuj nazwy i adresy na liście” is on – one order in both (AUDIT REV-63). The app
    /// names the new name of every Mac it renames („zmień nazwę imac03 na imac01”), also in a swap: the sheet is
    /// closed to follow the advice and forgets the names typed in it (AUDIT REV-65); in cmcrctl the names on the list
    /// are the new names.
    ///
    /// `newNames`: the name each Mac gets (default: its name on the list, as in cmcrctl). `rejected`: the Macs of the
    /// same run whose new names are wrong whatever the order (`rejections`) – an order through one of them would stop
    /// at it, or leave a Mac of a swap with the temporary name, so the advice names them instead (AUDIT REV-64).
    /// `stillHeld`: one Mac per name, as in cmcrctl (`steps(for:stillHeld:)`).
    public static func advice(for machine: Machine, stillHeld: [UUID: Machine], newNames: [UUID: String] = [:],
                              rejected: [UUID: Rejection] = [:], in tool: Tool) -> String {
        advice(for: machine, holders: stillHeld.mapValues { [$0] }, newNames: newNames, rejected: rejected, in: tool)
    }

    /// The advice for `machine` when a new name may still be held by several Macs (`holders`, AUDIT REV-69) – the app,
    /// where the name on the list and the name read count too. Where two Macs get temporary names, the second gets
    /// „inną nazwę tymczasową” and each new name says which Mac had the temporary name („(wcześniej imac03)”).
    public static func advice(for machine: Machine, holders: [UUID: [Machine]], newNames: [UUID: String] = [:],
                              rejected: [UUID: Rejection] = [:], in tool: Tool) -> String {
        let (steps, loops) = walk(from: machine, holders: holders)
        var seen: Set<UUID> = []
        let wrong = steps.map(\.machine).filter { rejected[$0.id] != nil && seen.insert($0.id).inserted }
        if !wrong.isEmpty {
            let names = wrong.map { "\($0.name) (\(rejected[$0.id]?.reason ?? ""))" }
            return "Najpierw popraw \(wrong.count == 1 ? "nazwę" : "nazwy") \(andList(names)) – dopiero wtedy da się podać "
                + "kolejność."
        }
        let eachRun = tool == .cmcrctl ? "za każdym razem z --update-list"
            : "zaznaczając za każdym razem tylko jeden komputer, z włączoną aktualizacją listy komputerów"
        let byName = tool == .cmcrctl ? " (--name)" : ""
        // A Mac renamed in a step, in the app with the name typed for it (AUDIT REV-65).
        func renamed(_ m: Machine) -> String {
            guard tool == .app, let new = newNames[m.id] else { return m.name }
            return "\(m.name) na \(new)"
        }
        if loops.isEmpty {
            return (steps.count > 2 ? "Zmień nazwy po kolei" : "Zmień nazwy w dwóch krokach")
                + ", \(eachRun): najpierw " + steps.map { renamed($0.machine) }.joined(separator: ", potem ") + "."
        }
        if tool == .cmcrctl, steps.count == 3, steps[0] == .temporary(machine) {
            // A swap: either Mac can go first. The app gives the steps with the names typed in the sheet, as below.
            return "Przy zamianie nazw nadaj najpierw jednemu z nich nazwę tymczasową\(byName), potem zmień nazwę drugiego, "
                + "a na końcu nadaj pierwszemu docelową nazwę\(byName), \(eachRun)."
        }
        // The Macs of the loops, each once, in the order met.
        var inLoops: [Machine] = []
        for m in loops.joined() where !inLoops.contains(where: { $0.id == m.id }) { inLoops.append(m) }
        let severalTemporary = steps.filter { if case .temporary = $0 { true } else { false } }.count > 1
        var phrases: [String] = []
        var afterRename = false, temporaryGiven = false
        for step in steps {
            switch step {
            case .temporary(let m):
                phrases.append("nadaj \(m.name) \(temporaryGiven ? "inną " : "")nazwę tymczasową\(byName)")
                temporaryGiven = true
            case .rename(let m):
                phrases.append(afterRename ? renamed(m) : "zmień nazwę \(renamed(m))")
            case .target(let m):
                phrases.append("nadaj komputerowi z nazwą tymczasową\(severalTemporary ? " (wcześniej \(m.name))" : "") "
                               + "docelową nazwę \(newNames[m.id] ?? m.name)\(byName)")
            }
            if case .rename = step { afterRename = true } else { afterRename = false }
        }
        return "Komputery \(andList(inLoops.map(\.name))) zamieniają się nazwami"
            + (loops.contains { $0.count > 2 } ? " w kółko" : "") + ". Zmień nazwy po kolei, \(eachRun): najpierw "
            + phrases.dropLast().joined(separator: ", potem ") + ", a na końcu \(phrases[phrases.count - 1])."
    }

    /// „imac01, imac02 i imac03”.
    static func andList(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " i " + items[items.count - 1]
    }

    /// The `.local` names (lowercased) a Mac has now: from its `.local` address, from its name on the list and from the
    /// LocalHostName read from it.
    static func names(of machine: Machine, read: String?) -> Set<String> {
        var names: Set<String> = []
        let address = machine.address.lowercased()
        if address.hasSuffix(".local") { names.insert(String(address.dropLast(".local".count))) }
        let listed = ComputerNames.localHostName(from: machine.name).lowercased()
        if !listed.isEmpty { names.insert(listed) }
        if let read = read?.lowercased(), !read.isEmpty { names.insert(read) }
        return names
    }
}
