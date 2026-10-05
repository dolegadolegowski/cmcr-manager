import CMCRCore
import Foundation

/// `install` / `install-url`, plus `_builder`: a hidden hook that runs one remote script builder with
/// explicit parameters, used by the end-to-end tests (Tests/e2e/suites/scripts.sh).
@MainActor
enum ScriptCommands {
    static let usage = """
      cmcrctl install plik… [all|nr] [--allow-unsigned]
                                                zainstaluj programy (.pkg/.dmg/.zip/.app) jako root; bez
                                                --allow-unsigned tylko z ważnym podpisem i notaryzacją Apple
      cmcrctl install-url https://… [all|nr] [--sha256 SUMA] [--allow-unsigned]
                                                pobierz instalator na iMacu (tylko https) i zainstaluj
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

    /// Removes `--allow-unsigned` and `--sha256 SUMA` from install arguments.
    static func installOptions(_ args: [String], sha256Allowed: Bool) -> (rest: [String], allowUnsigned: Bool, sha256: String?) {
        var rest: [String] = []
        var allow = false
        var sha: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            i += 1
            if a == "--allow-unsigned" {
                allow = true
            } else if a == "--yes" || a == "-y" {
                continue
            } else if sha256Allowed, a == "--sha256" || a.hasPrefix("--sha256=") {
                let raw: String
                if a == "--sha256" {
                    guard i < args.count else { fail("Brak wartości dla --sha256.") }
                    raw = args[i]
                    i += 1
                } else {
                    raw = String(a.dropFirst("--sha256=".count))
                }
                guard let hex = Scripts.normalizedSHA256(raw) else {
                    fail("--sha256: oczekiwano 64 znaków szesnastkowych (suma SHA-256), podano „\(raw)”.")
                }
                sha = hex
            } else if a.hasPrefix("--") {
                fail("Nieznana opcja: \(a)")
            } else {
                rest.append(a)
            }
        }
        return (rest, allow, sha)
    }

    static func install(_ args: [String]) async -> Int32 {
        let options = installOptions(args, sha256Allowed: false)
        var files = options.rest
        var spec: String?
        if files.count >= 2, let last = files.last, !FileManager.default.fileExists(atPath: expandTilde(last)) {
            spec = last
            files.removeLast()
        }
        guard !files.isEmpty else { fail("Użycie: cmcrctl install plik… [all|nr] [--allow-unsigned]") }
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
            let r = await Operations.install(payload: payload, on: h, allowUnsigned: options.allowUnsigned,
                                             password: Keychain.password(for: h), settings: sshSettings,
                                             onOutput: Console.printer)
            status = max(status, report(r))
        }
        return status
    }

    static func installURL(_ args: [String]) async -> Int32 {
        let options = installOptions(args, sha256Allowed: true)
        let use = "Użycie: cmcrctl install-url https://… [all|nr] [--sha256 SUMA] [--allow-unsigned]"
        guard options.rest.count <= 2, let url = options.rest.first, url.contains("://") else { fail(use) }
        guard Scripts.isSecureDownloadURL(url) else {
            fail("Dozwolone są tylko adresy https:// (lub file://) – przez http:// ktoś w sieci szkolnej mógłby podmienić instalator.")
        }
        return await runOnHosts(Scripts.installFromURL(url, sha256: options.sha256, allowUnsigned: options.allowUnsigned),
                                options.rest.count > 1 ? options.rest[1] : nil)
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
