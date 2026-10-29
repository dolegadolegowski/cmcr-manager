import CMCRCore
import Foundation

/// `cmcrctl` commands for lesson routines, attention mode, energy schedule, names and reports.
enum ClassroomCLI {
    static let usage = """
    Zajęcia, zasilanie i raporty
      cmcrctl lesson start|end KOMP [--no-wait] [--yes]   scenariusz zajęć zapisany w aplikacji (classroom.json);
                                                      komputery obsługiwane naraz, jak w aplikacji
      cmcrctl lock KOMP [--message "…"] [--mode automatic|lockScreen|overlay] [--minutes N]
      cmcrctl unlock KOMP                             zdejmij blokadę ekranu
      cmcrctl ask "pytanie" KOMP [--buttons "Tak,Nie"] [--timeout sekundy]
                                                      bez --timeout: czas na odpowiedź zapisany w aplikacji
      cmcrctl schedule show [KOMP]                    harmonogram zasilania (bez KOMP: wszystkie)
      cmcrctl schedule set|clear KOMP [--on MTWRF@07:45] [--off MTWRF@16:30]
                       [--on-type wakeorpoweron|wake] [--off-type sleep|shutdown] [--no-autorestart] [--no-womp]
                                                      bez --on/--off: harmonogram i zasady zapisane w aplikacji
                                                      (classroom.json); --on/--off: tylko podane zdarzenia
      cmcrctl rename KOMP [--name "Nazwa"] [--dry-run] [--update-list] [--yes]
                                                      nazwy z listy; --name tylko dla jednego komputera
      cmcrctl rename-computer KOMP [--name "Nazwa"] [--dry-run] [--update-list] [--yes]
                                                      jak rename KOMP: zmiana nazw komputerów
      cmcrctl power-later restart|shutdown|sleep MINUTY KOMP [--warn "komunikat"] [--yes]
      cmcrctl power-cancel KOMP                       anuluj zaplanowane wyłączenie/restart/uśpienie
      cmcrctl app-version "Nazwa" [KOMP]              wersja aplikacji na komputerach
      cmcrctl filevault [KOMP]                        czy FileVault jest włączony
      cmcrctl report [plik.csv]                       raport CSV o komputerach
    """

    static let specs: [String: ModuleSpec] = [
        "lesson": ModuleSpec(flags: ["--no-wait"], maxPositional: 2),
        "lock": ModuleSpec(values: ["--message", "--mode", "--minutes"], maxPositional: 1, parallel: true),
        "unlock": ModuleSpec(maxPositional: 1, parallel: true),
        // All Macs at once: every dialog waits for its student.
        "ask": ModuleSpec(values: ["--buttons", "--timeout"], maxPositional: 2),
        "schedule": ModuleSpec(flags: ["--no-autorestart", "--no-womp"], values: ["--on", "--off", "--on-type", "--off-type"],
                               maxPositional: 2, parallel: true),
        "rename": ModuleSpec(flags: ["--dry-run", "--update-list"], values: ["--name"], maxPositional: 1),
        "rename-computer": ModuleSpec(flags: ["--dry-run", "--update-list"], values: ["--name"], maxPositional: 1),
        "power-later": ModuleSpec(values: ["--warn"], maxPositional: 3, parallel: true),
        "power-cancel": ModuleSpec(maxPositional: 1, parallel: true),
        "app-version": ModuleSpec(maxPositional: 2, parallel: true),
        "filevault": ModuleSpec(maxPositional: 1, parallel: true),
        "report": ModuleSpec(maxPositional: 1),
    ]

    /// classroom.json as saved in the app (lesson scenarios, energy schedule, attention mode, question timeout). A
    /// damaged file, whose values fall back to the defaults – e.g. the built-in schedule for `schedule set` – is
    /// reported before the command runs, like settings.json in main.swift (AUDIT REV-37). Only the commands that use
    /// the file read it: the others neither warn about it nor make a backup copy of it.
    static func loadConfig() -> ClassroomConfig {
        let config = ClassroomStore.loadConfig()
        if let issue = ClassroomStore.loadIssue { Console.err("⚠ \(issue)") }
        return config
    }

