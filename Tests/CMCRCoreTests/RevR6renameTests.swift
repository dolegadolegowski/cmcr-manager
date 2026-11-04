import Foundation
import Testing
@testable import CMCRCore

/// Review of the audit fixes, round 6, group R6-rename: no order of a renumbering or a swap is given when it runs
/// through a Mac whose new name is wrong whatever the order – repeated, taken or invalid (REV-64), in cmcrctl and in
/// the app's „Zmień nazwy komputerów” alike; the app's advice names the name typed for every Mac it renames (REV-65).
/// The cmcrctl messages are tested end to end in Tests/e2e/suites/rev-r6-rename.sh.
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

    private let eachRun = "zaznaczając za każdym razem tylko jeden komputer, z włączoną aktualizacją listy komputerów"

    private func renames(_ typed: [(Machine, String)]) -> [RenamePlan.Rename] {
        typed.map { RenamePlan.Rename(machine: $0.0, localHostName: ComputerNames.localHostName(from: $0.1)) }
    }

    /// AUDIT REV-65: the app's advice names the name typed for every Mac it renames, not only for the Mac with the
    /// temporary name: the sheet is closed to follow it (its button stays off while a new address is still held), it
    /// forgets the typed names then and opens again with the names on the list – „zmień nazwę imac03” alone did not
    /// say imac03 was to become imac01. cmcrctl keeps the names on the list, which are the new names there.
    @Test func theAppNamesTheNewNameOfEveryStep() {
        let five = mac("imac05", "imac05.local"), six = mac("imac06", "imac06.local"), seven = mac("imac07", "imac07.local")
        let renumbering = renames([(five, "imac06"), (six, "imac07"), (seven, "imac08")])
        let renumbered = Dictionary(uniqueKeysWithValues: renumbering.map { ($0.machine.id, $0.localHostName) })
        let held = RenamePlan.namesStillHeld(renumbering)
        #expect(RenamePlan.advice(for: five, stillHeld: held, newNames: renumbered, in: .app)
            == "Zmień nazwy po kolei, \(eachRun): najpierw imac07 na imac08, potem imac06 na imac07, potem imac05 na imac06.")
        #expect(RenamePlan.advice(for: six, stillHeld: held, newNames: renumbered, in: .app)
            == "Zmień nazwy w dwóch krokach, \(eachRun): najpierw imac07 na imac08, potem imac06 na imac07.")
        #expect(RenamePlan.advice(for: five, stillHeld: held, in: .cmcrctl)
            == "Zmień nazwy po kolei, za każdym razem z --update-list: najpierw imac07, potem imac06, potem imac05.")

        let a = mac("imac01", "imac01.local"), b = mac("imac02", "imac02.local"), c = mac("imac03", "imac03.local")
        let rotation = RenamePlan.namesStillHeld(renames([(a, "imac02"), (b, "imac03"), (c, "imac01")]))
        #expect(RenamePlan.advice(for: a, stillHeld: rotation, newNames: [a.id: "imac02", b.id: "imac03", c.id: "imac01"],
                                  in: .app)
            == "Komputery imac01, imac02 i imac03 zamieniają się nazwami w kółko. Zmień nazwy po kolei, \(eachRun): "
            + "najpierw nadaj imac01 nazwę tymczasową, potem zmień nazwę imac03 na imac01, potem imac02 na imac03, a na "
            + "końcu nadaj komputerowi z nazwą tymczasową docelową nazwę imac02.")
        // A swap: the names as typed – not only „zmień nazwę drugiego” and „docelową nazwę”.
        let swap = RenamePlan.namesStillHeld(renames([(a, "iMac02"), (b, "iMac01")]))
        #expect(RenamePlan.advice(for: a, stillHeld: swap, newNames: [a.id: "iMac02", b.id: "iMac01"], in: .app)
            == "Komputery imac01 i imac02 zamieniają się nazwami. Zmień nazwy po kolei, \(eachRun): najpierw nadaj imac01 "
            + "nazwę tymczasową, potem zmień nazwę imac02 na iMac01, a na końcu nadaj komputerowi z nazwą tymczasową "
            + "docelową nazwę iMac02.")
    }

    /// AUDIT REV-65: in the app's advice every Mac of the order comes with the name typed for it, in the order of the
    /// steps – for a renumbering, a swap, loops of three and four, and a chain into a loop.
    @Test func theAppAdviceCarriesEveryTypedName() {
        let m = (1...6).map { mac(String(format: "imac%02d", $0), String(format: "imac%02d.local", $0)) }
        let plans: [([(Machine, String)], [UUID: String])] = [
            ([(m[0], "Pracownia 2"), (m[1], "Pracownia 3"), (m[2], "Pracownia 4")],
             [m[1].id: "Pracownia-2", m[2].id: "Pracownia-3"]),
            ([(m[0], "imac02"), (m[1], "imac01")], [:]),
            ([(m[0], "imac02"), (m[1], "imac03"), (m[2], "imac01")], [:]),
            ([(m[0], "imac02"), (m[1], "imac03"), (m[2], "imac04"), (m[3], "IMAC01")], [:]),
            // imac05 → „Imac 01” (Imac-01.local), which imac02 of the swap still has as the name read from it.
            ([(m[0], "imac02"), (m[1], "imac01"), (m[4], "Imac 01")], [m[1].id: "Imac-01"]),
        ]
        var checked = 0
        for (typed, read) in plans {
            let newNames = Dictionary(uniqueKeysWithValues: typed.map { ($0.0.id, $0.1) })
            let held = RenamePlan.namesStillHeld(renames(typed), currentNames: read)
            for (machine, _) in typed where held[machine.id] != nil {
                let advice = RenamePlan.advice(for: machine, stillHeld: held, newNames: newNames, in: .app)
                var rest = advice[...]
                for step in RenamePlan.steps(for: machine, stillHeld: held) {
                    let needle = switch step {
                    case .temporary(let x): "nadaj \(x.name) nazwę tymczasową"
                    case .rename(let x): "\(x.name) na \(newNames[x.id] ?? "?")"
                    case .target(let x): "docelową nazwę \(newNames[x.id] ?? "?")"
                    }
                    guard let found = rest.range(of: needle) else {
                        Issue.record("\(machine.name): brak „\(needle)” w „\(advice)”")
                        break
                    }
                    rest = rest[found.upperBound...]
                }
                checked += 1
            }
        }
        #expect(checked == 14)
    }
}
