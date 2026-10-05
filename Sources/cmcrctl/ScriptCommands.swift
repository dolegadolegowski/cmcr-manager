import CMCRCore
import Foundation

/// `install` / `install-url`, plus `_builder`: a hidden hook that runs one remote script builder with
/// explicit parameters, used by the end-to-end tests (Tests/e2e/suites/scripts.sh).
@MainActor
enum ScriptCommands {
    nonisolated static let usage = """
      cmcrctl install plik… KOMP [--allow-unsigned]
                                                zainstaluj programy (.pkg/.dmg/.zip/.app) jako root; bez
                                                --allow-unsigned tylko z ważnym podpisem i notaryzacją Apple
      cmcrctl install-url https://… KOMP [--sha256 SUMA] [--allow-unsigned]
                                                pobierz instalator na iMacu (tylko https) i zainstaluj
    """

    /// `--root` is accepted for compatibility: installing always runs as root.
    nonisolated static let specs: [String: ModuleSpec] = [
        "install": ModuleSpec(flags: ["--root", "--allow-unsigned"], parallel: true),
        "install-url": ModuleSpec(flags: ["--root", "--allow-unsigned"], values: ["--sha256"], maxPositional: 2, parallel: true),
    ]

    /// Exit status, or nil when `command` is not one of these (`args` without the command word).
    static func run(_ command: String, _ args: [String]) async -> Int32? {
        guard let spec = specs[command] else { return nil }
        let a = ModuleArguments.parse(command, args, spec)
        return command == "install" ? await install(a) : await installURL(a)
    }

    static func install(_ a: ModuleArguments) async -> Int32 {
        var files = a.positional
        var spec: String?
        // The host list comes last; a last argument that is not a local file is taken as the host list.
        if files.count >= 2, let last = files.last, !FileManager.default.fileExists(atPath: expandTilde(last)) {
            spec = last
            files.removeLast()
        }
        guard !files.isEmpty else { moduleUsageError(a.command, "Użycie: cmcrctl install plik… KOMP [--allow-unsigned]") }
        let urls = files.map { URL(fileURLWithPath: expandTilde($0)).standardizedFileURL }
        for u in urls where !FileManager.default.fileExists(atPath: u.path) {
            moduleUsageError(a.command, "Brak pliku: \(u.path)")
        }
        let targets = ModuleHosts.changing(spec, a.command)
        let payload: URL
        switch await Payload.make(urls) {
        case .failure(let e): fail(e.localizedDescription)
        case .success(let url): payload = url
        }
        defer { try? FileManager.default.removeItem(at: payload) }
        let ssh = sshSettings
        let allowUnsigned = a.has("--allow-unsigned")
        return await eachHost(targets, a) { io in
            let r = await Operations.install(payload: payload, on: io.host, allowUnsigned: allowUnsigned,
                                             password: Keychain.password(for: io.host), settings: ssh, onOutput: io.stream)
            return io.report(r)
        }
    }

    static func installURL(_ a: ModuleArguments) async -> Int32 {
        guard let url = a[0], url.contains("://") else {
            moduleUsageError(a.command, "Użycie: cmcrctl install-url https://… KOMP [--sha256 SUMA] [--allow-unsigned]")
        }
        guard Scripts.isSecureDownloadURL(url) else {
            moduleUsageError(a.command, "Dozwolone są tylko adresy https:// (lub file://) – przez http:// ktoś w sieci "
                             + "szkolnej mógłby podmienić instalator.")
        }
        let sha256: String? = a.value("--sha256").map { raw in
            guard let hex = Scripts.normalizedSHA256(raw) else {
                moduleUsageError(a.command, "--sha256: oczekiwano 64 znaków szesnastkowych (suma SHA-256), podano „\(raw)”.")
            }
            return hex
        }
        let allowUnsigned = a.has("--allow-unsigned")
        let targets = ModuleHosts.changing(a[1], a.command)
        return await runEach(targets, a, ssh: sshSettings) { _ in
            Scripts.installFromURL(url, sha256: sha256, allowUnsigned: allowUnsigned)
        }
    }

    /// `_builder` only: the remote exit code is kept, the e2e suites check the codes of the script builders.
    static func runRaw(_ script: RemoteScript, _ spec: String) async -> Int32 {
        var status: Int32 = 0
        for h in legacyCLI.targets(spec) {
            Console.out("\(h.name):")
            let r = await SSH.run(script, on: h, password: Keychain.password(for: h), settings: sshSettings,
                                  onOutput: Console.printer)
            status = max(status, rawCode(r))
        }
        return status
    }

    static func rawCode(_ r: CommandResult) -> Int32 {
        if !r.succeeded { Console.err("✘ \(SSH.diagnose(r).1)") }
        return r.succeeded ? 0 : (r.exitCode == 0 ? 1 : r.exitCode)
    }

