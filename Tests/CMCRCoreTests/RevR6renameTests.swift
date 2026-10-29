import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 6, group R6-rename: no order of a renumbering or a swap is given when it runs
/// through a Mac whose new name is wrong whatever the order – repeated, taken or invalid (REV-64), in cmcrctl and in
/// the app's „Zmień nazwy komputerów” alike. The cmcrctl messages are tested end to end in
/// Tests/e2e/suites/rev-r6-rename.sh.
struct RevR6renameTests {
    private func mac(_ name: String, _ address: String) -> Machine {
        Machine(name: name, address: address, user: "admin")
    }

    /// What `cmcrctl rename KOMP` checks of `run` – each Mac renamed to its name on the list – before any order: the
    /// Macs whose new names another renamed Mac still has, and the Macs whose new names are wrong whatever the order.
    private func plan(_ run: [Machine], list: [Machine]) -> (stillHeld: [UUID: Machine], rejected: [UUID: RenamePlan.Rejection]) {
        let renames = run.map { RenamePlan.Rename(machine: $0, localHostName: ComputerNames.localHostName(from: $0.name)) }
        return (RenamePlan.namesStillHeld(renames),
                RenamePlan.rejections(renames, taken: RenamePlan.namesTaken(by: list, renaming: Set(run.map(\.id)))))
    }

    /// Follows `steps` as a teacher would: one run of `cmcrctl rename KOMP` per step, checked as cmcrctl checks it (the
    /// names the other Macs on the list have), and the list updated after it as --update-list does. Nil when a step
    /// would be refused.
    private func follow(_ steps: [RenamePlan.Step], list: [Machine]) -> [Machine]? {
        var list = list
        for step in steps {
            let (machine, name): (Machine, String) = switch step {
            case .temporary(let m): (m, "tymczasowa")
            case .rename(let m), .target(let m): (m, m.name)
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

    private let noOrder = " – dopiero wtedy da się podać kolejność."

    /// AUDIT REV-64: the swap of imac01 and imac02 runs through imac02, whose name repeats (imąc02 → imac02.local).
    /// imac01 used to get the swap advice; followed, it left one of the two Macs with the temporary name (its last
    /// step was refused as taken by imąc02). Now it is told to correct imac02 first, in cmcrctl and in the app.
    @Test func aSwapThroughARepeatedNameGetsNoOrder() {
        let a = mac("imac02", "imac01.local"), b = mac("imac01", "imac02.local"), c = mac("imąc02", "imac03.local")
        let (stillHeld, rejected) = plan([a, b, c], list: [a, b, c])
        #expect(rejected == [a.id: .repeated, c.id: .repeated])
        #expect(stillHeld[b.id]?.id == a.id)
        #expect(follow(RenamePlan.steps(for: b, stillHeld: stillHeld), list: [a, b, c]) == nil)
        for tool in [RenamePlan.Tool.cmcrctl, .app] {
            #expect(RenamePlan.advice(for: b, stillHeld: stillHeld, rejected: rejected, in: tool)
                == "Najpierw popraw nazwę imac02 (adres powtarza się)" + noOrder)
        }
    }

    /// AUDIT REV-64: a renumbering whose free end repeats (imac07 and IMAC07) or is taken by a Mac not renamed here
    /// (imac08 at imac07.local): „najpierw imac07, potem imac06” was refused at its first step.
    @Test func aRenumberingThroughAWrongNameGetsNoOrder() {
        let six = mac("imac06", "imac05.local"), seven = mac("imac07", "imac06.local")
        let repeated = mac("IMAC07", "imac09.local"), eight = mac("imac08", "imac07.local")
        var (stillHeld, rejected) = plan([six, seven, repeated], list: [six, seven, repeated])
        #expect(rejected == [seven.id: .repeated, repeated.id: .repeated])
        #expect(RenamePlan.advice(for: six, stillHeld: stillHeld, rejected: rejected, in: .cmcrctl)
            == "Najpierw popraw nazwę imac07 (adres powtarza się)" + noOrder)
        (stillHeld, rejected) = plan([six, seven], list: [six, seven, eight])
        #expect(rejected == [seven.id: .taken(by: "imac08")])
        #expect(RenamePlan.advice(for: six, stillHeld: stillHeld, rejected: rejected, in: .cmcrctl)
            == "Najpierw popraw nazwę imac07 (adres ma już imac08)" + noOrder)
    }

