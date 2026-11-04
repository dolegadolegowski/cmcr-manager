import CMCRCore
import Foundation

let usage = """
cmcrctl – zarządzanie iMacami z terminala (odpowiednik cmcr-helpers.sh)

Użycie: cmcrctl POLECENIE [argumenty] [opcje]

KOMP – wybór komputerów: all | numer z nazwy (4 → imac04) | lista (1,3,7) | zakres (1-5)
       | pozycja na liście (@2) | nazwa, adres lub konto (imac04, imac04.local).
Bez KOMP polecenia, które tylko odczytują (status, readiness, filevault, app-version, schedule show),
działają na wszystkich komputerach; polecenia, które coś zmieniają (exec, open-app, quit-app, lock,
lesson, install, trust…) – tylko w terminalu, po pytaniu „Wykonać na wszystkich?” (--yes na nie nie odpowiada),
a w skryptach wymagają podania KOMP, np. all. rename (nazwy komputerów) zawsze wymaga KOMP.
cmcrctl POLECENIE --help – pomoc jednego polecenia (niczego nie wykonuje).

Stan i polecenia
  list                                     lista komputerów
  status [KOMP] [--json]                   stan komputerów (równolegle); zapamiętuje adresy MAC
  exec "polecenie" [KOMP] [--root]         cmcr-exec: wykonaj polecenie (jako root z rm -r, shutdown, diskutil…
                                           – w terminalu po potwierdzeniu)
  go nr                                    cmcr-go: interaktywna sesja ssh
  render "polecenie" [--root]              pokaż skrypt wykonywany zdalnie

Pliki
  push KOMP [--root]                       cmcr-push: ~/Public/cmcr/{all,<host>}/* → folder ucznia; bez --root
                                           właścicielem plików jest konto administratora, z --root – uczeń
                                           (jak „Wyślij” w aplikacji)
  pull KOMP [--root]                       cmcr-pull: folder ucznia → ~/Public/cmcr/<host>
  ls ŚCIEŻKA KOMP [--root]                 zawartość folderu ({student} = konto ucznia, {console} = zalogowany
                                           użytkownik)
  clean ŚCIEŻKA KOMP                       usuń zawartość folderu (/Users/<konto>/…, /tmp, /Volumes)

Aplikacje
  apps nr                                  uruchomione aplikacje użytkownika
  open-app "Nazwa" [KOMP]                  uruchom aplikację u zalogowanego użytkownika
  quit-app "Nazwa" [KOMP] [--force]        zamknij aplikację (--force: natychmiast, po potwierdzeniu)
  open-url ADRES KOMP                      otwórz stronę lub plik u zalogowanego użytkownika
  kill PID nr [--force]                    zakończ proces na jednym komputerze (--force: SIGKILL)
  uninstall /Applications/X.app KOMP       usuń aplikację
  brew "argumenty" KOMP                    Homebrew, np.: cmcrctl brew "install --cask firefox" all
  screenshot nr plik.jpg                   zrzut ekranu zalogowanego użytkownika

Aktualizacje macOS
  updates list KOMP                        dostępne aktualizacje (równolegle)
  updates install KOMP [--restart] [--download] [--recommended] [--major]
                                           instalacja (--restart: z ponownym uruchomieniem,
                                           --download: tylko pobierz, --recommended: tylko zalecane,
                                           --major: także nowa wersja macOS, po potwierdzeniu)
  updates history KOMP                     historia instalacji

Sesja i zasilanie
  message "tytuł" "treść" KOMP [--notification]   okno z wiadomością (lub powiadomienie)
  logout KOMP [--force]                    poproś o wylogowanie (aplikacje mogą zapytać o zapis);
                                           --force: wyloguj natychmiast (także sesje w tle)
  power restart|shutdown|sleep|display-sleep KOMP
                                           uruchom ponownie | wyłącz | uśpij | uśpij ekran
  wake KOMP [--wait] [--dry-run]           obudź przez sieć (Wake-on-LAN, wymaga adresu MAC; najpierw MAC
                                           karty Ethernet); --wait: czekaj do 3 min, aż komputery odpowiedzą

Konfiguracja
  hosts [list]                             komputery ze szczegółami (port, MAC, hasło)
  hosts add nazwa [adres] [konto] [--port N] [--mac MAC]
  hosts set nr [--mac MAC] [--port N]      zmień adres MAC lub port komputera
  hosts remove KOMP
  hosts generate [prefiks] [--start 1] [--count 15] [--digits 2] [--domain local] [--replace|--append]
                                           jak pętla w cmcr-helpers.sh; bez --replace/--append tylko podgląd
  password set [--host nr]                 zapisz hasło administratora w Pęku kluczy (ze stdin, bez echa)
  password clear [--host nr]               usuń zapisane hasło
  password status                          czy hasła są zapisane
\(CLI.trustUsage)
  selftest                                 sprawdź składnię wszystkich skryptów zdalnych (bash -n)

Opcje
  -j N, --jobs N    ile komputerów obsługiwać naraz (domyślnie 1; status i updates list: „Komputery obsługiwane
                    naraz” z Konfiguracja › Ustawienia, domyślnie \(AppSettings().maxParallel)); wyniki zawsze w kolejności listy
  --prefix          poprzedź każdy wiersz wyniku nazwą komputera, np. [imac04]
                    (-j i --prefix: polecenia z argumentem KOMP, poza wake, hosts remove, lesson,
                    rename, setup, readiness, trust i ask – ask pyta wszystkie komputery naraz)
  --root            wykonaj jako root (sudo z hasłem administratora)
  --yes, -y         nie pytaj o potwierdzenie (wymagane bez terminala dla restartu, wylogowania, usuwania,
                    quit-app --force, power-later, zakończenia zajęć, zmiany nazw komputerów, collect --clean)
  --                koniec opcji – dalsze argumenty dosłownie

Kody wyjścia: 0 – sukces, 1 – błąd na co najmniej jednym komputerze, 2 – błędne użycie (także opcja,
której polecenie nie używa, lub nadmiarowy argument – wtedy nic nie jest wykonywane);
exec zwraca kod zdalnego polecenia (najwyższy z kilku komputerów; nieudane lub zerwane połączenie – 1),
screen-watch – także 3–6;
130 – przerwano: Ctrl-C zatrzymuje także na iMacach każde polecenie, które coś na nich zmienia, i nie uruchamia go
już na kolejnych; ponowne Ctrl-C kończy od razu.

W terminalu znaki sterujące w wynikach z iMaców (np. sekwencje ESC w nazwach plików) są pokazywane
jako ^[, ^M…; wynik przekierowany do pliku lub potoku (… | cat) pozostaje dosłowny.

Konfiguracja: \(ConfigStore.directory.path)
Hasło administratora: Pęk kluczy (cmcrctl password set lub aplikacja) albo zmienna CMCR_PASSWORD.
"""

