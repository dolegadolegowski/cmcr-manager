import CMCRCore
import Foundation

/// `cmcrctl unity latest|list|install`: Unity editors through Unity Hub on the iMacs (Hub CLI, headless).
/// The version is resolved here, once, so a line (6000.6) means the same release on every iMac.
@MainActor
enum UnityCLI {
    nonisolated static let usage = """
      cmcrctl unity latest LINIA                najnowsza wersja końcowa linii Unity (np. 6000.6): numer,
                                                changeset i rozmiar (Unity Release API)
      cmcrctl unity list [KOMP]                 edytory Unity zainstalowane przez Unity Hub
      cmcrctl unity install WERSJA|LINIA KOMP [--modules android,ios] [--changeset X]
                                                edytor Unity przez Unity Hub, dla architektury komputera;
                                                LINIA (6000.6) = jej najnowsza wersja, ta sama na wszystkich;
                                                komputer, który ją ma, jest pomijany (brakujące moduły są
                                                doinstalowywane); najpierw sprawdza wolne miejsce na dysku
    """

    nonisolated static let spec = ModuleSpec(values: ["--modules", "--changeset"], maxPositional: 3, parallel: true)

    static let syntax = "Użycie: cmcrctl unity latest LINIA | list [KOMP] | install WERSJA|LINIA KOMP [--modules android,ios] [--changeset X]"

    static func run(_ a: ModuleArguments) async -> Int32 {
        switch a[0] {
        case "latest": return await latest(a)
        case "list": return await list(a)
        case "install": return await install(a)
        case nil: moduleUsageError(a.command, syntax)
        case let other?: moduleUsageError(a.command, "Nieznane polecenie unity \(other).\n" + syntax)
        }
    }

    /// The Release API, or in the e2e harness a fixed answer from a file (no network in the tests).
    static var loader: UnityReleases.Loader? {
        guard inTestHarness, let path = ProcessInfo.processInfo.environment["CMCR_E2E_UNITY_RELEASES"], !path.isEmpty else {
            return nil
        }
        return { _ in try Data(contentsOf: URL(fileURLWithPath: path)) }
    }

    static func onlyInstallOptions(_ a: ModuleArguments) {
        for option in ["--modules", "--changeset"] where a.value(option) != nil {
            moduleUsageError(a.command, "Opcja \(option) dotyczy tylko polecenia unity install.")
        }
    }

    static func latest(_ a: ModuleArguments) async -> Int32 {
        onlyInstallOptions(a)
        guard a.positional.count == 2, let raw = a[1] else { moduleUsageError(a.command, "Użycie: cmcrctl unity latest LINIA (np. 6000.6)") }
        guard UnityReleases.isLine(raw) else {
            moduleUsageError(a.command, "Podaj linię Unity, np. 6000.6 (podano „\(raw)”).")
        }
        do {
            let r = try await UnityReleases.resolve(.line(raw), load: loader)
            Console.out("\(r.version) \(r.changeset)")
            Console.out("Wydano: \(day(r.releaseDate))\(r.stream.isEmpty ? "" : " (\(r.stream))")")
            for arch in ["arm64", "x86_64"] {
                guard let s = r.editor[arch] else { continue }
                Console.out("Edytor \(arch == "arm64" ? "Apple silicon" : "Intel"): pobranie \(gb(s.download)), "
                            + "po instalacji \(gb(s.installed))")
            }
            if let android = r.modules["arm64"]?["android"] ?? r.modules["x86_64"]?["android"] {
                Console.out("Moduł android (z SDK, NDK i OpenJDK): pobranie \(gb(android.download)), po instalacji \(gb(android.installed))")
            }
            return ExitCode.success
        } catch {
            Console.err("✘ \(error.localizedDescription)")
            return ExitCode.failure
        }
    }

    static func list(_ a: ModuleArguments) async -> Int32 {
        onlyInstallOptions(a)
        let targets = ModuleHosts.readOnly(a[1])
        let ssh = sshSettings
        return await eachHost(targets, a) { io in
            let r = await Interruption.shared.run(Scripts.unityHub(["editors", "--installed"]), on: io.host,
                                                  password: Keychain.password(for: io.host), settings: ssh,
                                                  timeout: 120, onOutput: io.stream)
            return io.report(r)
        }
    }

    static func install(_ a: ModuleArguments) async -> Int32 {
        guard a.positional.count >= 2, let raw = a[1] else { moduleUsageError(a.command, syntax) }
        guard let input = UnityVersionInput(raw) else {
            moduleUsageError(a.command, UnityReleaseError.invalidInput(raw).localizedDescription)
        }
        let modules = (a.value("--modules") ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        if let bad = modules.first(where: { !UnityReleases.isModuleID($0) }) {
            moduleUsageError(a.command, "--modules: „\(bad)” to nie identyfikator modułu Unity (np. android, ios, webgl, mac-il2cpp).")
        }
        let changeset = a.value("--changeset")
        if let changeset, !UnityReleases.isChangeset(changeset) {
            moduleUsageError(a.command, "--changeset: oczekiwano 12 znaków szesnastkowych (np. 237b6593792b), podano „\(changeset)”.")
        }
        if changeset != nil, case .line = input {
            moduleUsageError(a.command, "--changeset podaj razem z pełnym numerem wersji (np. 6000.6.8f1), nie z linią.")
        }
        // Before Unity is asked: a script without a host list stops here (exit 2), not after a network round trip.
        let targets = ModuleHosts.changing(a[2], a.command)
        let isExact: Bool
        if case .exact = input { isExact = true } else { isExact = false }

        var version = input.text
        var cs = changeset ?? ""
        var need: UnityDiskNeed?
        if isExact, changeset != nil {
            Console.out("Unity \(version) (changeset \(cs)) – bez sprawdzania w Unity Release API i bez kontroli miejsca na dysku.")
        } else {
            do {
                let r = try await UnityReleases.resolve(input, load: loader)
                let unknown = r.unknownModules(modules)
                guard unknown.isEmpty else {
                    moduleUsageError(a.command, "Unity \(r.version) nie ma modułów: \(unknown.joined(separator: ", ")). Dostępne: "
                                     + r.moduleIDs.sorted().joined(separator: ", "))
                }
                version = r.version
                cs = r.changeset
                need = r.diskNeed(modules: modules)
                let total = r.totalSize(modules: modules)
                let origin = isExact ? "wydana \(day(r.releaseDate))" : "najnowsza w linii \(input.text), wydana \(day(r.releaseDate))"
                Console.out("Unity \(version) (changeset \(cs), \(origin)).")
                Console.out("Na każdym komputerze: pobranie ok. \(gb(total.download)), po instalacji ok. \(gb(total.installed))"
                            + (modules.isEmpty ? "." : " (z modułami: \(modules.joined(separator: ", "))).")
                            + (targets.count > 1 ? " Razem do pobrania z internetu: ok. \(gb(total.download * Int64(targets.count)))." : ""))
            } catch let e as UnityReleaseError where e.isLookupUnavailable && isExact {
                // Unity Hub has its own release list: an exact version still installs, only without these checks.
                Console.err("Uwaga: \(e.localizedDescription) Instalacja bez changesetu i bez kontroli miejsca na dysku.")
            } catch {
                Console.err("✘ \(error.localizedDescription)")
                return ExitCode.failure
            }
        }
        let script = Scripts.unityInstallEditor(version: version, modules: modules, changeset: cs, diskNeed: need)
        return await runEach(targets, a, ssh: sshSettings) { _ in script }
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }

    static func day(_ date: Date?) -> String {
        guard let date else { return "?" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
