import CMCRCore
import Foundation

/// `cmcrctl app-update …` (update CMCR Manager itself from GitHub Releases) and the internal
/// `__swap-bundles` used by the update helper. Both run before the configuration is loaded, because the
/// helper may call `__swap-bundles` as root and an update needs no hosts or passwords.
enum SelfUpdateCommand {
    static let usage = """
      cmcrctl app-update [check] [--app ŚCIEŻKA] [--beta]
                                                sprawdź, czy jest nowa wersja CMCR Manager
      cmcrctl app-update install [--app ŚCIEŻKA] [--beta] [--relaunch]
                                                pobierz, zweryfikuj i zainstaluj nową wersję
                                                (aplikacja musi być zamknięta)
    """

    /// Exit code when the command was handled, nil for every other command.
    static func handle(_ argv: [String]) async -> Int32? {
        let args = Array(argv.dropFirst())
        if args.count == 3, args[0] == "__swap-bundles" {
            let rc = UpdateInstaller.swap(args[1], args[2])
            if rc != 0 { printError("swap: \(String(cString: strerror(rc)))") }
            return rc == 0 ? 0 : 1
        }
        guard args.first == "app-update" else { return nil }
        var rest = Array(args.dropFirst())
        let beta = take("--beta", from: &rest)
        let relaunch = take("--relaunch", from: &rest)
        let app = value("--app", from: &rest).map { URL(fileURLWithPath: expandTilde($0)).standardizedFileURL } ?? defaultApp
        let confirmTimeout = value("--confirm-timeout", from: &rest).flatMap(Int.init) ?? 45
        switch rest.first ?? "check" {
        case "check" where rest.count <= 1:
            return await check(app: app, beta: beta)
        case "install" where rest.count == 1:
            return await install(app: app, beta: beta, relaunch: relaunch, confirmTimeout: confirmTimeout)
        default:
            printError("Użycie:\n\(usage)")
            return 64
        }
    }

    /// The app this cmcrctl ships in (…/CMCR Manager.app/Contents/Resources/bin/cmcrctl), else /Applications.
    static var defaultApp: URL {
        var url = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.pathExtension == "app" ? url : URL(fileURLWithPath: "/Applications/CMCR Manager.app")
    }

    // MARK: - Commands

    static func check(app: URL, beta: Bool) async -> Int32 {
        guard let installed = installedVersion(app) else { return 1 }
        switch await lookUp(installed: installed, beta: beta) {
        case .failure(let error):
            printError("✘ \(error.localizedDescription)")
            return 1
        case .success(.upToDate(let latest)):
            print("CMCR Manager \(installed) jest aktualny" + (latest.map { " (najnowsze wydanie: \($0))." } ?? "."))
            return 0
        case .success(.available(let c)):
            print("Dostępna nowa wersja \(c.version) (zainstalowana: \(installed)).")
            if !c.notes.isEmpty { print("\n\(c.notes)\n") }
            print("Instalacja: cmcrctl app-update install" + (app == defaultApp ? "" : " --app \(shQuote(app.path))"))
            return 0
        }
    }

    static func install(app: URL, beta: Bool, relaunch: Bool, confirmTimeout: Int) async -> Int32 {
        guard let installed = installedVersion(app) else { return 1 }
        let location = InstallLocation.of(app)
        switch location {
        case .unsupported(let why):
            printError("✘ \(why)")
            return 1
        case .requiresAdmin where getuid() != 0:
            printError("✘ Brak uprawnień do zapisu w \(app.deletingLastPathComponent().path). Uruchom: sudo cmcrctl app-update install")
            return 1
        default:
            break
        }
        if isRunning(app) {
            printError("✘ CMCR Manager jest uruchomiony – zamknij aplikację (albo użyj menu CMCR Manager › Sprawdź uaktualnienia…).")
            return 1
        }
        let candidate: UpdateCandidate
        switch await lookUp(installed: installed, beta: beta) {
        case .failure(let error):
            printError("✘ \(error.localizedDescription)")
            return 1
        case .success(.upToDate):
            print("CMCR Manager \(installed) jest aktualny – nie ma czego instalować.")
            return 0
        case .success(.available(let c)):
            candidate = c
        }
        let m = candidate.manifest
        print("Pobieranie wersji \(m.version) (\(ByteCountFormatter.string(fromByteCount: m.size, countStyle: .file)))…")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-app-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent(m.file)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            _ = try await FileDownloader.download(candidate.archiveURL, to: zip, maxBytes: m.size, userAgent: userAgent(installed))
            try await UpdateVerifier.verifyDownload(zip, manifest: m, workDirectory: work)
        } catch {
            printError("✘ \(error.localizedDescription)")
            return 1
        }
        print("Zweryfikowano: podpis Ed25519 manifestu, SHA-256 archiwum, podpis kodu pakietu.")

