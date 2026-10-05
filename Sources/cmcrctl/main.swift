import CMCRCore
import Foundation

// Command line counterpart of cmcr-helpers.sh, sharing configuration with the CMCR Manager app.

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IONBF, 0)

let usage = """
cmcrctl – zarządzanie iMacami z terminala (odpowiednik cmcr-helpers.sh)

Użycie:
  cmcrctl list                              lista komputerów
  cmcrctl status [all|nr|nazwa]             stan komputerów
  cmcrctl exec "polecenie" [all|nr] [--root]   cmcr-exec: wykonaj polecenie
  cmcrctl go nr                             cmcr-go: interaktywna sesja ssh
  cmcrctl push all|nr [--root]              cmcr-push: ~/Public/cmcr/{all,<host>}/* → folder ucznia
  cmcrctl pull all|nr [--root]              cmcr-pull: folder ucznia → ~/Public/cmcr/<host>
  cmcrctl apps nr                           uruchomione aplikacje użytkownika
  cmcrctl screenshot nr plik.jpg            zrzut ekranu zalogowanego użytkownika
  cmcrctl open-app "Nazwa" [all|nr]         uruchom aplikację u zalogowanego użytkownika
  cmcrctl quit-app "Nazwa" [all|nr] [--force]  zamknij aplikację
  cmcrctl render "polecenie" [--root]       pokaż skrypt wykonywany zdalnie

Konfiguracja: \(ConfigStore.directory.path)
Hasło administratora: Pęk kluczy (ustawiane w aplikacji) lub zmienna CMCR_PASSWORD.
"""

let settings = ConfigStore.loadSettings()
let hosts = ConfigStore.loadHosts()
for issue in ConfigStore.loadIssues { FileHandle.standardError.write(Data("⚠ \(issue)\n".utf8)) }
let sshSettings = SSHSettings(settings, askpassPath: ConfigStore.ensureAskpass())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func selectHosts(_ spec: String?) -> [Machine] {
    guard let spec, spec != "all" else { return hosts }
    if let n = Int(spec) {
        let matched = hosts.filter { $0.number == n }
        if !matched.isEmpty { return matched }
        if n >= 1 && n <= hosts.count { return [hosts[n - 1]] }
    }
    let matched = hosts.filter { $0.name == spec || $0.address == spec || $0.user == spec }
    if matched.isEmpty { fail("Connection \(spec) not found.") }
    return matched
}

enum Console {
    static let printer: Operations.Output = { channel, data in
        (channel == .stdout ? FileHandle.standardOutput : FileHandle.standardError).write(data)
    }
}

func report(_ r: CommandResult) -> Int32 {
    if !r.succeeded {
        let (_, message) = SSH.diagnose(r)
        FileHandle.standardError.write(Data("✘ \(message)\n".utf8))
    }
    return r.succeeded ? 0 : (r.exitCode == 0 ? 1 : r.exitCode)
}

var args = Array(CommandLine.arguments.dropFirst())
let root = args.contains("--root")
let force = args.contains("--force")
args.removeAll { $0 == "--root" || $0 == "--force" }

guard let command = args.first else {
    print(usage)
    exit(0)
}

