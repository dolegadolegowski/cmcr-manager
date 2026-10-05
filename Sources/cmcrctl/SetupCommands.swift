import CMCRCore
import Foundation

/// `cmcrctl setup-script`, `setup` and `readiness`: the one-time root configuration of the iMacs.
enum SetupCommands {
    static let names: Set<String> = ["setup-script", "setup", "readiness"]

    static let usage = """
      cmcrctl setup-script [opcje] > plik.sh    skrypt konfiguracyjny do uruchomienia przy iMacu: sudo bash plik.sh
      cmcrctl setup all|nr [opcje] [--verify]   skonfiguruj iMaki zdalnie jako root (jednorazowo)
      cmcrctl readiness [all|nr]                gotowość iMaców: klucz, sudo, folder, uprawnienia, FileVault…
    """

    private static func err(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static let printer: Operations.Output = { channel, data in
        (channel == .stdout ? FileHandle.standardOutput : FileHandle.standardError).write(data)
    }

    static func appPublicKey(_ settings: AppSettings) -> String? {
        SSHKeys.currentPrivateKey(settings: settings).flatMap { SSHKeys.publicKey(for: $0) }
    }

    static func run(_ command: String, _ args: [String], select: (String?) -> [Machine],
                    settings: AppSettings, ssh: SSHSettings) async -> Int32 {
        if args.contains("--help") || args.contains("-h") {
            print(usage + "\n\n" + SetupCommandLine.optionsHelp)
            return 0
        }
        let cl: SetupCommandLine
        do {
            cl = try SetupCommandLine(parsing: args)
        } catch {
            err("✘ \(error.localizedDescription)\nPomoc: cmcrctl \(command) --help")
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
            for h in select(target) {
                let what = cl.mode == .apply ? "konfiguracja jako root" : "sprawdzanie konfiguracji (bez zmian)"
                print("══ \(h.name) (\(h.destination)): \(what)…")
                if cl.options.setHostname && SetupScript.hostname(for: h) == nil {
                    err("Uwaga: adres \(h.address) nie ma postaci nazwa.local – nazwa komputera \(h.name) zostanie bez zmian.")
                }
                let script = SetupScript.remote(cl.options, host: h, settings: settings, publicKey: key, mode: cl.mode)
                let r = await SSH.run(script, on: h, password: Keychain.password(for: h), settings: ssh, onOutput: printer)
                if let report = SetupReport.parse(r.stdoutText) {
                    print("→ \(h.name): \(report.summary)")
                } else if !r.succeeded {
                    err("✘ \(h.name): \(SSH.diagnose(r).1)")
                }
                let code: Int32 = r.succeeded ? 0 : (r.exitCode == 0 ? 1 : r.exitCode)
                status = max(status, code)
            }
            return status

        default:
            let student = settings.studentUser
            let folder = settings.resolve(settings.sharedFolder)
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
