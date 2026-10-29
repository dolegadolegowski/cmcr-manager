import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 7, group R7-rename: the order the app's „Zmień nazwy komputerów” gives for a
/// renumbering or a swap works when followed one Mac at a time (REV-69), also when the name of a renamed Mac on the
/// list is not its `.local` name. cmcrctl gives the same orders as before: there the names on the list are the new
/// names (RevR6renameTests follows them).
struct RevR7renameTests {
    private func mac(_ name: String, _ address: String) -> Machine {
        Machine(name: name, address: address, user: "admin")
    }

    private func renames(_ typed: [(Machine, String)]) -> [RenamePlan.Rename] {
        typed.map { RenamePlan.Rename(machine: $0.0, localHostName: ComputerNames.localHostName(from: $0.1)) }
    }

    private let eachRun = "zaznaczając za każdym razem tylko jeden komputer, z włączoną aktualizacją listy komputerów"

    /// Follows `steps` as a teacher would in the app: the sheet with only the step's Mac selected and its name typed (a
    /// temporary name, or the name typed in the first sheet), checked as the sheet checks it – the names the other Macs
    /// on the list have, from their addresses, their names on the list and the names read from them – and the list
    /// updated after it as „Zaktualizuj nazwy i adresy na liście” does (ClassroomModel.renamed: the typed name, the new
    /// `.local` address, the new name read). The list at the end, or nil when a step would be refused.
    private func followInTheApp(_ steps: [RenamePlan.Step], list: [Machine], read: [UUID: String],
                                newNames: [UUID: String]) -> [Machine]? {
        var list = list, read = read, temporary = 0
        for step in steps {
            let name: String
            switch step {
            case .temporary:
                temporary += 1
                name = "tymczasowa\(temporary)"
            case .rename(let m), .target(let m):
                name = newNames[m.id] ?? ""
            }
            let lhn = ComputerNames.localHostName(from: name)
            guard ComputerNames.isValidLocalHostName(lhn),
                  RenamePlan.namesTaken(by: list, renaming: [step.machine.id], readNames: read)[lhn.lowercased()] == nil,
                  let i = list.firstIndex(where: { $0.id == step.machine.id }) else { return nil }
            list[i].name = name
            if let address = ComputerNames.addressAfterRename(list[i].address, localHostName: lhn) { list[i].address = address }
            read[step.machine.id] = lhn
        }
        return list
    }

