import CMCRCore
import Foundation

/// `cmcrctl` commands for lesson routines, attention mode, energy schedule, names and reports.
enum ClassroomCLI {
    static let commands: Set<String> = ["lesson", "lock", "unlock", "ask", "schedule", "rename", "power-later",
                                        "power-cancel", "app-version", "filevault", "report"]

    static let usage = """
    Zajęcia, zasilanie i raporty:
      cmcrctl lesson start|end [all|nr] [--no-wait]   scenariusz zajęć zapisany w aplikacji (classroom.json)
      cmcrctl lock [all|nr] [--message "…"] [--mode automatic|lockScreen|overlay] [--minutes N]
      cmcrctl unlock [all|nr]                         zdejmij blokadę ekranu
      cmcrctl ask "pytanie" [all|nr] [--buttons "Tak,Nie"] [--timeout sekundy]
      cmcrctl schedule show|set|clear [all|nr] [--on MTWRF@07:45] [--off MTWRF@16:30]
                       [--on-type wakeorpoweron|wake] [--off-type sleep|shutdown] [--no-autorestart] [--no-womp]
      cmcrctl rename [all|nr] [--name "Nazwa"] [--dry-run] [--update-list]
                                                      nazwy z listy; --name tylko dla jednego komputera
      cmcrctl power-later restart|shutdown|sleep MINUTY [all|nr] [--warn "komunikat"]
      cmcrctl power-cancel [all|nr]                   anuluj zaplanowane wyłączenie/restart/uśpienie
      cmcrctl app-version "Nazwa" [all|nr]            wersja aplikacji na komputerach
      cmcrctl filevault [all|nr]                      czy FileVault jest włączony
      cmcrctl report [plik.csv]                       raport CSV o komputerach
    """

    static let printer: Operations.Output = { channel, data in
        (channel == .stdout ? FileHandle.standardOutput : FileHandle.standardError).write(data)
    }

    static let valueOptions: Set<String> = ["--message", "--mode", "--minutes", "--buttons", "--timeout", "--on", "--off",
                                            "--on-type", "--off-type", "--name", "--warn"]