    /// Runs a classroom command (`rawArgs` without the command word).
    static func run(_ command: String, _ rawArgs: [String], settings: AppSettings, ssh: SSHSettings) async -> Int32 {
        let a = ModuleArguments.parse(command, rawArgs, specs[command] ?? ModuleSpec())
        func use(_ text: String) -> Never { moduleUsageError(command, text) }

        switch command {
        case "lesson":
            guard let kind = a[0], kind == "start" || kind == "end" else {
                use("Użycie: cmcrctl lesson start|end KOMP [--no-wait]")
            }
            // Read before the hosts: a damaged file is reported before „Wykonać na wszystkich?” (AUDIT REV-46), as
            // in lock, ask and schedule set.
            let config = loadConfig()
            return await lesson(start: kind == "start", config: config, hosts: ModuleHosts.changing(a[1], "lesson \(kind)"),
                                wait: !a.has("--no-wait"), yes: a.yes, settings: settings, ssh: ssh)

        case "lock":
            let config = loadConfig()
            let message = a.value("--message") ?? config.lockMessage
            let mode: AttentionMode
            if let raw = a.value("--mode") {
                guard let m = AttentionMode.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) else {
                    use("--mode: automatic, lockScreen lub overlay (podano „\(raw)”).")
                }
                mode = m
            } else {
                mode = config.lockMode
            }
            let minutes = a.int("--minutes", in: 0...240) ?? config.autoUnlockMinutes
            let list = ModuleHosts.changing(a[0], command)
            return await runEach(list, a, ssh: ssh, timeout: 60) { _ in
                Scripts.lockScreen(message: message, mode: mode, autoUnlockMinutes: minutes)
            }

        case "unlock":
            return await runEach(ModuleHosts.changing(a[0], command), a, ssh: ssh, timeout: 60) { _ in Scripts.unlockScreen() }

        case "ask":
            guard let question = a[0], !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                use("Podaj treść pytania: cmcrctl ask \"pytanie\" KOMP")
            }
            let buttons = (a.value("--buttons") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard buttons.count <= ClassroomConfig.maxQuestionButtons else {
                use("Okno pytania mieści najwyżej \(ClassroomConfig.maxQuestionButtons) przyciski.")
            }
            // As in the app: „Czekaj na odpowiedź” from classroom.json unless --timeout says otherwise.
            let seconds = a.int("--timeout", in: 5...3600)
                ?? min(3600, max(1, loadConfig().questionTimeoutMinutes) * 60)
            let list = ModuleHosts.changing(a[1], command)
            Console.err("Czas na odpowiedź: " + (seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"))
            logAction(list)
            return await ask(question, buttons: buttons, seconds: seconds, hosts: list, ssh: ssh)

        case "schedule":
            guard let action = a[0], ["show", "set", "clear"].contains(action) else {
                use("Użycie: cmcrctl schedule show|set|clear KOMP [opcje] – szczegóły: cmcrctl schedule --help")
            }
            if action != "set", let option = (Array(a.values.keys) + Array(a.flags)).sorted().first {
                use("Opcja \(option) dotyczy tylko polecenia schedule set.")
            }
            switch action {
            case "set":
                // The schedule and the power policy saved in the app (classroom.json); the options change them.
                let config = loadConfig()
                let schedule = parseSchedule(a, saved: config.schedule)
                let list = ModuleHosts.changing(a[1], "schedule set")
                let autoRestart = config.autoRestartAfterPowerLoss && !a.has("--no-autorestart")
                let wake = config.wakeOnLAN && !a.has("--no-womp")
                return await runEach(list, a, ssh: ssh, timeout: 60) { _ in
                    Scripts.applyEnergySchedule(schedule, autoRestart: autoRestart, wakeOnLAN: wake)
                }
            case "clear":
                return await runEach(ModuleHosts.changing(a[1], "schedule clear"), a, ssh: ssh, timeout: 60) { _ in
                    Scripts.cancelEnergySchedule()
                }
            default:
                return await eachHost(ModuleHosts.readOnly(a[1]), a, header: false) { io in
                    let h = io.host
                    let r = await SSH.run(Scripts.energyScheduleStatus(), on: h, password: Keychain.password(for: h),
                                          settings: ssh, timeout: 30)
                    guard r.succeeded else {
                        io.out("\(h.name): —")
                        return io.report(r)
                    }
                    let events = PowerScheduleParser.repeating(r.stdoutText)
                    let policy = PowerScheduleParser.policy(r.stdoutText)
                    io.out("\(h.name): \(events.isEmpty ? "brak harmonogramu" : events.map(\.text).joined(separator: "; "))"
                           + " | po zaniku zasilania: \(policy["autorestart"] == "1" ? "tak" : "nie")"
                           + " | Wake-on-LAN: \(policy["womp"] == "1" ? "tak" : "nie")")
                    return ExitCode.success
                }
            }

        case "rename", "rename-computer":
            return await renameComputers(a, ssh: ssh)

        case "power-later":
            guard a.positional.count >= 2 else { use("Użycie: cmcrctl power-later restart|shutdown|sleep MINUTY KOMP [--warn \"…\"]") }
            let action: PowerAction
            switch a.positional[0] {
            case "restart", "reboot": action = .restart
            case "shutdown": action = .shutdown
            case "sleep": action = .sleep
            default: use("Akcja: restart, shutdown lub sleep (podano „\(a.positional[0])”).")
            }
            guard let minutes = Int(a.positional[1]), minutes >= 0 else {
                use("MINUTY: liczba całkowita ≥ 0 (podano „\(a.positional[1])”).")
            }
            let warning = a.value("--warn")
            let list = ModuleHosts.changing(a[2], command)
            CLI.confirm("\(action.label) za \(minutes) min: \(ModuleHosts.names(list))? Zalogowani użytkownicy mogą stracić "
                        + "niezapisane dane.", yes: a.yes)
            return await runEach(list, a, ssh: ssh, timeout: 60) { _ in
                Scripts.delayedPower(action, minutes: minutes, warning: warning)
            }

        case "power-cancel":
            return await runEach(ModuleHosts.changing(a[0], command), a, ssh: ssh, timeout: 60) { _ in
                Scripts.cancelDelayedPower()
            }

        case "app-version":
            guard let name = a[0], !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                use("Podaj nazwę aplikacji: cmcrctl app-version \"Nazwa\" [KOMP]")
            }
            return await eachHost(ModuleHosts.readOnly(a[1]), a, header: false) { io in
                let h = io.host
                let r = await SSH.run(Scripts.appVersion(name), on: h, password: Keychain.password(for: h), settings: ssh,
                                      timeout: 60)
                guard r.succeeded else {
                    io.out("\(h.name): —")
                    return io.report(r)
                }
                let found = AppVersionInfo.parse(r.stdoutText)
                if found.isEmpty {
                    io.out("\(h.name): brak")
                } else {
                    // Version strings and paths come from the app bundles on the iMac.
                    let esc = { TerminalText.escape($0, keepBackslash: true) }
                    for app in found {
                        io.out("\(h.name): \(app.version.isEmpty ? "?" : esc(app.version)) (\(esc(app.build))) \(esc(app.path))")
                    }
                }
                return ExitCode.success
            }

        case "filevault":
            return await eachHost(ModuleHosts.readOnly(a[0]), a, header: false) { io in
                let h = io.host
                let r = await SSH.run(Scripts.fileVaultStatus(), on: h, password: Keychain.password(for: h), settings: ssh,
                                      timeout: 30)
                guard r.succeeded else {
                    io.out("\(h.name): —")
                    return io.report(r)
                }
                let kv = Parsers.keyValues(r.stdoutText)
                io.out("\(h.name): FileVault \(kv["fv"] == "on" ? "włączony" : "wyłączony")"
                       + (kv["fv"] == "on" ? (kv["authrestart"] == "yes" ? " (obsługuje authrestart)" : " (brak authrestart)") : ""))
                return ExitCode.success
            }

        case "report":
            // The list every other command uses (an unreadable hosts.json is reported, never copied or repaired here).
            legacyCLI.warnIfDefaultHosts()
            return await inventoryReport(to: a[0], hosts: legacyCLI.hosts, ssh: ssh)

        default:
            use(usage)
        }
    }