    /// AUDIT REV-69: imac03 at imac03.local and „imac02” at imac06.local (a Mac whose entry was renamed earlier), typed
    /// imac03 → imac02 and imac02 → imac03. The advice for imac02 said „najpierw imac03 na imac02, potem imac02 na
    /// imac03”, and the sheet refused that first step: imac02.local is the name of the other Mac on the list. Starting
    /// with the other Mac is refused too, so only a temporary name helps. The name on the list now counts as a name the
    /// Mac still has, as in the check of each step (RenamePlan.namesTaken): the two Macs swap names.
    @Test func aNameOnTheListIsANameTheMacStillHas() {
        let a = mac("imac03", "imac03.local"), b = mac("imac02", "imac06.local")
        let read = [a.id: "imac03", b.id: "imac06"], newNames = [a.id: "imac02", b.id: "imac03"]
        let typed = renames([(a, "imac02"), (b, "imac03")])
        // Both selected: no name is taken by another Mac on the list or wrong.
        let taken = RenamePlan.namesTaken(by: [a, b], renaming: [a.id, b.id], readNames: read)
        #expect(taken.isEmpty)
        let rejected = RenamePlan.rejections(typed, taken: taken)
        #expect(rejected.isEmpty)
        let held = RenamePlan.namesStillHeld(typed, currentNames: read)
        #expect(held[b.id]?.id == a.id)
        #expect(held[a.id]?.id == b.id)
        #expect(RenamePlan.advice(for: b, stillHeld: held, newNames: newNames, rejected: rejected, in: .app)
            == "Komputery imac02 i imac03 zamieniają się nazwami. Zmień nazwy po kolei, \(eachRun): najpierw nadaj imac02 "
            + "nazwę tymczasową, potem zmień nazwę imac03 na imac02, a na końcu nadaj komputerowi z nazwą tymczasową "
            + "docelową nazwę imac03.")
        #expect(RenamePlan.advice(for: a, stillHeld: held, newNames: newNames, rejected: rejected, in: .app)
            == "Komputery imac03 i imac02 zamieniają się nazwami. Zmień nazwy po kolei, \(eachRun): najpierw nadaj imac03 "
            + "nazwę tymczasową, potem zmień nazwę imac02 na imac03, a na końcu nadaj komputerowi z nazwą tymczasową "
            + "docelową nazwę imac02.")
        // Followed, both orders work and both Macs end with their new names and addresses.
        for m in [a, b] {
            let after = followInTheApp(RenamePlan.steps(for: m, stillHeld: held), list: [a, b], read: read, newNames: newNames)
            #expect(after?.map(\.name) == ["imac02", "imac03"], "\(m.name)")
            #expect(after?.map(\.address) == ["imac02.local", "imac03.local"], "\(m.name)")
        }
        // The order given before is refused at its first step, and so is the other one.
        #expect(followInTheApp([.rename(a), .rename(b)], list: [a, b], read: read, newNames: newNames) == nil)
        #expect(followInTheApp([.rename(b), .rename(a)], list: [a, b], read: read, newNames: newNames) == nil)
    }

    /// AUDIT REV-69: a new name that another renamed Mac has only as its name on the list (imac03 → imac02 while
    /// „imac02” at imac06.local becomes imac07) waits for that Mac, as in the check of each step: renamed at once, the
    /// list would keep two Macs named imac02 when the rename of the other one fails. The order works when followed.
    @Test func aNameOnlyOnTheListIsGivenUpFirst() {
        let a = mac("imac03", "imac03.local"), b = mac("imac02", "imac06.local")
        let read = [a.id: "imac03", b.id: "imac06"], newNames = [a.id: "imac02", b.id: "imac07"]
        let held = RenamePlan.namesStillHeld(renames([(a, "imac02"), (b, "imac07")]), currentNames: read)
        #expect(held.count == 1 && held[a.id]?.id == b.id)
        #expect(RenamePlan.advice(for: a, stillHeld: held, newNames: newNames, in: .app)
            == "Zmień nazwy w dwóch krokach, \(eachRun): najpierw imac02 na imac07, potem imac03 na imac02.")
        #expect(followInTheApp(RenamePlan.steps(for: a, stillHeld: held), list: [a, b], read: read, newNames: newNames)?
            .map(\.name) == ["imac02", "imac07"])
        // cmcrctl: the name on the list is the new name, so it is never given up – the same plans as before.
        let six = mac("imac06", "imac05.local"), seven = mac("imac07", "imac06.local")
        let cli = RenamePlan.namesStillHeld(renames([(six, six.name), (seven, seven.name)]))
        #expect(cli.count == 1 && cli[six.id]?.id == seven.id)
    }

    /// AUDIT REV-69: a new name that two other renamed Macs still have – imac02 as the name on the list of „imac02” at
    /// imac06.local and as the address of „imac04” at imac02.local – waits for both. Following only the first of them
    /// („najpierw imac02 na imac07, potem imac05 na imac02”) was refused at the last step: imac04 still had
    /// imac02.local.
    @Test func aNameHeldByTwoRenamedMacsWaitsForBoth() {
        let x = mac("imac05", "imac05.local"), y = mac("imac02", "imac06.local"), z = mac("imac04", "imac02.local")
        let list = [x, y, z]
        let read = [x.id: "imac05", y.id: "imac06", z.id: "imac02"]
        let newNames = [x.id: "imac02", y.id: "imac07", z.id: "imac08"]
        let typed = renames([(x, "imac02"), (y, "imac07"), (z, "imac08")])
        let holders = RenamePlan.holders(typed, currentNames: read)
        #expect(holders.count == 1 && holders[x.id]?.map(\.id) == [y.id, z.id])
        #expect(RenamePlan.namesStillHeld(typed, currentNames: read).mapValues(\.id) == [x.id: y.id])
        let steps = RenamePlan.steps(for: x, holders: holders)
        #expect(steps == [.rename(y), .rename(z), .rename(x)])
        #expect(RenamePlan.advice(for: x, holders: holders, newNames: newNames, in: .app)
            == "Zmień nazwy po kolei, \(eachRun): najpierw imac02 na imac07, potem imac04 na imac08, potem imac05 na imac02.")
        #expect(followInTheApp(steps, list: list, read: read, newNames: newNames)?.map(\.name)
            == ["imac02", "imac07", "imac08"])
        #expect(followInTheApp([.rename(y), .rename(x)], list: list, read: read, newNames: newNames) == nil)
    }

    /// AUDIT REV-69: names that go round in two loops – imac02 and imac03 swap names, and so do imac03 and imac05 –
    /// need two temporary names: the second is „inną nazwę tymczasową”, and each new name says which Mac had the
    /// temporary name. With one loop followed (imac03 waits for imac02 only), imac03's step was refused: imac05 still
    /// had imac02.local.
    @Test func twoLoopsGiveTwoTemporaryNames() {
        let a = mac("imac02", "imac04.local"), b = mac("imac03", "imac01.local"), c = mac("imac05", "imac02.local")
        let list = [a, b, c]
        let read = [a.id: "imac04", b.id: "imac01", c.id: "imac02"]
        let newNames = [a.id: "imac01", b.id: "imac02", c.id: "imac03"]
        let holders = RenamePlan.holders(renames([(a, "imac01"), (b, "imac02"), (c, "imac03")]), currentNames: read)
        #expect(holders[b.id]?.map(\.id) == [a.id, c.id])
        let steps = RenamePlan.steps(for: a, holders: holders)
        #expect(steps == [.temporary(a), .temporary(b), .rename(c), .target(b), .target(a)])
        #expect(RenamePlan.advice(for: a, holders: holders, newNames: newNames, in: .app)
            == "Komputery imac02, imac03 i imac05 zamieniają się nazwami. Zmień nazwy po kolei, \(eachRun): najpierw nadaj "
            + "imac02 nazwę tymczasową, potem nadaj imac03 inną nazwę tymczasową, potem zmień nazwę imac05 na imac03, potem "
            + "nadaj komputerowi z nazwą tymczasową (wcześniej imac03) docelową nazwę imac02, a na końcu nadaj komputerowi z "
            + "nazwą tymczasową (wcześniej imac02) docelową nazwę imac01.")
        #expect(followInTheApp(steps, list: list, read: read, newNames: newNames)?.map(\.name)
            == ["imac01", "imac02", "imac03"])
        #expect(followInTheApp([.temporary(a), .rename(b), .target(a)], list: list, read: read, newNames: newNames) == nil)
    }

    /// Plans drawn the same way on every run (SplitMix64).
    private struct Draw {
        var state: UInt64

        mutating func below(_ n: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(n))
        }

        mutating func distinct(_ count: Int, of pool: [String]) -> [String] {
            var rest = pool, chosen: [String] = []
            for _ in 0..<count { chosen.append(rest.remove(at: below(rest.count))) }
            return chosen
        }
    }

    /// AUDIT REV-69: every order the app's sheet gives works when followed in the sheet, one Mac at a time – otherwise
    /// it names a Mac of the order whose name is wrong. Lists of 2–5 Macs with different names and addresses, some at
    /// IP addresses, some names not read, names on the list that are other Macs' names, and new names typed for some of
    /// them. Before, about two in five of the orders given here were refused at a step, all through the name on the
    /// list of another renamed Mac; with those names but one Mac per name, about one in six.
    @Test func anAppOrderIsGivenOnlyWhenItWorks() {
        let pool = (1...8).map { String(format: "imac%02d", $0) }
        var draw = Draw(state: 69)
        var orders = 0, temporary = 0, twoTemporary = 0, corrections = 0, atOnce = 0
        for _ in 0..<4000 {
            let count = 2 + draw.below(4)
            let real = draw.distinct(count, of: pool), listed = draw.distinct(count, of: pool)
            var list: [Machine] = [], read: [UUID: String] = [:]
            for i in 0..<count {
                let m = mac(listed[i], draw.below(5) == 0 ? "192.0.2.\(10 + i)" : real[i] + ".local")
                list.append(m)
                if draw.below(7) != 0 { read[m.id] = real[i] }
            }
            // Only the Macs that get new names are selected (a Mac whose name does not change is not renamed).
            var newNames: [UUID: String] = [:]
            for m in list where draw.below(10) < 7 {
                let name = pool[draw.below(pool.count)]
                let typed = draw.below(10) == 0 ? name.uppercased() : name
                if typed != read[m.id] { newNames[m.id] = typed }
            }
            let renamed = list.filter { newNames[$0.id] != nil }
            guard renamed.count >= 2 else { continue }
            let typed = renamed.map { RenamePlan.Rename(machine: $0, localHostName: ComputerNames.localHostName(from: newNames[$0.id]!)) }
            let taken = RenamePlan.namesTaken(by: list, renaming: Set(renamed.map(\.id)), readNames: read)
            let rejected = RenamePlan.rejections(typed, taken: taken)
            let held = RenamePlan.namesStillHeld(typed, currentNames: read)
            let holders = RenamePlan.holders(typed, currentNames: read)
            if held.isEmpty && rejected.isEmpty {
                // The sheet renames them all at once: no new name is a name another Mac has now, so the list never has
                // two Macs of one name, also when some of the renames fail.
                atOnce += 1
                for r in typed {
                    for other in list where other.id != r.machine.id {
                        #expect(!RenamePlan.names(of: other, read: read[other.id]).contains(r.localHostName.lowercased()))
                    }
                }
            }
            for m in renamed where held[m.id] != nil && rejected[m.id] == nil {
                let steps = RenamePlan.steps(for: m, holders: holders)
                let advice = RenamePlan.advice(for: m, holders: holders, newNames: newNames, rejected: rejected, in: .app)
                let plan = list.map { "\($0.name)@\($0.address)/\(read[$0.id] ?? "-")→\(newNames[$0.id] ?? "=")" }
                if advice.hasPrefix("Najpierw popraw") {
                    corrections += 1
                    #expect(steps.contains { rejected[$0.machine.id] != nil }, "\(plan) \(m.name): \(advice)")
                    continue
                }
                orders += 1
                let temporaries = steps.filter { if case .temporary = $0 { true } else { false } }.count
                if temporaries > 0 { temporary += 1 }
                if temporaries > 1 { twoTemporary += 1 }
                guard let after = followInTheApp(steps, list: list, read: read, newNames: newNames) else {
                    Issue.record("\(plan) \(m.name): \(advice)")
                    continue
                }
                // Every Mac of the order has its new name, the others keep theirs.
                let inOrder = Set(steps.map(\.machine.id))
                #expect(inOrder.contains(m.id))
                for (before, now) in zip(list, after) {
                    #expect(now.name == (inOrder.contains(before.id) ? newNames[before.id] : before.name), "\(plan) \(m.name)")
                }
            }
        }
        // Orders given (with a temporary name, with two), advice to correct a name first, runs allowed at once.
        #expect(orders == 1382 && temporary == 620 && twoTemporary == 51)
        #expect(corrections == 925 && atOnce == 397)
    }
}