struct CLI: Sendable {
    let args: Arguments
    let settings = ConfigStore.loadSettings()
    let hosts: [Machine]
    /// Why hosts.json could not be read; `hosts` is then the default lab, as in `ConfigStore.loadHosts()`.
    let hostsProblem: String?

    init(args: Arguments) {
        self.args = args
        do {
            hosts = try ConfigStore.readHostsFile() ?? Machine.generate()
            hostsProblem = nil
        } catch {
            hosts = Machine.generate()
            hostsProblem = error.localizedDescription
        }
    }

    /// Options of commands that run on several Macs through `runHosts`.
    static let parallel: Set<String> = ["-j", "--prefix"]

    /// Core commands that accept `parallel` (their help describes -j and --prefix).
    static let parallelCommands: Set<String> = [
        "status", "exec", "push", "pull", "ls", "clean", "open-app", "quit-app", "open-url", "uninstall", "brew",
        "updates", "message", "logout", "power",
    ]

    var root: Bool { args.has("--root") }
    var force: Bool { args.has("--force") }
    var prefixLines: Bool { args.has("--prefix") }

    func run() async -> Int32 {
        guard let command = args[0] else {
            Console.out(fullUsage)
            return ExitCode.success
        }
        if args.has("--help") || args.has("-h") || command == "help" {
            // `cmcrctl POLECENIE --help` (or `help POLECENIE`): that command's help; `cmcrctl help`: everything.
            let topic = command == "help" ? args[1] : command
            Console.out(topic.map { commandHelp($0, spec: Self.parallelCommands.contains($0) ? ModuleSpec(parallel: true) : nil) }
                        ?? fullUsage)
            return ExitCode.success
        }
        switch command {
        case "list": return list()
        case "render": return render()
        case "status": return await status()
        case "exec": return await exec()
        case "go": go()
        case "push": return await push()
        case "pull": return await pull()
        case "ls": return await listFolder()
        case "clean": return await clean()
        case "apps": return await apps()
        case "open-app", "quit-app": return await openQuitApp(open: command == "open-app")
        case "open-url": return await openURL()
        case "kill": return await kill()
        case "uninstall": return await uninstall()
        case "brew": return await brew()
        case "screenshot": return await screenshot()
        case "updates": return await updates()
        case "message": return await message()
        case "logout": return await logout()
        case "power": return await power()
        case "wake": return await wake()
        case "hosts": return hostsCommand()
        case "password": return password()
        case "trust": return await trust()
        case "selftest": return await selftest()
        default:
            usageError("Nieznane polecenie: \(command)")
        }
    }

    // MARK: - Helpers

    var hostsPath: String { ConfigStore.directory.appendingPathComponent("hosts.json").path }

    func warnIfDefaultHosts() {
        guard let hostsProblem else { return }
        Console.err("Uwaga: nie można odczytać \(hostsPath) (\(hostsProblem)) – używana jest domyślna lista "
                    + "\(hosts.first?.name ?? "")–\(hosts.last?.name ?? "").")
    }

    /// The host list for commands that change and save it. Saving the default list that replaced an unreadable
    /// hosts.json would silently lose the user's entries, so those commands stop instead.
    func editableHosts() -> [Machine] {
        if let hostsProblem {
            fail("Nie można odczytać \(hostsPath) (\(hostsProblem)) – popraw plik lub usuń go; lista komputerów nie została zmieniona.")
        }
        return hosts
    }

    func sshSettings() -> SSHSettings { SSHSettings(settings, askpassPath: ConfigStore.ensureAskpass()) }

