import CMCRCore
import Foundation

let usage = """
cmcrctl – zarządzanie iMacami z terminala (odpowiednik cmcr-helpers.sh)

Użycie: cmcrctl POLECENIE [argumenty] [opcje]

KOMP – wybór komputerów: all | numer z nazwy (4 → imac04) | lista (1,3,7) | zakres (1-5)
       | pozycja na liście (#2) | nazwa, adres lub konto (imac04, imac04.local).
Bez KOMP polecenia status, exec, open-app i quit-app działają na wszystkich komputerach.

Stan i polecenia
  list                                     lista komputerów
  status [KOMP] [--json]                   stan komputerów (równolegle); zapamiętuje adresy MAC
  exec "polecenie" [KOMP] [--root]         cmcr-exec: wykonaj polecenie
  go nr                                    cmcr-go: interaktywna sesja ssh
  render "polecenie" [--root]              pokaż skrypt wykonywany zdalnie

Pliki
  push KOMP [--root]                       cmcr-push: ~/Public/cmcr/{all,<host>}/* → folder ucznia
  pull KOMP [--root]                       cmcr-pull: folder ucznia → ~/Public/cmcr/<host>
  ls ŚCIEŻKA KOMP [--root]                 zawartość folderu ({console} = zalogowany użytkownik)
  clean ŚCIEŻKA KOMP                       usuń zawartość folderu (/Users/<konto>/…, /tmp, /Volumes)

Aplikacje
  apps nr                                  uruchomione aplikacje użytkownika
  open-app "Nazwa" [KOMP]                  uruchom aplikację u zalogowanego użytkownika
  quit-app "Nazwa" [KOMP] [--force]        zamknij aplikację (--force: natychmiast)
  open-url ADRES KOMP                      otwórz stronę lub plik u zalogowanego użytkownika
  kill PID KOMP [--force]                  zakończ proces (--force: SIGKILL)
  uninstall /Applications/X.app KOMP       usuń aplikację
  brew "argumenty" KOMP                    Homebrew, np.: cmcrctl brew "install --cask firefox" all
  screenshot nr plik.jpg                   zrzut ekranu zalogowanego użytkownika

Aktualizacje macOS
  updates list KOMP                        dostępne aktualizacje (równolegle)
  updates install KOMP [--restart] [--download] [--recommended]
                                           instalacja (--restart: z ponownym uruchomieniem,
                                           --download: tylko pobierz, --recommended: tylko zalecane)
  updates history KOMP                     historia instalacji

Sesja i zasilanie
  message "tytuł" "treść" KOMP [--notification]   okno z wiadomością (lub powiadomienie)
  logout KOMP                              wyloguj zalogowanego użytkownika
  power restart|shutdown|sleep|display-sleep KOMP
                                           uruchom ponownie | wyłącz | uśpij | uśpij ekran
  wake KOMP [--dry-run]                    obudź przez sieć (Wake-on-LAN, wymaga adresu MAC)

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
  selftest                                 sprawdź składnię wszystkich skryptów zdalnych (bash -n)

Opcje
  -j N, --jobs N    ile komputerów obsługiwać naraz (domyślnie 1; status i updates list: \(AppSettings().maxParallel)
                    lub „Równoległe operacje” z ustawień); wyniki zawsze w kolejności listy
  --prefix          poprzedź każdy wiersz wyniku nazwą komputera, np. [imac04]
  --root            wykonaj jako root (sudo z hasłem administratora)
  --yes, -y         nie pytaj o potwierdzenie (wymagane bez terminala dla restartu, wylogowania, usuwania)
  --                koniec opcji – dalsze argumenty dosłownie

Kody wyjścia: 0 – sukces, 1 – błąd na co najmniej jednym komputerze, 2 – błędne użycie (także opcja,
której polecenie nie używa, lub nadmiarowy argument – wtedy nic nie jest wykonywane);
exec zwraca kod zdalnego polecenia (najwyższy z kilku komputerów).

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

    var root: Bool { args.has("--root") }
    var force: Bool { args.has("--force") }
    var prefixLines: Bool { args.has("--prefix") }

    func run() async -> Int32 {
        guard let command = args[0] else {
            Console.out(usage)
            return ExitCode.success
        }
        if args.has("--help") || args.has("-h") || command == "help" {
            Console.out(usage)
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
        case "wake": return wake()
        case "hosts": return hostsCommand()
        case "password": return password()
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

    func single(_ spec: String?, usage text: String) -> Machine {
        guard let spec else { usageError(text) }
        let found = targets(spec)
        guard found.count == 1 else {
            usageError("Podaj jeden komputer (pasuje \(found.count): \(found.map(\.name).joined(separator: ", "))).")
        }
        return found[0]
    }

    /// Asks before disruptive actions. Without a terminal `--yes` is required, so scripts never hang.
    func confirm(_ question: String) {
        if args.yes { return }
        guard isatty(STDIN_FILENO) != 0 else {
            usageError("\(question)\nTo polecenie wymaga potwierdzenia – dodaj --yes.")
        }
        Console.err("\(question) Kontynuować? [t/N] ", terminator: "")
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard ["t", "tak", "y", "yes"].contains(answer) else { fail("Przerwano.") }
    }

    func names(_ list: [Machine]) -> String {
        let shown = list.prefix(8).map(\.name).joined(separator: ", ")
        return (list.count > 8 ? shown + " …" : shown) + " (\(plural(list.count, "komputer", "komputery", "komputerów")))"
    }

    func header(_ host: Machine) -> String { "== \(host.name) (\(host.destination)) ==" }

    /// Streams one remote script per host under a header; the common shape of most commands.
    func runScript(on list: [Machine], jobs: Int? = nil, passThrough: Bool = false,
                   header makeHeader: (@Sendable (Machine) -> String)? = nil,
                   _ script: @escaping @Sendable (Machine) -> RemoteScript) async -> Int32 {
        let ssh = sshSettings()
        let defaultHeader = header
        let codes = await runHosts(list, jobs: jobs ?? args.jobs ?? 1, prefixLines: prefixLines) { io in
            io.out(makeHeader?(io.host) ?? defaultHeader(io.host))
            let r = await SSH.run(script(io.host), on: io.host, password: Keychain.password(for: io.host),
                                  settings: ssh, onOutput: io.stream)
            return io.report(r, passThrough: passThrough)
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
        args.expect("status", options: ["-j", "--json"], positional: 2)
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
                let kv = Parsers.keyValues(r.stdoutText)
                let user = kv["console"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                io.out("● \(h.name): macOS \(kv["os"] ?? "?") \(kv["model"] ?? "") użytkownik: \(user) IP \(kv["ip"] ?? "?")")
                return ExitCode.success
            }
            io.out("○ \(h.name): \(SSH.diagnose(r).1)")
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

    /// Like the app: a MAC address reported by a running Mac is stored for Wake-on-LAN when none is set.
    func rememberMACs(_ list: [Machine], _ results: [CommandResult?], quiet: Bool) {
        var learned: [(host: Machine, mac: String)] = []
        for (h, r) in zip(list, results) where h.macAddress.isEmpty {
            guard let r, r.succeeded, let mac = Parsers.keyValues(r.stdoutText)["mac"], WakeOnLAN.parseMAC(mac) != nil
            else { continue }
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
        ConfigStore.saveHosts(current)
        if !quiet { Console.err("Zapisano adres MAC (Wake-on-LAN): \(updated.joined(separator: ", "))") }
    }

    func exec() async -> Int32 {
        args.expect("exec", options: Self.parallel.union(["--root"]), positional: 3)
        guard let command = args[1] else { usageError("Podaj polecenie.") }
        let list = targets(args[2], defaultAll: true)
        let asRoot = root
        return await runScript(on: list, passThrough: true, header: { "Running command on \($0.destination) ..." }) { _ in
            RemoteScript(command, asRoot: asRoot)
        }
    }

    func go() -> Never {
        args.expect("go", positional: 2)
        let h = single(args[1], usage: "Podaj numer komputera.")
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
        let codes = await runHosts(list, jobs: args.jobs ?? 1, prefixLines: prefixLines) { io in
            let h = io.host
            let items = Operations.conventionItems(base: s.localFolder, host: h)
            io.out("Pushing to \(h.destination) ... (\(plural(items.count, "element", "elementy", "elementów")))")
            if items.isEmpty { return ExitCode.success }
            switch await Payload.make(items) {
            case .failure(let e):
                io.err("✘ \(h.name): \(e.localizedDescription)")
                return ExitCode.failure
            case .success(let payload):
                defer { try? FileManager.default.removeItem(at: payload) }
                let r = await Operations.push(payload: payload, to: h, destination: s.sharedFolder,
                                              owner: asRoot ? s.studentUser : "", mode: "777", asRoot: asRoot,
                                              password: Keychain.password(for: h), settings: ssh, onOutput: io.stream)
                return io.report(r)
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
        let codes = await runHosts(list, jobs: args.jobs ?? 1, prefixLines: prefixLines) { io in
            let h = io.host
            io.out("Pulling from \(h.destination) ...")
            let dest = URL(fileURLWithPath: expandTilde(s.localFolder)).appendingPathComponent(h.folderKey)
            let r = await Operations.pull(source: s.sharedFolder, from: h, into: dest, asRoot: asRoot,
                                          password: Keychain.password(for: h), settings: ssh, onOutput: io.stream)
            return io.report(r)
        }
        return combine(codes)
    }

    func listFolder() async -> Int32 {
        args.expect("ls", options: Self.parallel.union(["--root"]), positional: 3)
        guard let path = args[1] else { usageError("Użycie: cmcrctl ls ŚCIEŻKA KOMP [--root]") }
        let list = targets(args[2])
        let asRoot = root
        return await runScript(on: list) { _ in Scripts.listFolder(path, asRoot: asRoot) }
    }

    func clean() async -> Int32 {
        args.expect("clean", options: Self.parallel, positional: 3)
        guard let path = args[1] else { usageError("Użycie: cmcrctl clean ŚCIEŻKA KOMP") }
        let list = targets(args[2])
        confirm("Usunąć całą zawartość folderu \(path) na: \(names(list))?")
        return await runScript(on: list) { _ in Scripts.cleanFolder(path) }
    }

    // MARK: - Applications

    func apps() async -> Int32 {
        args.expect("apps", positional: 2)
        let h = single(args[1], usage: "Podaj numer komputera.")
        let r = await SSH.run(Scripts.runningApps(), on: h, password: Keychain.password(for: h), settings: sshSettings())
        let parsed = Parsers.runningApps(r.stdoutText)
        Console.out("Użytkownik: \(parsed.user ?? "—")")
        for app in parsed.apps { Console.out(String(format: "%7ld  %@", app.pid, app.bundlePath as NSString)) }
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
        let list = targets(args[2], defaultAll: true)
        let hard = force
        return await runScript(on: list, header: { "\($0.name):" }) { _ in
            open ? Scripts.launchApp(app) : Scripts.quitApp(app, force: hard)
        }
    }

    func openURL() async -> Int32 {
        args.expect("open-url", options: Self.parallel, positional: 3)
        guard let url = args[1] else { usageError("Użycie: cmcrctl open-url ADRES KOMP") }
        let list = targets(args[2])
        return await runScript(on: list) { _ in Scripts.openURL(url) }
    }

    func kill() async -> Int32 {
        args.expect("kill", options: Self.parallel.union(["--force"]), positional: 3)
        guard let raw = args[1], let pid = Int(raw), pid > 1 else { usageError("Użycie: cmcrctl kill PID KOMP [--force]") }
        let list = targets(args[2])
        let hard = force
        return await runScript(on: list) { _ in Scripts.killProcess(pid, force: hard) }
    }

    func uninstall() async -> Int32 {
        args.expect("uninstall", options: Self.parallel, positional: 3)
        guard let path = args[1] else { usageError("Użycie: cmcrctl uninstall /Applications/Nazwa.app KOMP") }
        let list = targets(args[2])
        confirm("Usunąć \(path) na: \(names(list))?")
        return await runScript(on: list) { _ in Scripts.uninstallApp(path) }
    }

    func brew() async -> Int32 {
        args.expect("brew", options: Self.parallel, positional: 3)
        guard let arguments = args[1], !arguments.trimmingCharacters(in: .whitespaces).isEmpty else {
            usageError("Użycie: cmcrctl brew \"argumenty\" KOMP, np. cmcrctl brew \"install --cask firefox\" all")
        }
        let list = targets(args[2])
        return await runScript(on: list) { _ in Scripts.brew(arguments) }
    }

    func screenshot() async -> Int32 {
        args.expect("screenshot", positional: 3)
        let h = single(args[1], usage: "Użycie: cmcrctl screenshot nr plik.jpg")
        guard let file = args[2] else { usageError("Użycie: cmcrctl screenshot nr plik.jpg") }
        let shot = await Operations.screenshot(of: h, maxSize: settings.screenshotMaxSize, settings: settings,
                                               notify: settings.notifyOnObserve, password: Keychain.password(for: h),
                                               sshSettings: sshSettings())
        guard let data = shot.imageData else { fail(shot.message ?? "Błąd") }
        do {
            try data.write(to: URL(fileURLWithPath: expandTilde(file)))
        } catch {
            fail("Nie można zapisać \(file): \(error.localizedDescription)")
        }
        Console.out("Zapisano \(file) (\(data.count) B, użytkownik \(shot.user ?? "?"))")
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
                let titles = Parsers.softwareUpdates(r.stdoutText)
                if !titles.isEmpty {
                    io.out("\(h.name): \(plural(titles.count, "aktualizacja", "aktualizacje", "aktualizacji"))")
                    for t in titles { io.out("  • \(t)") }
                } else if r.stdoutText.contains("No new software available") {
                    io.out("\(h.name): brak aktualizacji")
                } else {
                    io.out("\(h.name): brak rozpoznanych aktualizacji, odpowiedź softwareupdate:")
                    for line in Parsers.lines(r.stdoutText) { io.out("  \(line)") }
                }
                return ExitCode.success
            }
            return combine(codes)
        case "install":
            args.expect("updates install", options: Self.parallel.union(["--restart", "--download", "--recommended"]),
                        positional: 3)
            let list = targets(args[2])
            let restart = args.has("--restart"), download = args.has("--download"), recommended = args.has("--recommended")
            if restart && !download {
                confirm("Zainstalować aktualizacje z ponownym uruchomieniem na: \(names(list))? Zalogowani użytkownicy stracą niezapisane dane.")
            }
            return await runScript(on: list) { _ in
                Scripts.installUpdates(restart: restart, recommendedOnly: recommended, downloadOnly: download)
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
        return await runScript(on: list) { _ in Scripts.message(title: title, text: text, asDialog: dialog) }
    }

    func logout() async -> Int32 {
        args.expect("logout", options: Self.parallel, positional: 2)
        let list = targets(args[1])
        confirm("Wylogować użytkowników na: \(names(list))? Niezapisane dane przepadną.")
        return await runScript(on: list) { _ in Scripts.logoutUser() }
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
        return await runScript(on: list) { _ in Scripts.power(action) }
    }

    func wake() -> Int32 {
        args.expect("wake", options: ["--dry-run"], positional: 2)
        let list = targets(args[1])
        let dryRun = args.has("--dry-run")
        var code = ExitCode.success
        for h in list {
            guard !h.macAddress.isEmpty else {
                Console.err("✘ \(h.name): brak adresu MAC – uruchom „cmcrctl status”, gdy komputer jest włączony, lub ustaw: cmcrctl hosts set \(h.name) --mac aa:bb:cc:dd:ee:ff.")
                code = ExitCode.failure
                continue
            }
            guard let bytes = WakeOnLAN.parseMAC(h.macAddress) else {
                Console.err("✘ \(h.name): niepoprawny adres MAC „\(h.macAddress)”.")
                code = ExitCode.failure
                continue
            }
            let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            if dryRun {
                Console.out("\(h.name): pakiet Wake-on-LAN dla \(mac) (próba – nic nie wysłano)")
                continue
            }
            do {
                for _ in 0..<3 { try WakeOnLAN.wake(mac: h.macAddress) }
                Console.out("✔ \(h.name): wysłano pakiet Wake-on-LAN do \(mac)")
            } catch {
                Console.err("✘ \(h.name): \(error.localizedDescription)")
                code = ExitCode.failure
            }
        }
        if code == ExitCode.success && !dryRun {
            Console.err("Wake-on-LAN działa przy połączeniu Ethernet i włączonej opcji „Budź przy dostępie do sieci”.")
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
            Console.err("selftest: \(problems.count) błędów składni w skryptach zdalnych.")
            return ExitCode.failure
        }
        Console.out("✔ selftest: \(samples.count) skryptów (treść, tryb użytkownika i root) – składnia bash poprawna.")
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