        // The relaunched app confirms its start in the user's temporary folder, which root cannot predict.
        let asRoot = getuid() == 0
        if asRoot && relaunch { print("Uwaga: jako root aplikacja nie zostanie uruchomiona ponownie – uruchom ją ręcznie.") }
        var request = UpdateInstaller.Request(archive: zip, sha256: m.sha256, target: app, version: m.version,
                                              bundleIdentifier: m.bundleIdentifier, relaunch: relaunch && !asRoot)
        request.pid = nil
        request.confirmTimeout = confirmTimeout
        request.statusFile = work.appendingPathComponent("status")
        if asRoot, let sudoUID = ProcessInfo.processInfo.environment["SUDO_UID"].flatMap(UInt32.init) {
            request.uid = sudoUID
        }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = ["-c", UpdateInstaller.helperScript, "cmcr-updater"] + request.arguments
        do { try helper.run() } catch {
            printError("✘ \(UpdateError.helperFailed(error.localizedDescription).localizedDescription)")
            return 1
        }
        helper.waitUntilExit()
        // The helper leaves "failed <reason>" or "rolledback <reason>" in the status file. Process passes the
        // script in decomposed Unicode (file system representation), so the reason is recomposed for display.
        let reason = (try? String(contentsOf: request.statusFile, encoding: .utf8))?.precomposedStringWithCanonicalMapping
            .split(separator: " ", maxSplits: 1).dropFirst().first
            .map { " (\($0.trimmingCharacters(in: .whitespacesAndNewlines)))" } ?? ""
        switch helper.terminationStatus {
        case 0:
            print("✔ Zainstalowano CMCR Manager \(m.version) w \(app.path).")
            return 0
        case 2:
            printError("✘ Nowa wersja nie uruchomiła się poprawnie – przywrócono wersję \(installed)\(reason).")
            return 2
        default:
            printError("✘ Instalacja nie powiodła się – wersja \(installed) pozostała bez zmian\(reason).")
            return 1
        }
    }

    // MARK: - Helpers

    static func lookUp(installed: SemanticVersion, beta: Bool) async -> Result<UpdateCheckResult, Error> {
        let feed = UpdateFeed(configuration: .standard, userAgent: userAgent(installed))
        do { return .success(try await feed.check(current: installed, includePrereleases: beta, cache: nil).0) } catch {
            return .failure(error)
        }
    }

    static func installedVersion(_ app: URL) -> SemanticVersion? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            printError("✘ Nie znaleziono aplikacji \(app.path) (podaj ją przez --app).")
            return nil
        }
        let expected = UpdateConfiguration.standard.bundleIdentifier
        guard info["CFBundleIdentifier"] as? String == expected else {
            printError("✘ \(app.path) nie jest aplikacją CMCR Manager (\(expected)).")
            return nil
        }
        guard let version = (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init) else {
            printError("✘ Nieprawidłowa wersja w \(plist.path).")
            return nil
        }
        return version
    }

    static func isRunning(_ app: URL) -> Bool {
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "command="]
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        // Foundation drops the /private prefix of /tmp and /var paths, ps shows the path as it was started.
        let executable = app.appendingPathComponent("Contents/MacOS").path + "/"
        let prefixes = executable.hasPrefix("/tmp/") || executable.hasPrefix("/var/") ? [executable, "/private" + executable] : [executable]
        return output.split(separator: "\n").contains { line in prefixes.contains { line.hasPrefix($0) } }
    }

    static func userAgent(_ version: SemanticVersion) -> String { "CMCR-Manager/\(version) (cmcrctl; macOS)" }

    static func take(_ flag: String, from args: inout [String]) -> Bool {
        guard let i = args.firstIndex(of: flag) else { return false }
        args.remove(at: i)
        return true
    }

    static func value(_ option: String, from args: inout [String]) -> String? {
        guard let i = args.firstIndex(of: option), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