    /// `schedule set` options → schedule; a usage error (exit 2) for anything invalid. Without --on/--off it is
    /// the schedule saved in the app (`saved`); with them, only the events given. --on-type/--off-type change the
    /// saved types.
    static func parseSchedule(_ a: ModuleArguments, saved: EnergySchedule) -> EnergySchedule {
        func use(_ text: String) -> Never { moduleUsageError(a.command, text) }
        var s = saved
        let on = a.value("--on"), off = a.value("--off")
        if on != nil || off != nil {
            s.powerOnEnabled = on != nil
            s.powerOffEnabled = off != nil
        }
        if let on {
            guard let parsed = parseEvent(on) else { use("Niepoprawne --on (np. MTWRF@07:45).") }
            (s.onDays, s.onTime) = parsed
        }
        if let off {
            guard let parsed = parseEvent(off) else { use("Niepoprawne --off (np. MTWRF@16:30).") }
            (s.offDays, s.offTime) = parsed
        }
        if let t = a.value("--on-type") {
            guard let v = EnergySchedule.OnType(rawValue: t) else { use("--on-type: wakeorpoweron lub wake") }
            s.onType = v
        }
        if let t = a.value("--off-type") {
            guard let v = EnergySchedule.OffType(rawValue: t) else { use("--off-type: sleep lub shutdown") }
            s.offType = v
        }
        if let e = s.validationError {
            use(on == nil && off == nil ? "Harmonogram zapisany w aplikacji: \(e) Podaj --on lub --off." : e)
        }
        return s
    }