    func targets(_ spec: String?, defaultAll: Bool = false) -> [Machine] {
        warnIfDefaultHosts()
        guard let spec else {
            guard defaultAll else { usageError("Podaj komputery: all, numer (4), lista (1,3), zakres (1-5) lub nazwę.") }
            guard !hosts.isEmpty else { fail(HostSpec.SelectionError.emptyList.localizedDescription) }
            return hosts
        }
        do {
            return try HostSpec.select(spec, from: hosts)
        } catch {
            fail(error.localizedDescription, code: ExitCode.usage)
        }
    }

    /// exec, open-app, quit-app and trust keep cmcr-exec's "no list = every Mac", but only at a terminal, announced
    /// and asked there. In a script a dropped argument – an unquoted `#3` is a comment – must not widen the command to
    /// the lab: without a terminal it is an error, and a script started from Terminal (it inherits the terminal) gets
    /// the question too, which `--yes` does not answer – only the person at the keyboard can. trust asks as well: its
    /// own confirmation is answered by `--yes`, so `trust $NR --yes` with an empty $NR would otherwise trust every new
    /// key of the lab without a question (AUDIT REV-32).
    func targetsOrAllAtTerminal(_ spec: String?, command: String) -> [Machine] {
        guard spec == nil else { return targets(spec) }
        guard isatty(STDIN_FILENO) != 0 else {
            usageError("Podaj komputery dla polecenia \(command) (all, numer 4, lista 1,3, zakres 1-5 lub pozycja @2) "
                       + "– bez terminala nie są wybierane wszystkie automatycznie.")
        }
        let list = targets(nil, defaultAll: true)
        Console.err("Nie podano komputerów – \(command) na wszystkich: \(names(list)).")
        guard Self.askAtTerminal("Wykonać na wszystkich? [t/N] ") else {
            fail("Przerwano – nic nie zostało wykonane. W skryptach podaj komputery, np. all albo 4.")
        }
        return list
    }

    /// A question at the terminal that only the person at the keyboard answers (`--yes` does not): true for „t”.
    static func askAtTerminal(_ question: String) -> Bool {
        Console.err(question, terminator: "")
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["t", "tak", "y", "yes"].contains(answer)
    }

    func single(_ spec: String?, usage text: String) -> Machine {
        guard let spec else { usageError(text) }
        let found = targets(spec)
        guard found.count == 1 else {
            usageError("Podaj jeden komputer (pasuje \(found.count): \(found.map(\.name).joined(separator: ", "))).")
        }
        return found[0]
    }

    /// Asks before disruptive actions. Without a terminal `--yes` is required, so scripts never hang.
    func confirm(_ question: String) { Self.confirm(question, yes: args.yes) }

    /// `confirm` for commands with their own parser (module commands): `yes` is their `--yes`/`-y`.
    static func confirm(_ question: String, yes: Bool) {
        if yes { return }
        guard isatty(STDIN_FILENO) != 0 else {
            usageError("\(question)\nTo polecenie wymaga potwierdzenia – dodaj --yes.")
        }
        Console.err("\(question) Kontynuować? [t/N] ", terminator: "")
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["t", "tak", "y", "yes"].contains(answer) else { fail("Przerwano.") }
    }

    func names(_ list: [Machine]) -> String {
        let shown = list.prefix(8).map(\.name).joined(separator: ", ")
        return (list.count > 8 ? shown + " …" : shown) + " (\(plural(list.count, "komputer", "komputery", "komputerów")))"
    }

    func header(_ host: Machine) -> String { "== \(host.name) (\(host.destination)) ==" }

    /// Streams one remote script per host under a header; the common shape of most commands. `note` may add a
    /// hint for the terminal under a host's result – below the reason of a failure (AUDIT REV-38) – e.g. the
    /// cmcrctl option for what the script skipped.
    func runScript(on list: [Machine], jobs: Int? = nil, passThrough: Bool = false,
                   header makeHeader: (@Sendable (Machine) -> String)? = nil,
                   note: (@Sendable (Machine, CommandResult) -> String?)? = nil,
                   _ script: @escaping @Sendable (Machine) -> RemoteScript) async -> Int32 {
        let ssh = sshSettings()
        let defaultHeader = header
        let codes = await runHosts(list, jobs: jobs ?? args.jobs ?? 1, prefixLines: prefixLines) { io in
            io.out(makeHeader?(io.host) ?? defaultHeader(io.host))
            // A registered job: Ctrl-C stops it on the iMac too (Interruption).
            let r = await Interruption.shared.run(script(io.host), on: io.host, password: Keychain.password(for: io.host),
                                                  settings: ssh, onOutput: io.stream)
            let code = io.report(r, passThrough: passThrough)
            if let text = note?(io.host, r) { io.err(text) }
            return code
        }
        return combine(codes, passThrough: passThrough)
    }

    func combine(_ codes: [Int32], passThrough: Bool = false) -> Int32 {
        if passThrough { return codes.max() ?? ExitCode.success }
        return codes.contains { $0 != ExitCode.success } ? ExitCode.failure : ExitCode.success
    }

    // MARK: - State & commands

