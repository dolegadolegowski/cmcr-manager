import CMCRCore
import Foundation

/// `cmcrctl setup-script`, `setup` and `readiness`: the one-time root configuration of the iMacs.
enum SetupCommands {
    static let names: Set<String> = ["setup-script", "setup", "readiness"]

    static let usage = """
      cmcrctl setup-script [opcje] > plik.sh    skrypt konfiguracyjny do uruchomienia przy iMacu: sudo bash plik.sh
      cmcrctl setup all|nr [opcje] [--verify]   skonfiguruj iMaki zdalnie jako root (jednorazowo); najpierw
                                                instaluje lub aktualizuje usługę podglądu ekranu
                                                (bez niej: --no-screen-agent)
      cmcrctl readiness [all|nr]                gotowość iMaców: klucz, sudo, folder, uprawnienia, FileVault…
    """

    private static func err(_ text: String) { Console.err(text) }
    private static func print(_ text: String, terminator: String = "\n") { Console.out(text, terminator: terminator) }
    private static let printer = Console.printer

    static func appPublicKey(_ settings: AppSettings) -> String? {
        SSHKeys.currentPrivateKey(settings: settings).flatMap { SSHKeys.publicKey(for: $0) }
    }

    static func run(_ command: String, _ args: [String], settings: AppSettings, ssh: SSHSettings) async -> Int32 {
        let select = ModuleHosts.readOnly
        if args.contains("--help") || args.contains("-h") {
            print(usage + "\n\n" + SetupCommandLine.optionsHelp)
            return 0
        }
        let cl: SetupCommandLine
        do {
            // readiness uses no setup option, so the options saved in the app do not matter to it: they must not
            // turn --no-key into advice to add a setup option that readiness then refuses (AUDIT REV-34).
            cl = command == "readiness" ? try SetupCommandLine(parsing: args, saved: SetupOptions())
                                        : try SetupCommandLine(parsing: args)
        } catch {
            err("✘ \(error.localizedDescription)\nPomoc: cmcrctl \(command) --help")
            return 2
        }
        // As every other command: a surplus argument or an option the command does not use is an error and nothing
        // runs (`setup --hostname imac07 3` would otherwise configure imac07; `setup 3 7` would skip imac07).
        let maxPositional = command == "setup-script" ? 0 : 1
        if cl.positional.count > maxPositional {
            err("✘ Nadmiarowy argument „\(cl.positional[maxPositional])” w poleceniu \(command). Nic nie zostało wykonane."
                + (command == "setup" ? " Kilka komputerów: lista po przecinku, np. 3,7 albo zakres 1-5." : "")
                + "\nPomoc: cmcrctl \(command) --help")
            return 2
        }
        if command == "setup-script", cl.mode != .apply {
            err("✘ Opcja --verify/--dry-run dotyczy polecenia setup. Przy iMacu sprawdź zapisany skrypt: sudo bash \(SetupScript.fileName) --verify\nPomoc: cmcrctl setup-script --help")
            return 2
        }
        // readiness takes only the key to look for (--pubkey, --pubkey-file); --no-key, --verify and --dry-run belong
        // to setup like the configuration options.
        if command == "readiness", let flag = cl.configurationFlags.first
            ?? (cl.mode == .verify ? "--verify" : cl.mode == .dryRun ? "--dry-run" : nil)
            ?? (cl.options.installKey ? nil : "--no-key") {
            err("✘ Polecenie readiness tylko sprawdza gotowość – opcja \(flag) dotyczy polecenia setup. Nic nie zostało wykonane.\nPomoc: cmcrctl readiness --help")
            return 2
        }
        let key = cl.publicKey ?? appPublicKey(settings)
        switch command {
        case "setup-script":
            if cl.options.installKey && key == nil {
                err("Uwaga: brak klucza SSH aplikacji (~/.ssh/id_ed25519.pub) – skrypt nie zainstaluje klucza.")
            }
            if let problem = SetupScript.sharedFolderProblem(settings) { err("Uwaga: \(problem)") }
            print(SetupScript.standalone(cl.options, settings: settings, publicKey: key), terminator: "")
            err("Skopiuj plik na iMaca i uruchom na koncie administratora: sudo bash \(SetupScript.fileName)")
            if cl.options.screenAgent {
                // The agent ships inside the app, not in the script (SetupOptions.screenAgent never reaches it). No
                // shell syntax in the text: `cmcrctl setup-script > plik.sh 2>&1` puts it at the end of the file.
                err("Usługi podglądu ekranu \(ScreenAgentInfo.displayName) skrypt z pliku nie instaluje – gdy iMac będzie "
                    + "dostępny zdalnie: cmcrctl screen-agent install KOMP")
            }
            return 0

        case "setup":
            guard let target = cl.positional.first else {
                err("Podaj all lub numer komputera, np.: cmcrctl setup 3 --verify")
                return 2
            }
            if let problem = SetupScript.sharedFolderProblem(settings) {
                err("✘ \(problem) Popraw folder w Konfiguracji.")
                return 2
            }
            var status: Int32 = 0
            let hosts = select(target)
            // CMCR Screen Agent ships inside the app, so cmcrctl installs it before the script, in the same run, as
            // „Skonfiguruj zaznaczone” does; --verify and --dry-run change nothing, so they install nothing.
            let withAgent = cl.options.screenAgent && cl.mode == .apply
            let agent = withAgent ? ScreenAgentLocator.bundledAgent() : nil
            if withAgent && agent == nil {
                err("Uwaga: \(ScreenAgentCLI.missingAgentText) Usługa podglądu zostanie pominięta, reszta konfiguracji się "
                    + "wykona (bez tej uwagi: --no-screen-agent).")
            }
            if cl.mode != .apply && cl.options.screenAgent {
                print("Usługa podglądu ekranu nie jest instalowana przy --verify/--dry-run – jej stan: cmcrctl screen-agent status.")
            }
            if cl.mode == .apply { logAction(hosts) }
            var notStarted: [Machine] = []
            for h in hosts {
                // After Ctrl-C the remaining Macs are left as they are (AUDIT REV-36).
                if Interruption.shared.isInterrupted {
                    notStarted.append(h)
                    status = ExitCode.failure
                    continue
                }
                let what = cl.mode == .apply ? "konfiguracja jako root" : "sprawdzanie konfiguracji (bez zmian)"
                print("══ \(h.name) (\(h.destination)): \(what)…")
                if cl.options.setHostname && SetupScript.hostname(for: h) == nil {
                    err("Uwaga: adres \(h.address) nie ma postaci nazwa.local – nazwa komputera \(h.name) zostanie bez zmian.")
                }
                if let agent {
                    print("→ usługa podglądu ekranu (\(ScreenAgentInfo.displayName) \(ScreenAgentInfo.version)): instalacja lub aktualizacja…")
                    // A registered job, like the script: Ctrl-C stops the upload or the installation on the iMac too.
                    let a = await Interruption.shared.job(on: h) { handle in
                        await Operations.installScreenAgent(on: h, agentApp: agent, password: Keychain.password(for: h),
                                                            settings: ssh, handle: handle, onOutput: printer)
                    }
                    if a.succeeded {
                        print("→ \(h.name): \(ScreenAgentCLI.installSummary(a.stdoutText, host: h))")
                        if ScreenAgentCLI.needsPermission(a.stdoutText) {
                            print("→ \(h.name): proszę o uprawnienie nagrywania ekranu (na iMacu pojawi się okno macOS)…")
                            let p = await Interruption.shared.job(on: h) { handle in
                                await Operations.requestScreenAgentPermission(on: h, password: Keychain.password(for: h),
                                                                              settings: ssh, handle: handle, onOutput: printer)
                            }
                            if !p.succeeded && !p.cancelled {
                                err("  Nie udało się poprosić o uprawnienie: \(SSH.diagnose(p).1) Później: cmcrctl screen-agent permission \(h.name)")
                            }
                        }
                    } else {
                        let (reach, message) = SSH.diagnose(a)
                        err("✘ \(h.name): usługa podglądu: \(message)")
                        status = ExitCode.failure
                        // Stopped, or the Mac was not reached at all: the script would fail the same way.
                        if a.cancelled || Interruption.shared.isInterrupted || reach != .online { continue }
                        err("  Skrypt konfiguracyjny zostanie uruchomiony mimo to.")
                    }
                }
                let script = SetupScript.remote(cl.options, host: h, settings: settings, publicKey: key, mode: cl.mode)
                // A registered job: Ctrl-C stops the configuration on the iMac too (Interruption).
                let r = await Interruption.shared.run(script, on: h, password: Keychain.password(for: h), settings: ssh,
                                                      onOutput: printer)
                if let report = SetupReport.parse(r.stdoutText) {
                    print("→ \(h.name): \(report.summary)")
                } else if !r.succeeded {
                    err("✘ \(h.name): \(SSH.diagnose(r).1)")
                }
                if !r.succeeded { status = ExitCode.failure }
            }
            Interruption.shared.reportNotStarted(notStarted)
            return status

        default:
            let student = settings.studentUser
            let folder = settings.studentFolder
            var status: Int32 = 0
            for h in select(cl.positional.first) {
                let r = await SSH.run(Scripts.readiness(student: student, sharedFolder: folder, publicKey: key),
                                      on: h, password: Keychain.password(for: h), settings: ssh, timeout: 60)
                let report = r.succeeded
                    ? ReadinessReport.parse(r.stdoutText, student: student, sharedFolder: folder)
                    : ReadinessReport.unreachable(r)
                if !r.succeeded || !report.isReady { status = 1 }
                print("\(report.isReady ? "●" : "○") \(h.name)\(report.isReady ? " – gotowy" : "")")
                for c in ReadinessCheck.allCases {
                    let item = report[c]
                    let pad = String(repeating: " ", count: max(1, 24 - c.title.count))
                    print("   \(symbol(item.state)) \(c.title)\(pad)\(item.short)")
                    if item.state != .ok && item.state != .off { print("        \(item.detail)") }
                }
            }
            return status
        }
    }

    static func symbol(_ s: ReadinessState) -> String {
        switch s {
        case .ok: return "✔"
        case .off: return "–"
        case .unknown: return "?"
        case .manual: return "☐"
        case .warning: return "⚠︎"
        case .problem: return "✘"
        }
    }
}