var status: Int32 = 0
switch command {
case "list":
    for (i, h) in hosts.enumerated() {
        print(String(format: "%2d  %-12@ %-24@ %@", i + 1, h.name as NSString, h.destination as NSString,
                     (h.port == 22 ? "" : "port \(h.port)") as NSString))
    }

case "render":
    // Prints the exact script that would be executed on the remote Mac.
    guard args.count > 1 else { fail("Podaj polecenie.") }
    print(RemoteScript(args[1], asRoot: root).render(), terminator: "")

case "status":
    for h in selectHosts(args.count > 1 ? args[1] : nil) {
        let r = await SSH.run(Scripts.status(), on: h, password: Keychain.password(for: h), settings: sshSettings, timeout: 30)
        if r.succeeded {
            let kv = Parsers.keyValues(r.stdoutText)
            print("● \(h.name): macOS \(kv["os"] ?? "?") \(kv["model"] ?? "") użytkownik: \(kv["console"].flatMap { $0.isEmpty ? nil : $0 } ?? "—") IP \(kv["ip"] ?? "?")")
        } else {
            print("○ \(h.name): \(SSH.diagnose(r).1)")
            status = 1
        }
    }

case "exec":
    guard args.count > 1 else { fail("Podaj polecenie.") }
    for h in selectHosts(args.count > 2 ? args[2] : nil) {
        print("Running command on \(h.destination) ...")
        let r = await SSH.run(RemoteScript(args[1], asRoot: root), on: h, password: Keychain.password(for: h),
                              settings: sshSettings, onOutput: Console.printer)
        status = max(status, report(r))
    }

case "go":
    guard args.count > 1, let h = selectHosts(args[1]).first else { fail("Podaj numer komputera.") }
    let argv = ["ssh"] + SSH.interactiveArguments(for: h, settings: sshSettings)
    let cargs = argv.map { strdup($0) } + [nil]
    execv(SSH.sshPath, cargs)
    fail("Nie można uruchomić ssh.")

case "push":
    guard args.count > 1 else { fail("Podaj all lub numer komputera.") }
    for h in selectHosts(args[1]) {
        let items = Operations.conventionItems(base: settings.localFolder, host: h)
        print("Pushing to \(h.destination) ... (\(items.count) elementów)")
        if items.isEmpty { continue }
        switch await Payload.make(items) {
        case .failure(let e): fail(e.localizedDescription)
        case .success(let payload):
            let r = await Operations.push(payload: payload, to: h, destination: settings.sharedFolder,
                                          owner: root ? settings.studentUser : "", mode: "777", asRoot: root,
                                          password: Keychain.password(for: h), settings: sshSettings, onOutput: Console.printer)
            try? FileManager.default.removeItem(at: payload)
            status = max(status, report(r))
        }
    }

case "pull":
    guard args.count > 1 else { fail("Podaj all lub numer komputera.") }
    for h in selectHosts(args[1]) {
        print("Pulling from \(h.destination) ...")
        let dest = URL(fileURLWithPath: expandTilde(settings.localFolder)).appendingPathComponent(h.folderKey)
        let r = await Operations.pull(source: settings.sharedFolder, from: h, into: dest, asRoot: root,
                                      password: Keychain.password(for: h), settings: sshSettings, onOutput: Console.printer)
        status = max(status, report(r))
    }

case "apps":
    guard args.count > 1, let h = selectHosts(args[1]).first else { fail("Podaj numer komputera.") }
    let r = await SSH.run(Scripts.runningApps(), on: h, password: Keychain.password(for: h), settings: sshSettings)
    let parsed = Parsers.runningApps(r.stdoutText)
    print("Użytkownik: \(parsed.user ?? "—")")
    for app in parsed.apps { print(String(format: "%7d  %@", app.pid, app.bundlePath as NSString)) }
    status = report(r)

case "screenshot":
    guard args.count > 2, let h = selectHosts(args[1]).first else { fail("Użycie: cmcrctl screenshot nr plik.jpg") }
    let shot = await Operations.screenshot(of: h, maxSize: settings.screenshotMaxSize, settings: settings,
                                           notify: settings.notifyOnObserve, password: Keychain.password(for: h),
                                           sshSettings: sshSettings)
    if let data = shot.imageData {
        try data.write(to: URL(fileURLWithPath: expandTilde(args[2])))
        print("Zapisano \(args[2]) (\(data.count) B, użytkownik \(shot.user ?? "?"))")
    } else {
        fail(shot.message ?? "Błąd")
    }

case "open-app", "quit-app":
    guard args.count > 1 else { fail("Podaj nazwę aplikacji.") }
    for h in selectHosts(args.count > 2 ? args[2] : nil) {
        let script = command == "open-app" ? Scripts.launchApp(args[1]) : Scripts.quitApp(args[1], force: force)
        print("\(h.name):")
        let r = await SSH.run(script, on: h, password: Keychain.password(for: h), settings: sshSettings, onOutput: Console.printer)
        status = max(status, report(r))
    }

case "__run-job", "__forget-host-key":
    status = await HiddenCommands.run(command, Array(args.dropFirst()), select: selectHosts, root: root, settings: sshSettings)

default:
    print(usage)
    status = 2
}
exit(status)