    func list() -> Int32 {
        args.expect("list", positional: 1)
        warnIfDefaultHosts()
        for (i, h) in hosts.enumerated() {
            Console.out(pad("\(i + 1)", 2, right: true) + "  " + pad(h.name, 12) + " " + pad(h.destination, 24) + " "
                        + (h.port == 22 ? "" : "port \(h.port)"))
        }
        return ExitCode.success
    }

    func render() -> Int32 {
        args.expect("render", options: ["--root"], positional: 2)
        guard let command = args[1] else { usageError("Podaj polecenie.") }
        Console.out(RemoteScript(command, asRoot: root).render(), terminator: "")
        return ExitCode.success
    }

    func status() async -> Int32 {
        // --prefix is accepted for symmetry with the other commands: status lines already start with the name.
        args.expect("status", options: Self.parallel.union(["--json"]), positional: 2)
        let list = targets(args[1], defaultAll: true)
        let json = args.has("--json")
        let ssh = sshSettings()
        let timeout = TimeInterval(settings.connectTimeout + 25)
        let results = ResultBox(count: list.count)
        let codes = await runHosts(list, jobs: args.jobs ?? max(1, settings.maxParallel), prefixLines: false) { io in
            let h = io.host
            let r = await SSH.run(Scripts.status(), on: h, password: Keychain.password(for: h), settings: ssh, timeout: timeout)
            results.set(io.index, r)
            guard !json else { return r.succeeded ? ExitCode.success : ExitCode.failure }
            if r.succeeded {
                // Reported by the iMac: escaped like every remote value shown on its own line.
                let kv = Parsers.keyValues(r.stdoutText).mapValues { TerminalText.escape($0, keepBackslash: true) }
                let user = kv["console"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                io.out("● \(h.name): macOS \(kv["os"] ?? "?") \(kv["model"] ?? "") użytkownik: \(user) IP \(kv["ip"] ?? "?")")
                return ExitCode.success
            }
            io.out("○ \(h.name): \(SSH.diagnose(r).1)")
            if !r.started, HostTrust.refusal(r) != nil {
                io.out("  W terminalu: cmcrctl trust \(h.name) – pokaże odcisk klucza i zapyta o zaufanie.")
            }
            return ExitCode.failure
        }
        let all = results.all()
        if json {
            let rows: [[String: Any]] = zip(list, all).map { h, r in
                var row: [String: Any] = ["name": h.name, "address": h.address, "user": h.user, "port": h.port,
                                          "destination": h.destination]
                if let n = h.number { row["number"] = n }
                let info = r.map { $0.succeeded ? Parsers.keyValues($0.stdoutText) : [:] } ?? [:]
                if let r, r.succeeded {
                    row["reachability"] = Reachability.online.rawValue
                    row["online"] = true
                    row["message"] = ""
                } else {
                    let (reach, message) = r.map(SSH.diagnose) ?? (.error, "Brak wyniku.")
                    row["reachability"] = (reach == .online ? Reachability.error : reach).rawValue
                    row["online"] = false
                    row["message"] = message
                }
                row["info"] = info
                return row
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                Console.write(.stdout, data + Data("\n".utf8))
            }
        }
        rememberMACs(list, all, quiet: json)
        return combine(codes)
    }

    /// Like the app: a MAC address reported by a running Mac is stored for Wake-on-LAN when none is set – that of the
    /// wired port when the Mac has one (`HostStatus.mac`), not of the default route, which may be Wi-Fi.
    func rememberMACs(_ list: [Machine], _ results: [CommandResult?], quiet: Bool) {
        var learned: [(host: Machine, mac: String)] = []
        for (h, r) in zip(list, results) where h.macAddress.isEmpty {
            guard let r, r.succeeded else { continue }
            var status = HostStatus()
            status.info = Parsers.keyValues(r.stdoutText)
            guard let mac = status.mac.flatMap(HostEntry.normalizedMAC) else { continue }
            learned.append((h, mac))
        }
        guard !learned.isEmpty else { return }
        // Re-read: the app may have changed the list while status was running. Never replace a list we could not read.
        var current: [Machine]
        do { current = try ConfigStore.readHostsFile() ?? hosts } catch { return }
        // Entries written without an `id` get a new one on every load, so also match by connection details.
        func same(_ a: Machine, _ b: Machine) -> Bool {
            a.id == b.id || (a.name == b.name && a.address == b.address && a.user == b.user && a.port == b.port)
        }
        var updated: [String] = []
        for i in current.indices where current[i].macAddress.isEmpty {
            if let mac = learned.first(where: { same($0.host, current[i]) })?.mac {
                current[i].macAddress = mac
                updated.append(current[i].name)
            }
        }
        guard !updated.isEmpty else { return }
        if let problem = ConfigStore.saveHosts(current) {
            Console.err("Nie zapisano adresu MAC (Wake-on-LAN): \(problem)")
        } else if !quiet {
            Console.err("Zapisano adres MAC (Wake-on-LAN): \(updated.joined(separator: ", "))")
        }
    }

    func exec() async -> Int32 {
        args.expect("exec", options: Self.parallel.union(["--root"]), positional: 3)
        guard let command = args[1] else { usageError("Podaj polecenie.") }
        let list = targetsOrAllAtTerminal(args[2], command: "exec")
        let asRoot = root
        // As in the app (Polecenia): a root command that deletes folders, restarts, formats… is confirmed – at the
        // terminal; scripts keep working as before and only get the warning.
        let risks = CommandRisk.risks(in: command)
        if CommandRisk.usesRoot(command, asRoot: asRoot), !risks.isEmpty {
            let what = "Polecenie zawiera: \(risks.joined(separator: ", "))."
            if isatty(STDIN_FILENO) != 0 {
                confirm("\(what) Uruchomić je jako root na: \(names(list))?")
            } else if !args.yes {
                Console.err("Uwaga: p" + what.dropFirst() + " Wykonywane jako root na: \(names(list)).")
            }
        }
        logAction(list)
        return await runScript(on: list, passThrough: true, header: { "Running command on \($0.destination) ..." }) { _ in
            RemoteScript(command, asRoot: asRoot)
        }
    }

    func go() -> Never {
        args.expect("go", positional: 2)
        let h = single(args[1], usage: "Podaj numer komputera.")
        if let message = SSH.refusalMessage(for: h) { fail(message) }
        let argv = ["ssh"] + SSH.interactiveArguments(for: h, settings: sshSettings())
        let cargs = argv.map { strdup($0) } + [nil]
        execv(SSH.sshPath, cargs)
        fail("Nie można uruchomić ssh.")
    }

    // MARK: - Files

    func push() async -> Int32 {
        args.expect("push", options: Self.parallel.union(["--root"]), positional: 2)
        guard args[1] != nil else { usageError("Podaj all lub numer komputera.") }
        let list = targets(args[1])
        let ssh = sshSettings()
        let s = settings, asRoot = root
        logAction(list)
        let codes = await runHosts(list, jobs: args.jobs ?? 1, prefixLines: prefixLines) { io in
            let h = io.host
            let items = Operations.conventionItems(base: s.localFolder, host: h)
            io.out("Pushing to \(h.destination) ... (\(plural(items.count, "element", "elementy", "elementów")))")
            if items.isEmpty { return ExitCode.success }
            // A registered job: Ctrl-C stops the packing, the upload or the unpacking on the iMac (Interruption).
            return await Interruption.shared.job(on: h) { handle in
                switch await Payload.make(items, handle: handle) {
                case .failure(let e):
                    io.err("✘ \(h.name): \(e.localizedDescription)")
                    return ExitCode.failure
                case .success(let payload):
                    defer { try? FileManager.default.removeItem(at: payload) }
                    let r = await Operations.push(payload: payload, to: h, destination: s.studentFolder,
                                                  owner: asRoot ? s.studentUser : "", mode: "777", asRoot: asRoot,
                                                  password: Keychain.password(for: h), settings: ssh, handle: handle,
                                                  onOutput: io.stream)
                    return io.report(r)
                }
            }
        }
        return combine(codes)
    }

    func pull() async -> Int32 {
        args.expect("pull", options: Self.parallel.union(["--root"]), positional: 2)
        guard args[1] != nil else { usageError("Podaj all lub numer komputera.") }
        let list = targets(args[1])
        let ssh = sshSettings()
        let s = settings, asRoot = root
        logAction(list)
        let codes = await runHosts(list, jobs: args.jobs ?? 1, prefixLines: prefixLines) { io in
            let h = io.host
            io.out("Pulling from \(h.destination) ...")
            let dest = URL(fileURLWithPath: expandTilde(s.localFolder)).appendingPathComponent(h.folderKey)
            let r = await Interruption.shared.job(on: h) { handle in
                await Operations.pull(source: s.studentFolder, from: h, into: dest, asRoot: asRoot,
                                      password: Keychain.password(for: h), settings: ssh, handle: handle,
                                      onOutput: io.stream)
            }
            return io.report(r)
        }
        return combine(codes)
    }

    func listFolder() async -> Int32 {
        args.expect("ls", options: Self.parallel.union(["--root"]), positional: 3)
        // {student} as in every other path option (collect --from, rm, get…); {console} is resolved on the iMac.
        guard let path = args[1].map(settings.resolve) else { usageError("Użycie: cmcrctl ls ŚCIEŻKA KOMP [--root]") }
        let list = targets(args[2])
        let asRoot = root
        return await runScript(on: list) { _ in Scripts.listFolder(path, asRoot: asRoot) }
    }

    func clean() async -> Int32 {
        args.expect("clean", options: Self.parallel, positional: 3)
        guard let path = args[1].map(settings.resolve) else { usageError("Użycie: cmcrctl clean ŚCIEŻKA KOMP") }
        let list = targets(args[2])
        confirm("Usunąć całą zawartość folderu \(path) na: \(names(list))?")
        logAction(list)
        return await runScript(on: list) { _ in Scripts.cleanFolder(path) }
    }

    // MARK: - Applications

    func apps() async -> Int32 {
        args.expect("apps", positional: 2)
        let h = single(args[1], usage: "Podaj numer komputera.")
        let r = await SSH.run(Scripts.runningApps(), on: h, password: Keychain.password(for: h), settings: sshSettings())
        let parsed = Parsers.runningApps(r.stdoutText)
        Console.out("Użytkownik: \(parsed.user.map { TerminalText.escape($0) } ?? "—")")
        for app in parsed.apps {
            Console.out(String(format: "%7ld  %@", app.pid, TerminalText.escape(app.bundlePath, keepBackslash: true) as NSString))
        }
        if !r.succeeded {
            Console.err("✘ \(h.name): \(SSH.diagnose(r).1)")
            return ExitCode.failure
        }
        return ExitCode.success
    }

    func openQuitApp(open: Bool) async -> Int32 {
        args.expect(open ? "open-app" : "quit-app", options: open ? Self.parallel : Self.parallel.union(["--force"]),
                    positional: 3)
        guard let app = args[1] else { usageError("Podaj nazwę aplikacji.") }
        let list = targetsOrAllAtTerminal(args[2], command: open ? "open-app" : "quit-app")
        let hard = force
        // As in the app („Wymuś zamknięcie…”): killing the app loses the students' unsaved work.
        if !open && hard {
            confirm("Wymusić zamknięcie „\(app)” na: \(names(list))? Aplikacja zostanie natychmiast zakończona – "
                    + "niezapisana praca uczniów przepadnie.")
        }
        logAction(list)
        return await runScript(on: list, header: { "\($0.name):" }) { _ in
            open ? Scripts.launchApp(app) : Scripts.quitApp(app, force: hard)
        }
    }

    func openURL() async -> Int32 {
        args.expect("open-url", options: Self.parallel, positional: 3)
        guard let url = args[1] else { usageError("Użycie: cmcrctl open-url ADRES KOMP") }
        let list = targets(args[2])
        logAction(list)
        return await runScript(on: list) { _ in Scripts.openURL(url) }
    }

    /// A PID means something on one Mac only (like the app, which kills a process on the Mac its list came from):
    /// the same number on the other Macs is some other process, e.g. a student's app with unsaved work.
    func kill() async -> Int32 {
        let use = "Użycie: cmcrctl kill PID nr [--force]"
        args.expect("kill", options: ["--force"], positional: 3)
        guard let raw = args[1], let pid = Int(raw), pid > 1 else { usageError(use) }
        let h = single(args[2], usage: use)
        let hard = force
        logAction([h])
        return await runScript(on: [h]) { _ in Scripts.killProcess(pid, force: hard) }
    }

    func uninstall() async -> Int32 {
        args.expect("uninstall", options: Self.parallel, positional: 3)
        guard let path = args[1] else { usageError("Użycie: cmcrctl uninstall /Applications/Nazwa.app KOMP") }
        let list = targets(args[2])
        confirm("Usunąć \(path) na: \(names(list))?")
        logAction(list)
        return await runScript(on: list) { _ in Scripts.uninstallApp(path) }
    }

    func brew() async -> Int32 {
        args.expect("brew", options: Self.parallel, positional: 3)
        guard let arguments = args[1], !arguments.trimmingCharacters(in: .whitespaces).isEmpty else {
            usageError("Użycie: cmcrctl brew \"argumenty\" KOMP, np. cmcrctl brew \"install --cask firefox\" all")
        }
        let list = targets(args[2])
        logAction(list)
        return await runScript(on: list) { _ in Scripts.brew(arguments) }
    }

    func screenshot() async -> Int32 {
        args.expect("screenshot", positional: 3)
        let h = single(args[1], usage: "Użycie: cmcrctl screenshot nr plik.jpg")
        guard let file = args[2] else { usageError("Użycie: cmcrctl screenshot nr plik.jpg") }
        let shot = await Operations.screenshot(of: h, maxSize: settings.screenshotMaxSize, settings: settings,
                                               notify: settings.notifyOnObserve, password: Keychain.password(for: h),
                                               sshSettings: sshSettings())
        // The actions log, as for the app's preview: whose screen was seen and whether the user was notified.
        let logPrefix = "Podgląd ekranu (cmcrctl screenshot) → \(h.name)"
        if case .notifyFailed(let user, let detail) = shot.issue {
            ConfigStore.log("\(logPrefix): nie udało się powiadomić użytkownika \(user) (\(detail)) – obraz nie jest pobierany")
        }
        if let user = shot.notifiedUser { ConfigStore.log("\(logPrefix): powiadomiono użytkownika \(user)") }
        guard let data = shot.imageData else { fail(shot.message ?? "Błąd") }
        ConfigStore.log("\(logPrefix) (użytkownik \(shot.user ?? "?"))")
        do {
            try data.write(to: URL(fileURLWithPath: expandTilde(file)))
        } catch {
            fail("Nie można zapisać \(file): \(error.localizedDescription)")
        }
        Console.out("Zapisano \(file) (\(data.count) B, użytkownik \(shot.user.map { TerminalText.escape($0) } ?? "?"))")
        return ExitCode.success
    }

    // MARK: - Updates

    func updates() async -> Int32 {
        let use = "Użycie: cmcrctl updates list|install|history KOMP"
        guard let sub = args[1] else { usageError(use) }
        switch sub {
        case "list":
            args.expect("updates list", options: Self.parallel, positional: 3)
            let list = targets(args[2])
            let ssh = sshSettings()
            let codes = await runHosts(list, jobs: args.jobs ?? max(1, settings.maxParallel), prefixLines: prefixLines) { io in
                let h = io.host
                let r = await SSH.run(Scripts.listUpdates(), on: h, password: Keychain.password(for: h), settings: ssh)
                guard r.succeeded else { return io.report(r) }
                switch Parsers.softwareUpdateCheck(r) {
                case .available(let titles):
                    io.out("\(h.name): \(plural(titles.count, "aktualizacja", "aktualizacje", "aktualizacji"))")
                    for t in titles { io.out("  • \(TerminalText.escape(t, keepBackslash: true))") }
                case .upToDate:
                    io.out("\(h.name): brak aktualizacji")
                case .failed:
                    // Same rule as the app: without "No new software available" the check did not succeed.
                    io.out("\(h.name): nie udało się sprawdzić aktualizacji, odpowiedź softwareupdate:")
                    for line in Parsers.lines(r.stdoutText) { io.out("  \(TerminalText.escape(line, keepBackslash: true))") }
                    return ExitCode.failure
                }
                return ExitCode.success
            }
            return combine(codes)
        case "install":
            args.expect("updates install",
                        options: Self.parallel.union(["--restart", "--download", "--recommended", "--major"]), positional: 3)
            let list = targets(args[2])
            let restart = args.has("--restart"), download = args.has("--download"), recommended = args.has("--recommended")
            // „Pozwól na nową wersję macOS” of the app: a new major version is installed only when asked for.
            let major = args.has("--major")
            if !download && (restart || major) {
                confirm("Zainstalować aktualizacje" + (major ? " razem z nową wersją macOS (przejście na nowy system)" : "")
                        + (restart ? " z ponownym uruchomieniem" : "") + " na: \(names(list))?"
                        + (restart ? " Zalogowani użytkownicy stracą niezapisane dane." : "")
                        + (major ? " Nowej wersji systemu nie da się potem cofnąć." : ""))
            }
            // The script names the app's switch; at the terminal the same choice is --major.
            let hint: @Sendable (Machine, CommandResult) -> String? = { _, r in
                r.stdoutText.contains("Pominięto przejście na nową wersję systemu")
                    ? "  (cmcrctl: dodaj --major, aby zainstalować także nową wersję macOS)" : nil
            }
            logAction(list)
            return await runScript(on: list, note: major ? nil : hint) { _ in
                Scripts.installUpdates(restart: restart, recommendedOnly: recommended, downloadOnly: download,
                                       allowMajorUpgrade: major)
            }
        case "history":
            args.expect("updates history", options: Self.parallel, positional: 3)
            let list = targets(args[2])
            return await runScript(on: list) { _ in Scripts.updateHistory() }
        default:
            usageError(use)
        }
    }

    // MARK: - Session & power

    func message() async -> Int32 {
        args.expect("message", options: Self.parallel.union(["--notification"]), positional: 4)
        guard let title = args[1], let text = args[2], !text.isEmpty else {
            usageError("Użycie: cmcrctl message \"tytuł\" \"treść\" KOMP [--notification]")
        }
        let list = targets(args[3])
        let dialog = !args.has("--notification")
        logAction(list)
        return await runScript(on: list) { _ in Scripts.message(title: title, text: text, asDialog: dialog) }
    }

    /// Like the app's „Wyloguj”: loginwindow is asked to log out and apps may ask to save (or cancel). `--force` is
    /// „Wyloguj natychmiast”: the sessions end at once (launchctl bootout), unsaved work is lost.
    func logout() async -> Int32 {
        args.expect("logout", options: Self.parallel.union(["--force"]), positional: 2)
        let list = targets(args[1])
        let now = force
        if now {
            confirm("Wylogować natychmiast użytkowników na: \(names(list))? Niezapisane dane przepadną.")
        } else {
            confirm("Poprosić o wylogowanie użytkowników na: \(names(list))? Aplikacje mogą zapytać o zapisanie zmian "
                    + "(albo wstrzymać wylogowanie).")
        }
        // When the request was refused or did not end every session, the script itself points to the app's „Wyloguj
        // natychmiast”; at the terminal that is --force. Not for a Mac that was not reached (off, asleep, unknown key,
        // wrong password, timeout): --force would fail the same way (AUDIT REV-38). The name is quoted for the shell.
        let hint: @Sendable (Machine, CommandResult) -> String? = { h, r in
            guard r.started, !r.cancelled, !r.timedOut, r.exitCode == 1, r.stderrText.contains("Wyloguj natychmiast") else {
                return nil
            }
            return "  (cmcrctl \(CommandLineLog.describe(["logout", h.name, "--force"])) – wylogowanie natychmiastowe, "
                + "niezapisane dane przepadną)"
        }
        logAction(list)
        return await runScript(on: list, note: now ? nil : hint) { _ in Scripts.logoutUser(force: now) }
    }

    func power() async -> Int32 {
        let actions: [String: PowerAction] = [
            "restart": .restart, "reboot": .restart, "shutdown": .shutdown, "sleep": .sleep,
            "display-sleep": .displaySleep, "displaysleep": .displaySleep,
        ]
        guard let name = args[1], let action = actions[name.lowercased()] else {
            usageError("Użycie: cmcrctl power restart|shutdown|sleep|display-sleep KOMP")
        }
        args.expect("power", options: Self.parallel, positional: 3)
        let list = targets(args[2])
        if action != .displaySleep {
            confirm("\(action.label): \(names(list))? Zalogowani użytkownicy mogą stracić niezapisane dane.")
        }
        logAction(list)
        return await runScript(on: list) { _ in Scripts.power(action) }
    }

    /// Wake-on-LAN as in the app: packets for the Ethernet MAC the Mac reported last (status-cache.json of the app),
    /// the MAC on the list and the default route's MAC, also to the broadcast of the subnet it was last seen in.
    /// `--wait`: every Mac at once waits (up to 3 min, resending) until it answers over SSH.
    func wake() async -> Int32 {
        args.expect("wake", options: ["--dry-run", "--wait"], positional: 2)
        let list = targets(args[1])
        let dryRun = args.has("--dry-run"), wait = args.has("--wait")
        if dryRun && wait { usageError("Opcja --wait nie działa z --dry-run (próba niczego nie wysyła).") }
        if !dryRun { logAction(list) }
        let snapshots = ClassroomStore.loadSnapshots()
        func target(_ h: Machine) -> LessonRunner.Host {
            let info = snapshots[h.id]?.info ?? [:]
            return LessonRunner.Host(machine: h, password: Keychain.password(for: h),
                                     macs: WakeOnLAN.candidateMACs(listed: h.macAddress, lastStatus: info),
                                     extraBroadcasts: WakeOnLAN.lastSeenBroadcasts(info))
        }
        /// Sends the packets for one Mac; the line to print and whether it worked.
        @Sendable func send(_ t: LessonRunner.Host) -> (String, Bool) {
            let h = t.machine
            guard !t.macs.isEmpty else {
                let why = h.macAddress.isEmpty ? "brak adresu MAC" : "niepoprawny adres MAC „\(h.macAddress)”"
                return ("✘ \(h.name): \(why) – uruchom „cmcrctl status”, gdy komputer jest włączony, lub ustaw: "
                        + "cmcrctl hosts set \(h.name) --mac aa:bb:cc:dd:ee:ff.", false)
            }
            let extra = t.extraBroadcasts.isEmpty ? "" : " (także na \(t.extraBroadcasts.joined(separator: ", ")))"
            if dryRun {
                return ("\(h.name): pakiet Wake-on-LAN dla \(t.macs.joined(separator: ", "))\(extra) (próba – nic nie wysłano)", true)
            }
            var sent: [String] = []
            var failure: String?
            for mac in t.macs {
                do {
                    try WakeOnLAN.wake(mac: mac, extraBroadcasts: t.extraBroadcasts)
                    sent.append(mac)
                } catch {
                    failure = error.localizedDescription
                }
            }
            guard !sent.isEmpty else { return ("✘ \(h.name): \(failure ?? "nie wysłano pakietu")", false) }
            return ("✔ \(h.name): wysłano pakiet Wake-on-LAN do \(sent.joined(separator: ", "))\(extra)", true)
        }
        var code = ExitCode.success
        if wait {
            // Packets first for every Mac, then all of them wait at once (a Mac without a MAC may still be on).
            let hosts = list.map(target)
            let ssh = sshSettings()
            let codes = await runHosts(list, jobs: max(1, list.count), prefixLines: false) { io in
                let t = hosts[io.index]
                if !t.macs.isEmpty {
                    let (line, ok) = send(t)
                    if ok { io.out(line) } else { io.err(line) }
                }
                switch await LessonRunner.wake(t, ssh: ssh, minutes: 3, handle: nil, onOutput: nil) {
                case .done(let s):
                    io.out("✔ \(t.machine.name): \(s)")
                    return ExitCode.success
                case .failed(let s), .skipped(let s):
                    io.err("✘ \(t.machine.name): \(s)")
                    return ExitCode.failure
                default:
                    return ExitCode.failure
                }
            }
            return combine(codes)
        }
        for h in list {
            let (line, ok) = send(target(h))
            if ok { Console.out(line) } else { Console.err(line) }
            if !ok { code = ExitCode.failure }
        }
        if code == ExitCode.success && !dryRun {
            Console.err("Wake-on-LAN działa przy połączeniu Ethernet i włączonej opcji „Budź przy dostępie do sieci”; "
                        + "--wait czeka, aż komputery odpowiedzą.")
        }
        return code
    }

    // MARK: - Self test

    func selftest() async -> Int32 {
        args.expect("selftest", positional: 1)
        let samples = ScriptCatalog.samples
        let problems = await ScriptCatalog.syntaxCheck(samples)
        for p in problems { Console.err("✘ \(p)") }
        guard problems.isEmpty else {
            Console.err("selftest: \(Polish.count(problems.count, "błąd", "błędy", "błędów")) składni w skryptach zdalnych.")
            return ExitCode.failure
        }
        Console.out("✔ selftest: \(Polish.count(samples.count, "skrypt", "skrypty", "skryptów")) (treść, tryb użytkownika i root) "
                    + "– składnia bash poprawna.")
        return ExitCode.success
    }
}

/// Per-host results collected from parallel tasks.
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CommandResult?]

    init(count: Int) { results = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ r: CommandResult) {
        lock.lock()
        results[index] = r
        lock.unlock()
    }

    func all() -> [CommandResult?] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}