    /// Splits arguments into positionals and `--option value` / `--flag` pairs.
    static func parse(_ args: [String]) -> (positional: [String], options: [String: String]) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if valueOptions.contains(a), i + 1 < args.count {
                options[a] = args[i + 1]
                i += 2
            } else if a.hasPrefix("--") {
                options[a] = ""
                i += 1
            } else {
                positional.append(a)
                i += 1
            }
        }
        return (positional, options)
    }

    static func error(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }

    static func report(_ r: CommandResult) -> Int32 {
        if !r.succeeded {
            FileHandle.standardError.write(Data("✘ \(SSH.diagnose(r).1)\n".utf8))
        }
        return r.succeeded ? 0 : (r.exitCode == 0 ? 1 : r.exitCode)
    }

    /// Runs `script(host)` on every host in order, streaming output.
    static func each(_ hosts: [Machine], ssh: SSHSettings, timeout: TimeInterval? = nil,
                     _ script: (Machine) -> RemoteScript) async -> Int32 {
        var status: Int32 = 0
        for h in hosts {
            print("\(h.name):")
            let r = await SSH.run(script(h), on: h, password: Keychain.password(for: h), settings: ssh, timeout: timeout,
                                  onOutput: printer)
            status = max(status, report(r))
        }
        return status
    }

    static func run(_ command: String, _ rawArgs: [String], select: (String?) -> [Machine],
                    settings: AppSettings, ssh: SSHSettings) async -> Int32 {
        let (pos, opt) = parse(rawArgs)
        switch command {
        case "lesson":
            guard let kind = pos.first, kind == "start" || kind == "end" else { return error(usage) }
            return await lesson(start: kind == "start", hosts: select(pos.count > 1 ? pos[1] : nil),
                                wait: opt["--no-wait"] == nil, settings: settings, ssh: ssh)

        case "lock":
            let config = ClassroomStore.loadConfig()
            let message = opt["--message"] ?? config.lockMessage
            let mode = opt["--mode"].flatMap(AttentionMode.init(rawValue:)) ?? config.lockMode
            let minutes = opt["--minutes"].flatMap(Int.init) ?? config.autoUnlockMinutes
            return await each(select(pos.first), ssh: ssh, timeout: 60) { _ in
                Scripts.lockScreen(message: message, mode: mode, autoUnlockMinutes: minutes)
            }

        case "unlock":
            return await each(select(pos.first), ssh: ssh, timeout: 60) { _ in Scripts.unlockScreen() }

        case "ask":
            guard let question = pos.first else { return error("Podaj treść pytania.") }
            let buttons = (opt["--buttons"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard buttons.count <= ClassroomConfig.maxQuestionButtons else {
                return error("Okno pytania mieści najwyżej \(ClassroomConfig.maxQuestionButtons) przyciski.")
            }
            let seconds = opt["--timeout"].flatMap(Int.init) ?? 120
            let script = Scripts.ask(title: "Pytanie od nauczyciela", prompt: question, buttons: buttons,
                                     timeoutSeconds: seconds)
            // All Macs at once: every dialog waits for its student. Answers are printed as they arrive.
            var status: Int32 = 0
            await withTaskGroup(of: (Machine, CommandResult).self) { group in
                for h in select(pos.count > 1 ? pos[1] : nil) {
                    let pw = Keychain.password(for: h)
                    group.addTask {
                        (h, await SSH.run(script, on: h, password: pw, settings: ssh, timeout: TimeInterval(seconds + 60)))
                    }
                }
                for await (h, r) in group {
                    if let answer = StudentAnswer.parse(r.stdoutText) {
                        let who = answer.user.isEmpty ? "" : " (\(answer.user))"
                        print("\(h.name)\(who): \(answer.displayText)")
                    } else {
                        print("\(h.name): —")
                        status = max(status, report(r))
                    }
                }
            }
            return status

        case "schedule":
            guard let action = pos.first, ["show", "set", "clear"].contains(action) else { return error(usage) }
            let hosts = select(pos.count > 1 ? pos[1] : nil)
            switch action {
            case "set":
                var s = EnergySchedule()
                if let on = opt["--on"] {
                    guard let parsed = parseEvent(on) else { return error("Niepoprawne --on (np. MTWRF@07:45).") }
                    (s.onDays, s.onTime) = parsed
                } else if opt["--off"] != nil {
                    s.powerOnEnabled = false
                }
                if let off = opt["--off"] {
                    guard let parsed = parseEvent(off) else { return error("Niepoprawne --off (np. MTWRF@16:30).") }
                    (s.offDays, s.offTime) = parsed
                } else if opt["--on"] != nil {
                    s.powerOffEnabled = false
                }
                if let t = opt["--on-type"] {
                    guard let v = EnergySchedule.OnType(rawValue: t) else { return error("--on-type: wakeorpoweron lub wake") }
                    s.onType = v
                }
                if let t = opt["--off-type"] {
                    guard let v = EnergySchedule.OffType(rawValue: t) else { return error("--off-type: sleep lub shutdown") }
                    s.offType = v
                }
                if let e = s.validationError { return error(e) }
                return await each(hosts, ssh: ssh, timeout: 60) { _ in
                    Scripts.applyEnergySchedule(s, autoRestart: opt["--no-autorestart"] == nil, wakeOnLAN: opt["--no-womp"] == nil)
                }
            case "clear":
                return await each(hosts, ssh: ssh, timeout: 60) { _ in Scripts.cancelEnergySchedule() }
            default:
                var status: Int32 = 0
                for h in hosts {
                    let r = await SSH.run(Scripts.energyScheduleStatus(), on: h, password: Keychain.password(for: h),
                                          settings: ssh, timeout: 30)
                    guard r.succeeded else { print("\(h.name): —"); status = max(status, report(r)); continue }
                    let events = PowerScheduleParser.repeating(r.stdoutText)
                    let policy = PowerScheduleParser.policy(r.stdoutText)
                    print("\(h.name): \(events.isEmpty ? "brak harmonogramu" : events.map(\.text).joined(separator: "; "))"
                          + " | po zaniku zasilania: \(policy["autorestart"] == "1" ? "tak" : "nie")"
                          + " | Wake-on-LAN: \(policy["womp"] == "1" ? "tak" : "nie")")
                }
                return status
            }

        case "rename":
            let targets = select(pos.first)
            if opt["--name"] != nil && targets.count > 1 {
                return error("--name można podać tylko dla jednego komputera (wszystkie dostałyby tę samą nazwę). Bez --name każdy komputer dostaje nazwę z listy.")
            }
            var hosts = ConfigStore.loadHosts()
            var status: Int32 = 0
            for h in targets {
                let name = opt["--name"] ?? h.name
                let lhn = ComputerNames.localHostName(from: name)
                guard ComputerNames.isValidLocalHostName(lhn) else {
                    status = max(status, error("\(h.name): niepoprawna nazwa „\(name)”."))
                    continue
                }
                print("\(h.name): „\(name)” → \(lhn).local")
                if opt["--dry-run"] != nil { continue }
                let r = await SSH.run(Scripts.renameComputer(computerName: name, localHostName: lhn), on: h,
                                      password: Keychain.password(for: h), settings: ssh, timeout: 60, onOutput: printer)
                status = max(status, report(r))
                if r.succeeded, opt["--update-list"] != nil, let i = hosts.firstIndex(where: { $0.id == h.id }) {
                    hosts[i].name = name
                    if let address = ComputerNames.addressAfterRename(hosts[i].address, localHostName: lhn) {
                        hosts[i].address = address
                    }
                    ConfigStore.saveHosts(hosts)
                    print("Zaktualizowano listę komputerów: \(hosts[i].name) → \(hosts[i].address)")
                }
            }
            return status

        case "power-later":
            guard pos.count >= 2, let minutes = Int(pos[1]), minutes >= 0 else { return error(usage) }
            let action: PowerAction
            switch pos[0] {
            case "restart": action = .restart
            case "shutdown": action = .shutdown
            case "sleep": action = .sleep
            default: return error("Akcja: restart, shutdown lub sleep.")
            }
            let warning = opt["--warn"]
            return await each(select(pos.count > 2 ? pos[2] : nil), ssh: ssh, timeout: 60) { _ in
                Scripts.delayedPower(action, minutes: minutes, warning: warning)
            }

        case "power-cancel":
            return await each(select(pos.first), ssh: ssh, timeout: 60) { _ in Scripts.cancelDelayedPower() }

        case "app-version":
            guard let name = pos.first else { return error("Podaj nazwę aplikacji.") }
            var status: Int32 = 0
            for h in select(pos.count > 1 ? pos[1] : nil) {
                let r = await SSH.run(Scripts.appVersion(name), on: h, password: Keychain.password(for: h), settings: ssh,
                                      timeout: 60)
                guard r.succeeded else { print("\(h.name): —"); status = max(status, report(r)); continue }
                let found = AppVersionInfo.parse(r.stdoutText)
                if found.isEmpty {
                    print("\(h.name): brak")
                } else {
                    for a in found { print("\(h.name): \(a.version.isEmpty ? "?" : a.version) (\(a.build)) \(a.path)") }
                }
            }
            return status

        case "filevault":
            var status: Int32 = 0
            for h in select(pos.first) {
                let r = await SSH.run(Scripts.fileVaultStatus(), on: h, password: Keychain.password(for: h), settings: ssh,
                                      timeout: 30)
                guard r.succeeded else { print("\(h.name): —"); status = max(status, report(r)); continue }
                let kv = Parsers.keyValues(r.stdoutText)
                print("\(h.name): FileVault \(kv["fv"] == "on" ? "włączony" : "wyłączony")"
                      + (kv["fv"] == "on" ? (kv["authrestart"] == "yes" ? " (obsługuje authrestart)" : " (brak authrestart)") : ""))
            }
            return status

        case "report":
            return await inventoryReport(to: pos.first, hosts: ConfigStore.loadHosts(), ssh: ssh)

        default:
            return error(usage)
        }
    }

    /// `MTWRF@07:45` → days and time.
    static func parseEvent(_ s: String) -> (Set<Weekday>, ClockTime)? {
        let parts = s.split(separator: "@")
        guard parts.count == 2, let time = ClockTime.parse(String(parts[1])) else { return nil }
        let days = Set(parts[0].uppercased().compactMap { Weekday(rawValue: String($0)) })
        guard !days.isEmpty, days.count == Set(parts[0].uppercased()).count else { return nil }
        return (days, time)
    }

    static func lesson(start: Bool, hosts: [Machine], wait: Bool, settings: AppSettings, ssh: SSHSettings) async -> Int32 {
        let config = ClassroomStore.loadConfig()
        let plan = start ? LessonPlan.start(config.start, settings: settings) : LessonPlan.end(config.end, settings: settings)
        guard !plan.steps.isEmpty else { return error("Scenariusz nie ma żadnych kroków (ustaw je w aplikacji: Zajęcia).") }
        print("\(plan.kind.title): \(plan.steps.map(\.title).joined(separator: " → "))")
        if let folder = plan.collectFolder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            print("Zebrane prace: \(folder.path)")
        }
        var payload: URL?
        if plan.steps.contains(.materials) {
            let dir = URL(fileURLWithPath: expandTilde(config.start.materialsFolder), isDirectory: true)
            let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent != ".DS_Store" }
            if !items.isEmpty, case .success(let url) = await Payload.make(items) { payload = url }
        }
        defer { if let payload { try? FileManager.default.removeItem(at: payload) } }

        func host(_ h: Machine) -> LessonRunner.Host {
            LessonRunner.Host(machine: h, password: Keychain.password(for: h), macs: h.macAddress.isEmpty ? [] : [h.macAddress])
        }
        var status: Int32 = 0
        var first = 0
        if plan.steps.first == .warn {
            for h in hosts {
                print("== \(h.name)")
                _ = await LessonRunner.run(plan, on: host(h), ssh: ssh, materials: nil, range: 0..<1, onOutput: printer)
            }
            if wait {
                let secs = max(1, plan.end.warnMinutes) * 60
                print("Czekam \(secs / 60) min przed kolejnymi krokami…")
                try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            }
            first = 1
        }
        guard first < plan.steps.count else { return 0 }
        for h in hosts {
            print("== \(h.name)")
            let r = await LessonRunner.run(plan, on: host(h), ssh: ssh, materials: payload, range: first..<plan.steps.count,
                                           onOutput: printer)
            if !r.succeeded {
                FileHandle.standardError.write(r.stderr)
                status = 1
            }
        }
        return status
    }

    static func inventoryReport(to path: String?, hosts: [Machine], ssh: SSHSettings) async -> Int32 {
        let snapshots = ClassroomStore.loadSnapshots()
        var statuses: [UUID: HostStatus] = [:]
        await withTaskGroup(of: (UUID, HostStatus).self) { group in
            for h in hosts {
                let pw = Keychain.password(for: h)
                group.addTask {
                    let r = await SSH.run(Scripts.status(), on: h, password: pw, settings: ssh, timeout: 30)
                    var st = snapshots[h.id]?.restored ?? HostStatus()
                    st.updatedAt = Date()
                    if r.succeeded {
                        st.reachability = .online
                        st.info = Parsers.keyValues(r.stdoutText)
                    } else {
                        let (reach, message) = SSH.diagnose(r)
                        st.reachability = reach == .online ? .error : reach
                        st.message = message
                    }
                    return (h.id, st)
                }
            }
            for await (id, st) in group { statuses[id] = st }
        }
        let rows = InventoryReport.rows(machines: hosts, status: { statuses[$0.id] ?? HostStatus() },
                                        lastSeen: { statuses[$0.id]?.reachability == .online ? Date() : snapshots[$0.id]?.lastSeen })
        if let path {
            let url = URL(fileURLWithPath: expandTilde(path))
            do {
                try CSV.render(rows).write(to: url, atomically: true, encoding: .utf8)
                print("Zapisano raport: \(url.path) (\(hosts.count) \(Plural.computers(hosts.count)))")
            } catch {
                return self.error("Nie można zapisać \(url.path): \(error.localizedDescription)")
            }
        } else {
            print(CSV.render(rows, bom: false), terminator: "")
        }
        return statuses.values.contains { $0.reachability != .online } ? 1 : 0
    }
}