    /// AUDIT REV-64: names in a loop of three, two of them wrong – both are named, in the order of the steps; an
    /// invalid name in the app's sheet (a name typed there that gives no LocalHostName) counts the same.
    @Test func everyWrongNameOfTheOrderIsNamed() {
        let a = mac("imac02", "imac01.local"), b = mac("imac03", "imac02.local"), c = mac("imac01", "imac03.local")
        let d = mac("IMAC03", "imac04.local"), e = mac("IMAC01", "imac09.local")
        let (stillHeld, rejected) = plan([a, b, c, d], list: [a, b, c, d, e])
        #expect(rejected == [b.id: .repeated, c.id: .taken(by: "IMAC01"), d.id: .repeated])
        #expect(RenamePlan.advice(for: a, stillHeld: stillHeld, rejected: rejected, in: .cmcrctl)
            == "Najpierw popraw nazwy imac01 (adres ma już IMAC01) i imac03 (adres powtarza się)" + noOrder)
        // The app: imac03 → „imac04”, imac04 → „!!!” (no LocalHostName); imac04 still has imac04.local.
        let three = mac("imac03", "imac03.local"), four = mac("imac04", "imac04.local")
        let typed = [RenamePlan.Rename(machine: three, localHostName: "imac04"),
                     RenamePlan.Rename(machine: four, localHostName: ComputerNames.localHostName(from: "!!!"))]
        let held = RenamePlan.namesStillHeld(typed)
        let wrong = RenamePlan.rejections(typed, taken: [:])
        #expect(wrong == [four.id: .invalid])
        #expect(RenamePlan.advice(for: three, stillHeld: held, newNames: [three.id: "imac04", four.id: "!!!"],
                                  rejected: wrong, in: .app)
            == "Najpierw popraw nazwę imac04 (niepoprawna nazwa)" + noOrder)
    }

    /// AUDIT REV-64: a wrong name outside the order does not hide it, and every order given works when followed –
    /// otherwise it names a Mac of the order whose name is wrong.
    @Test func anOrderIsGivenOnlyWhenItWorks() {
        let lists: [[Machine]] = [
            [mac("imac02", "imac01.local"), mac("imac01", "imac02.local"), mac("imąc02", "imac03.local")],
            [mac("imac02", "imac01.local"), mac("imac01", "imac02.local"), mac("imac05", "imac03.local"),
             mac("IMAC05", "imac04.local")],
            [mac("imac06", "imac05.local"), mac("imac07", "imac06.local"), mac("IMAC07", "imac09.local")],
            [mac("imac02", "imac01.local"), mac("imac03", "imac02.local"), mac("imac01", "imac03.local"),
             mac("IMAC03", "imac04.local")],
            [mac("imac02", "imac01.local"), mac("imac03", "imac02.local"), mac("imac04", "imac03.local"),
             mac("imac01", "imac04.local"), mac("imac10", "imac09.local"), mac("IMAC10", "imac11.local")],
        ]
        var orders = 0
        for list in lists {
            let (stillHeld, rejected) = plan(list, list: list)
            for m in list where stillHeld[m.id] != nil && rejected[m.id] == nil {
                let steps = RenamePlan.steps(for: m, stillHeld: stillHeld)
                let advice = RenamePlan.advice(for: m, stillHeld: stillHeld, rejected: rejected, in: .cmcrctl)
                if advice.hasPrefix("Najpierw popraw") {
                    #expect(steps.contains { rejected[$0.machine.id] != nil }, "\(m.name): \(advice)")
                } else {
                    orders += 1
                    #expect(follow(steps, list: list) != nil, "\(m.name): \(advice)")
                }
            }
        }
        // The swap next to a repeated name and the loop of four next to one.
        #expect(orders == 6)
    }
}