    /// `MTWRF@07:45` → days and time.
    static func parseEvent(_ s: String) -> (Set<Weekday>, ClockTime)? {
        let parts = s.split(separator: "@")
        guard parts.count == 2, let time = ClockTime.parse(String(parts[1])) else { return nil }
        let days = Set(parts[0].uppercased().compactMap { Weekday(rawValue: String($0)) })
        guard !days.isEmpty, days.count == Set(parts[0].uppercased()).count else { return nil }
        return (days, time)
    }

    /// Asks all Macs at once; answers are printed as they arrive. Students type the answers, so they are escaped.
    /// Every question is a registered job: Ctrl-C closes the dialogs on the iMacs too, as „Przerwij” in the app
    /// (AUDIT REV-36); of the scripts' output only how that went is shown („imac01: ▸ Zatrzymano polecenie…”).
    static func ask(_ question: String, buttons: [String], seconds: Int, hosts: [Machine], ssh: SSHSettings) async -> Int32 {
        let script = Scripts.ask(title: "Pytanie od nauczyciela", prompt: question, buttons: buttons, timeoutSeconds: seconds)
        var status = ExitCode.success
        await withTaskGroup(of: (Machine, CommandResult).self) { group in
            for h in hosts {
                let pw = Keychain.password(for: h)
                let stopNotes: @Sendable (OutputChannel, Data) -> Void = { channel, data in
                    guard channel == .stderr, data.starts(with: Data("▸ ".utf8)) else { return }
                    Console.write(.stderr, Data("\(h.name): ".utf8) + data)
                }
                group.addTask {
                    (h, await Interruption.shared.run(script, on: h, password: pw, settings: ssh,
                                                      timeout: TimeInterval(seconds + 60), onOutput: stopNotes))
                }
            }
            for await (h, r) in group {
                if let answer = StudentAnswer.parse(r.stdoutText) {
                    let who = answer.user.isEmpty ? "" : " (\(TerminalText.escape(answer.user)))"
                    Console.out("\(h.name)\(who): \(TerminalText.escape(answer.displayText, keepBackslash: true))")
                } else {
                    Console.out("\(h.name): —")
                    Console.err("✘ \(h.name): \(SSH.diagnose(r).1)")
                    status = ExitCode.failure
                }
            }
        }
        return status
    }

    /// `.local` names (lowercased) of the Macs on the list that are not renamed, with the Mac that has the name: from
    /// its `.local` address and from its name on the list (the name rename-computer gives it by default).
    static func namesTaken(by machines: [Machine], renaming: Set<UUID>) -> [String: String] {
        var taken: [String: String] = [:]
        for m in machines where !renaming.contains(m.id) {
            let own = ComputerNames.localHostName(from: m.name).lowercased()
            if !own.isEmpty { taken[own] = m.name }
            let address = m.address.lowercased()
            if address.hasSuffix(".local") { taken[String(address.dropLast(".local".count))] = m.name }
        }
        return taken
    }