    /// `_builder NAME HOST [arguments…]`
    static func builder(_ args: [String]) async -> Int32 {
        // Test hook: never against the real lab configuration and Keychain by accident.
        guard let dir = ProcessInfo.processInfo.environment["CMCR_CONFIG_DIR"], !dir.isEmpty else {
            fail("_builder służy do testów i wymaga CMCR_CONFIG_DIR (osobnej konfiguracji).")
        }
        guard args.count >= 2 else { fail("Użycie: cmcrctl _builder NAZWA all|nr [argumenty…]") }
        let name = args[0], spec = args[1]
        var a = Array(args.dropFirst(2))
        func flag(_ f: String) -> Bool {
            guard let i = a.firstIndex(of: f) else { return false }
            a.remove(at: i)
            return true
        }
        func option(_ o: String, _ fallback: Int) -> Int {
            guard let i = a.firstIndex(of: o), i + 1 < a.count else { return fallback }
            let v = Int(a[i + 1]) ?? fallback
            a.removeSubrange(i...(i + 1))
            return v
        }
        func arg(_ i: Int) -> String {
            guard i < a.count else { fail("Brak argumentu nr \(i + 1) dla \(name).") }
            return a[i]
        }
        let script: RemoteScript
        switch name {
        case "status": script = Scripts.status(checkSudo: flag("--sudo"))
        case "clean-folder": script = Scripts.cleanFolder(arg(0), dryRun: flag("--dry-run"))
        case "list-folder": script = Scripts.listFolder(arg(0), asRoot: root)
        case "distribute-key": script = Scripts.distributeKey(arg(0), authorizedKeys: arg(1))
        case "launch-app":
            let newInstance: Bool? = flag("--new") ? true : (flag("--same") ? false : nil)
            script = Scripts.launchApp(arg(0), arguments: a.count > 1 ? a[1] : "", newInstance: newInstance)
        case "quit-app":
            let term = flag("--term")
            let wait = option("--wait", 10)
            script = Scripts.quitApp(arg(0), force: force, terminateIfRunning: term, wait: wait)
        case "uninstall": script = Scripts.uninstallApp(arg(0))
        case "logout": script = Scripts.logoutUser(force: force, wait: option("--wait", 30))
        case "message": script = Scripts.message(title: arg(0), text: arg(1), asDialog: !flag("--notify"))
        case "power":
            guard let action = PowerAction(rawValue: arg(0)) else { fail("Nieznana akcja: \(arg(0))") }
            script = Scripts.power(action)
        case "prepare-shared": script = Scripts.prepareSharedFolder(arg(0), owner: arg(1))
        case "install-url":
            // No checks on this side: the remote script must refuse http:// by itself.
            script = Scripts.installFromURL(arg(0), allowUnsigned: flag("--allow-unsigned"))
        case "remove-collected":
            // _builder remove-collected HOST SRC MTIME:SIZE:REL… (MTIME "L" = link) [--root]
            let files = a.dropFirst().map { spec -> CollectedFile in
                let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { fail("Oczekiwano MTIME:SIZE:ŚCIEŻKA, podano „\(spec)”.") }
                return CollectedFile(path: parts[2], modified: Int(parts[0]) ?? 0, size: Int64(parts[1]) ?? 0,
                                     isLink: parts[0] == "L")
            }
            script = Scripts.removeCollected(in: arg(0), files: files, folders: [], asRoot: root)
        case "install-updates":
            script = Scripts.installUpdates(restart: flag("--restart"), recommendedOnly: flag("--recommended"),
                                            downloadOnly: flag("--download"), allowMajorUpgrade: flag("--major"))
        case "mas-upgrade": script = Scripts.masUpgrade()
        case "brew": script = Scripts.brew(arg(0))
        case "unity-install": script = Scripts.unityInstallEditor(version: arg(0), modules: Array(a.dropFirst()))
        case "unity-modules": script = Scripts.unityInstallModules(version: arg(0), modules: Array(a.dropFirst()))
        case "android-sdk": script = Scripts.androidSDK(unityVersion: arg(0), apiLevels: Array(a.dropFirst()))
        case "screen-sharing": script = Scripts.enableScreenSharing()
        case "push":
            // _builder push HOST DEST OWNER MODE file…
            let dest = arg(0), owner = arg(1), mode = arg(2)
            let urls = a.dropFirst(3).map { URL(fileURLWithPath: expandTilde($0)).standardizedFileURL }
            guard !urls.isEmpty else { fail("Podaj pliki do wysłania.") }
            let payload: URL
            switch await Payload.make(urls) {
            case .failure(let e): fail(e.localizedDescription)
            case .success(let url): payload = url
            }
            defer { try? FileManager.default.removeItem(at: payload) }
            var status: Int32 = 0
            for h in legacyCLI.targets(spec) {
                let r = await Operations.push(payload: payload, to: h, destination: dest, owner: owner, mode: mode,
                                              asRoot: root, password: Keychain.password(for: h),
                                              settings: sshSettings, onOutput: Console.printer)
                status = max(status, rawCode(r))
            }
            return status
        default:
            fail("Nieznany generator: \(name)")
        }
        return await runRaw(script, spec)
    }
}
