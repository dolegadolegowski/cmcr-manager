import CMCRCore
import Foundation

/// `install` / `install-url`, plus `_builder`: a hidden hook that runs one remote script builder with
/// explicit parameters, used by the end-to-end tests (Tests/e2e/suites/scripts.sh).
@MainActor
enum ScriptCommands {
    static let usage = """
      cmcrctl install plik… [all|nr]            zainstaluj programy (.pkg/.dmg/.zip/.app) jako root
      cmcrctl install-url URL [all|nr]          pobierz instalator na iMacu i zainstaluj
    """

    /// Exit status, or nil when `command` is not one of these.
    static func run(_ command: String, _ args: [String]) async -> Int32? {
        let rest = Array(args.dropFirst())
        switch command {
        case "install": return await install(rest)
        case "install-url": return await installURL(rest)
        case "_builder": return await builder(rest)
        default: return nil
        }
    }

    static func install(_ args: [String]) async -> Int32 {
        var files = args
        var spec: String?
        if files.count >= 2, let last = files.last, !FileManager.default.fileExists(atPath: expandTilde(last)) {
            spec = last
            files.removeLast()
        }
        guard !files.isEmpty else { fail("Użycie: cmcrctl install plik… [all|nr]") }
        let urls = files.map { URL(fileURLWithPath: expandTilde($0)).standardizedFileURL }
        for u in urls where !FileManager.default.fileExists(atPath: u.path) { fail("Brak pliku: \(u.path)") }
        let targets = selectHosts(spec)
        let payload: URL
        switch await Payload.make(urls) {
        case .failure(let e): fail(e.localizedDescription)
        case .success(let url): payload = url
        }
        defer { try? FileManager.default.removeItem(at: payload) }
        var status: Int32 = 0
        for h in targets {
            print("\(h.name):")
            let r = await Operations.install(payload: payload, on: h, password: Keychain.password(for: h),
                                             settings: sshSettings, onOutput: Console.printer)
            status = max(status, report(r))
        }
        return status
    }

    static func installURL(_ args: [String]) async -> Int32 {
        guard let url = args.first, url.contains("://") else { fail("Użycie: cmcrctl install-url URL [all|nr]") }
        return await runOnHosts(Scripts.installFromURL(url), args.count > 1 ? args[1] : nil)
    }

    static func runOnHosts(_ script: RemoteScript, _ spec: String?) async -> Int32 {
        var status: Int32 = 0
        for h in selectHosts(spec) {
            print("\(h.name):")
            let r = await SSH.run(script, on: h, password: Keychain.password(for: h), settings: sshSettings,
                                  onOutput: Console.printer)
            status = max(status, report(r))
        }
        return status
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
            for h in selectHosts(spec) {
                let r = await Operations.push(payload: payload, to: h, destination: dest, owner: owner, mode: mode,
                                              asRoot: root, password: Keychain.password(for: h),
                                              settings: sshSettings, onOutput: Console.printer)
                status = max(status, report(r))
            }
            return status
        default:
            fail("Nieznany generator: \(name)")
        }
        return await runOnHosts(script, spec)
    }
}