    /// ComputerName, LocalHostName and HostName from the host list (or `--name` for one Mac). Always needs an
    /// explicit host list; every new name is checked before anything changes, and the change is confirmed.
    static func renameComputers(_ a: ModuleArguments, ssh: SSHSettings) async -> Int32 {
        let targets = ModuleHosts.required(a[0], a.command, why: "bez --name każdy dostaje nazwę z listy komputerów")
        if let name = a.value("--name") {
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { moduleUsageError(a.command, "--name: podaj nazwę.") }
            guard targets.count == 1 else {
                moduleUsageError(a.command, "--name można podać tylko dla jednego komputera (wszystkie dostałyby tę samą nazwę). "
                                 + "Bez --name każdy komputer dostaje nazwę z listy.")
            }
        }
        var planned: [(host: Machine, name: String, localHostName: String)] = []
        var invalid = false
        let taken = Self.namesTaken(by: legacyCLI.hosts, renaming: Set(targets.map(\.id)))
        var seen: Set<String> = []
        for h in targets {
            let name = a.value("--name") ?? h.name
            let lhn = ComputerNames.localHostName(from: name)
            guard ComputerNames.isValidLocalHostName(lhn) else {
                Console.err("\(h.name): niepoprawna nazwa „\(name)”.")
                invalid = true
                continue
            }
            // Bonjour would rename this Mac (imac04-2) and the updated list would point at the other one (AUDIT
            // KOM-15, REV-33): the same rule as the app's „Zmień nazwy komputerów”.
            if let owner = taken[lhn.lowercased()] {
                Console.err("\(h.name): „\(name)” → \(lhn).local – ten adres ma już \(owner) z listy komputerów "
                            + "(dwa komputery nie mogą mieć tego samego adresu w sieci).")
                invalid = true
                continue
            }
            guard seen.insert(lhn.lowercased()).inserted else {
                Console.err("\(h.name): „\(name)” → \(lhn).local – ten adres powtarza się "
                            + "(dwa komputery nie mogą mieć tego samego adresu w sieci).")
                invalid = true
                continue
            }
            Console.out("\(h.name): „\(name)” → \(lhn).local")
            planned.append((h, name, lhn))
        }
        if invalid { moduleUsageError(a.command, "Popraw nazwę – nic nie zostało zmienione.") }
        if a.has("--dry-run") { return ExitCode.success }
        var hosts = a.has("--update-list") ? legacyCLI.editableHosts() : []
        CLI.confirm("Zmienić nazwę komputera (ComputerName, LocalHostName, HostName) na: \(ModuleHosts.names(targets))? "
                    + "Adres .local każdego z nich zmieni się według nowej nazwy.", yes: a.yes)
        logAction(targets)
        var status = ExitCode.success
        var notStarted: [Machine] = []
        for p in planned {
            // After Ctrl-C the remaining Macs keep their names (AUDIT REV-36).
            if Interruption.shared.isInterrupted {
                notStarted.append(p.host)
                status = ExitCode.failure
                continue
            }
            Console.out("\(p.host.name):")
            // A registered job: Ctrl-C stops the rename on the iMac too (Interruption).
            let r = await Interruption.shared.run(Scripts.renameComputer(computerName: p.name, localHostName: p.localHostName),
                                                  on: p.host, password: Keychain.password(for: p.host), settings: ssh,
                                                  timeout: 60, onOutput: Console.printer)
            if report(r) != ExitCode.success { status = ExitCode.failure }
            if r.succeeded, a.has("--update-list"), let i = hosts.firstIndex(where: { $0.id == p.host.id }) {
                let before = hosts[i]
                hosts[i].name = p.name
                if let address = ComputerNames.addressAfterRename(hosts[i].address, localHostName: p.localHostName) {
                    hosts[i].address = address
                }
                saveHostsOrFail(hosts)
                Console.out("Zaktualizowano listę komputerów: \(hosts[i].name) → \(hosts[i].address)")
                // The Mac keeps its host keys: trust them under the new address too, as the app does – otherwise
                // every later connection is refused as an unknown Mac (AUDIT KOM-07, REV-01).
                if hosts[i].address != before.address,
                   await HostTrust.carryTrust(from: before, to: hosts[i], settings: ssh) {
                    Console.out("Zaufany klucz SSH obowiązuje także pod nowym adresem \(hosts[i].address).")
                }
            }
        }
        Interruption.shared.reportNotStarted(notStarted)
        return status
    }

