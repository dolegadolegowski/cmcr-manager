import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 5, group R5-rename: a name repeated among the renamed Macs is reported before the
/// order of a renumbering or a swap (REV-62), and the advice gives the whole order, also for names that go round
/// (REV-61). The cmcrctl messages are tested end to end in Tests/e2e/suites/rev-r5-rename.sh.
struct RevR5renameTests {
    private func mac(_ name: String, _ address: String) -> Machine {
        Machine(name: name, address: address, user: "admin")
    }

    /// The batch rename of `list` to each Mac's name on the list, as `cmcrctl rename KOMP` plans it.
    private func held(_ list: [Machine]) -> [UUID: Machine] {
        RenamePlan.namesStillHeld(list.map { RenamePlan.Rename(machine: $0, localHostName: ComputerNames.localHostName(from: $0.name)) })
    }

    /// Follows `steps` as a teacher would: one run of `cmcrctl rename KOMP` per step, checked as cmcrctl checks it (the
    /// names the other Macs on the list have), and the list updated after it as --update-list does. The list at the
    /// end, or nil when a step would be refused.
    private func follow(_ steps: [RenamePlan.Step], list: [Machine], newNames: [UUID: String]) -> [Machine]? {
        var list = list
        for step in steps {
            let (machine, name): (Machine, String) = switch step {
            case .temporary(let m): (m, "tymczasowa")
            case .rename(let m), .target(let m): (m, newNames[m.id] ?? "")
            }
            let lhn = ComputerNames.localHostName(from: name)
            guard ComputerNames.isValidLocalHostName(lhn),
                  RenamePlan.namesTaken(by: list, renaming: [machine.id])[lhn.lowercased()] == nil,
                  let i = list.firstIndex(where: { $0.id == machine.id }) else { return nil }
            list[i].name = name
            list[i].address = lhn + ".local"
        }
        return list
    }

    /// AUDIT REV-61: in names moved round three Macs (imac01 → imac02 → imac03 → imac01) the temporary name of the Mac
    /// asked about frees the name of the Mac before it in the loop – the others follow backwards, not in the order the
    /// loop is listed in.
    @Test func aRotationGoesBackwardsAfterTheTemporaryName() {
        let a = mac("imac02", "imac01.local"), b = mac("imac03", "imac02.local"), c = mac("imac01", "imac03.local")
        let stillHeld = held([a, b, c])
        #expect(RenamePlan.steps(for: a, stillHeld: stillHeld) == [.temporary(a), .rename(c), .rename(b), .target(a)])
        #expect(RenamePlan.steps(for: b, stillHeld: stillHeld) == [.temporary(b), .rename(a), .rename(c), .target(b)])
        #expect(RenamePlan.steps(for: c, stillHeld: stillHeld) == [.temporary(c), .rename(b), .rename(a), .target(c)])
        #expect(RenamePlan.advice(for: a, stillHeld: stillHeld)
            == "Komputery imac02, imac03 i imac01 zamieniają się nazwami w kółko. Zmień nazwy po kolei, za każdym razem z "
            + "--update-list: najpierw nadaj imac02 nazwę tymczasową (--name), potem zmień nazwę imac01, potem imac03, a na "
            + "końcu nadaj komputerowi z nazwą tymczasową docelową nazwę imac02 (--name).")
    }

    /// AUDIT REV-61: the order works when followed one step at a time – for every Mac of a rotation of three and of
    /// four, a swap and a renumbering – and every Mac ends with its new name.
    @Test func theWholeOrderWorksWhenFollowed() {
        let lists: [[Machine]] = [
            [mac("imac02", "imac01.local"), mac("imac03", "imac02.local"), mac("imac01", "imac03.local")],
            [mac("imac02", "imac01.local"), mac("imac03", "imac02.local"), mac("imac04", "imac03.local"),
             mac("imac01", "imac04.local")],
            [mac("imac02", "imac01.local"), mac("imac01", "imac02.local")],
            [mac("imac06", "imac05.local"), mac("imac07", "imac06.local"), mac("imac08", "imac07.local"),
             mac("imac10", "imac09.local")],
        ]
        for list in lists {
            let stillHeld = held(list)
            let newNames = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.name) })
            for m in list where stillHeld[m.id] != nil {
                let steps = RenamePlan.steps(for: m, stillHeld: stillHeld)
                let after = follow(steps, list: list, newNames: newNames)
                #expect(after != nil, "\(m.name): \(steps)")
                // Every Mac of the order has its new name and address; the other Macs are untouched.
                let renamed = Set(steps.map { step -> UUID in
                    switch step { case .rename(let x), .temporary(let x), .target(let x): x.id }
                })
                #expect(renamed.contains(m.id))
                for (before, now) in zip(list, after ?? []) {
                    let expected = renamed.contains(before.id) ? before.name + ".local" : before.address
                    #expect(now.name == before.name && now.address == expected, "\(m.name): \(now.name)@\(now.address)")
                }
            }
        }
    }

    /// AUDIT REV-61: a Mac whose name the first Mac of a swap still has, where that Mac takes part in the swap through
    /// another of its names (the LocalHostName read from it, in the app), is renamed after the swap – the advice no
    /// longer speaks only of the two other Macs.
    @Test func aChainIntoALoopIsRenamedAfterTheLoop() {
        let p = mac("imac02", "imac01.local"), q = mac("imac01", "imac02.local"), r = mac("imac05", "imac09.local")
        let stillHeld = RenamePlan.namesStillHeld([RenamePlan.Rename(machine: p, localHostName: "imac02"),
                                                   RenamePlan.Rename(machine: q, localHostName: "imac01"),
                                                   RenamePlan.Rename(machine: r, localHostName: "imac05")],
                                                  currentNames: [p.id: "imac05"])
        #expect(RenamePlan.order(of: r, stillHeld: stillHeld) == .loop([p, q]))
        #expect(RenamePlan.steps(for: r, stillHeld: stillHeld) == [.temporary(p), .rename(q), .target(p), .rename(r)])
        #expect(RenamePlan.advice(for: r, stillHeld: stillHeld)
            == "Komputery imac02 i imac01 zamieniają się nazwami. Zmień nazwy po kolei, za każdym razem z --update-list: "
            + "najpierw nadaj imac02 nazwę tymczasową (--name), potem zmień nazwę imac01, potem nadaj komputerowi z nazwą "
            + "tymczasową docelową nazwę imac02 (--name), a na końcu zmień nazwę imac05.")
    }
    /// AUDIT REV-62: the `.local` names more than one renamed Mac would get – compared without case, as Bonjour does –
    /// are an error for each of those Macs (cmcrctl used to report only the second one, and only when its name was not
    /// still held by another renamed Mac).
    @Test func aNameRepeatedAmongTheRenamedMacsIsFoundForAllOfThem() {
        #expect(RenamePlan.repeatedNames(["imac02", "imac01", "IMAC02", "imac03"]) == ["imac02"])
        #expect(RenamePlan.repeatedNames(["imac05", "imac06", "imac05", "imac05"]) == ["imac05"])
        #expect(RenamePlan.repeatedNames(["imac01", "imac02"]).isEmpty)
        #expect(RenamePlan.repeatedNames([]).isEmpty)
    }
}