    static func lesson(start: Bool, config: ClassroomConfig, hosts: [Machine], wait: Bool, yes: Bool,
                       settings: AppSettings, ssh: SSHSettings) async -> Int32 {
        let plan = start ? LessonPlan.start(config.start, settings: settings) : LessonPlan.end(config.end, settings: settings)
        guard !plan.steps.isEmpty else {
            moduleUsageError("lesson", "Scenariusz nie ma żadnych kroków (ustaw je w aplikacji: Zajęcia).")
        }
        // As in the app: ending a lesson that logs out, powers off, cleans folders or quits apps is confirmed.
        if !start && config.end.isDisruptive {
            CLI.confirm("Zakończyć zajęcia na: \(ModuleHosts.names(hosts))? Kroki: \(plan.steps.map(\.title).joined(separator: " → ")). "
                        + "Uczniowie mogą stracić niezapisaną pracę.", yes: yes)
        }
        Console.out("\(plan.kind.title): \(plan.steps.map(\.title).joined(separator: " → "))")
        if let folder = plan.collectFolder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Console.out("Zebrane prace: \(folder.path)")
        }
        var payload: URL?
        if plan.steps.contains(.materials) {
            // Never the current directory (an empty setting) and never silently nothing: stop before any step runs.
            switch LessonMaterials.items(in: config.start.materialsFolder) {
            case .failure(let problem):
                fail("✘ Materiały: \(problem.message) Nic nie zostało uruchomione.")
            case .success(let items) where !items.isEmpty:
                // A job of its own: Ctrl-C stops the packing and removes the archive (AUDIT REV-44).
                switch await Interruption.shared.pack(items) {
                case .success(let url): payload = url
                case .failure where Interruption.shared.isInterrupted:
                    Console.err("✘ Materiały: przerwano pakowanie plików. Nic nie zostało uruchomione.")
                    return ExitCode.failure
                case .failure(let error): fail("✘ Materiały: nie udało się ich spakować (\(error.localizedDescription)). Nic nie zostało uruchomione.")
                }
            case .success:
                Console.out("Folder z materiałami jest pusty – krok „Wyślij materiały” zostanie pominięty.")
            }
        }
        defer { if let payload { Interruption.shared.discard(payload) } }
        logAction(hosts)

        // As in the app: Wake-on-LAN for the same MACs (status-cache.json), every Mac at once – packets go out to all
        // first, each Mac then only waits for itself – and the other steps share the usual number of connections
        // (ConcurrencyLimiter, „Komputery obsługiwane naraz”). Output stays in list order.
        let snapshots = ClassroomStore.loadSnapshots()
        let targets = hosts.map { h -> LessonRunner.Host in
            let info = snapshots[h.id]?.info ?? [:]
            return LessonRunner.Host(machine: h, password: Keychain.password(for: h),
                                     macs: WakeOnLAN.candidateMACs(listed: h.macAddress, lastStatus: info),
                                     extraBroadcasts: WakeOnLAN.lastSeenBroadcasts(info))
        }
        let parallel = max(1, settings.maxParallel)
        func runAll(_ range: Range<Int>, materials: URL?, limiter: ConcurrencyLimiter?, jobs: Int) async -> [Int32] {
            await runHosts(hosts, jobs: jobs, prefixLines: false) { io in
                io.out("== \(io.host.name)")
                // A registered job: Ctrl-C stops the step running on the iMac and skips the rest (AUDIT REV-36).
                let r = await Interruption.shared.job(on: io.host) { handle in
                    await LessonRunner.run(plan, on: targets[io.index], ssh: ssh, materials: materials, range: range,
                                           limiter: limiter, handle: handle, onOutput: io.stream)
                }
                if r.cancelled { return io.report(r) }
                guard r.succeeded else {
                    io.write(.stderr, r.stderr)
                    return ExitCode.failure
                }
                return ExitCode.success
            }
        }
        var first = 0
        if plan.steps.first == .warn {
            _ = await runAll(0..<1, materials: nil, limiter: nil, jobs: parallel)
            // Interrupted during the warning: the other steps do not start (Ctrl-C during the pause ends at once).
            if Interruption.shared.isInterrupted { return ExitCode.failure }
            if wait {
                let secs = max(1, plan.end.warnMinutes) * 60
                Console.out("Czekam \(secs / 60) min przed kolejnymi krokami…")
                try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            }
            first = 1
        }
        guard first < plan.steps.count else { return ExitCode.success }
        let waking = plan.steps[first...].contains(.wake)
        if waking {
            for t in targets {
                for mac in t.macs { _ = try? WakeOnLAN.wake(mac: mac, extraBroadcasts: t.extraBroadcasts) }
            }
        }
        let codes = await runAll(first..<plan.steps.count, materials: payload,
                                 limiter: waking ? ConcurrencyLimiter(limit: parallel) : nil,
                                 jobs: waking ? hosts.count : parallel)
        return codes.allSatisfy { $0 == ExitCode.success } ? ExitCode.success : ExitCode.failure
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
                Console.out("Zapisano raport: \(url.path) (\(hosts.count) \(Plural.computers(hosts.count)))")
            } catch {
                Console.err("✘ Nie można zapisać \(url.path): \(error.localizedDescription)")
                return ExitCode.failure
            }
        } else {
            Console.out(CSV.render(rows, bom: false), terminator: "")
        }
        return statuses.values.contains { $0.reachability != .online } ? ExitCode.failure : ExitCode.success
    }
}
