import Foundation
import Testing
@testable import CMCRCore

/// Installed applications and uninstalling (Scripts+Apps.swift, AppInventory.swift, AppUninstall.swift): the records,
/// their Polish text, and the scripts run locally against folders of the test (as sshd would run them, without ssh).
@Suite struct AppInventoryTests {
    // MARK: - Inventory records

    static let sample = [
        "CMCR:MDM\tyes",
        "CMCR:APP\tapps\tapp\t/Applications/Blender.app\torg.blenderfoundation.blender\t4.2.1\t950000\tpl.test.blender,pl.test.extra",
        "CMCR:APP\tuser:uczen\tapp\t/Users/uczen/Applications/Gra.app\tpl.test.gra\t0.9\t\t",
        "CMCR:APP\tunity\tunity\t/Applications/Unity/Hub/Editor/6000.3.7f1/Unity.app\tcom.unity3d.UnityEditor5.x\t6000.3.7f1\t\t",
        "CMCR:APP\tapps\tapple\t/Applications/Pages.app\tcom.apple.iWork.Pages\t14.1\t500000\t",
        "CMCR:APP\tsystem\tsystem\t/System/Applications/Calculator.app\tcom.apple.calculator\t11.0\t1000\t",
        "CMCR:APP\tapps\tappstore\t/Applications/Ze Sklepu.app\tpl.test.sklep\t2.2\t100\t",
        "CMCR:APP\tfolder\tapp\t/Applications/Firma/Program.app\tpl.test.firma\t5\t10\t",
        "CMCR:APP\tapps\tnieznany\t/Applications/X.app\tx\t1\t1\t",
        "CMCR:APP\tapps\tapp\tbez-ukośnika\tx\t1\t1\t",
        "jakiś inny wiersz",
        "CMCR:PKG\tpl.test.blender\t4.2.1\t1767225600\t/",
        "CMCR:END\t7",
    ].joined(separator: "\n")

    @Test func parsesAppsPackagesAndMDM() throws {
        let inv = AppInventory.parse(Self.sample)
        #expect(inv.complete)
        #expect(inv.mdmEnrolled == true)
        #expect(inv.apps.map(\.name) == ["Blender", "Calculator", "Gra", "Pages", "Program", "Unity 6000.3.7f1", "Ze Sklepu"])
        let blender = try #require(inv.apps.first { $0.name == "Blender" })
        #expect(blender.bundleID == "org.blenderfoundation.blender")
        #expect(blender.version == "4.2.1")
        #expect(blender.sizeKB == 950000)
        #expect(blender.receipts == ["pl.test.blender", "pl.test.extra"])
        #expect(blender.isRemovable && blender.locationLabel == "Aplikacje")
        let gra = try #require(inv.apps.first { $0.name == "Gra" })
        #expect(gra.sizeKB == nil && gra.receipts.isEmpty)
        #expect(gra.user == "uczen" && gra.locationLabel == "Aplikacje konta uczen")
        #expect(inv.packages.map(\.id) == ["pl.test.blender"])
        #expect(inv.packages[0].installed == Date(timeIntervalSince1970: 1767225600))
        #expect(!AppInventory.parse("CMCR:APP\tapps\tapp\t/Applications/A.app\ta\t1\t1\t").complete)
        #expect(AppInventory.parse("CMCR:MDM\tunknown").mdmEnrolled == nil)
    }

    @Test func protectedKindsAreNotRemovableAndSayWhy() throws {
        let inv = AppInventory.parse(Self.sample)
        func app(_ name: String) throws -> InstalledApp { try #require(inv.apps.first { $0.name == name }) }
        for name in ["Pages", "Calculator"] {
            #expect(try !app(name).isRemovable, "\(name)")
            #expect(try app(name).reasonNotRemovable != nil)
        }
        #expect(InstalledApp(path: "/Applications/C.app", location: "apps", kind: .cmcr).reasonNotRemovable?.contains("CMCR") == true)
        let unity = try app("Unity 6000.3.7f1")
        #expect(unity.isRemovable)
        #expect(unity.removalPath == "/Applications/Unity/Hub/Editor/6000.3.7f1")
        #expect(unity.uninstallNote?.contains("modułami") == true)
        #expect(try app("Ze Sklepu").uninstallNote?.contains("MDM") == true)
        #expect(try app("Program").locationLabel == "Aplikacje › Firma")
        #expect(InstalledApp(path: "/Applications/Photoshop.app", location: "apps", kind: .app, bundleID: "com.adobe.Photoshop")
            .uninstallNote?.contains("Creative Cloud") == true)
    }

    // MARK: - Uninstall records and their text

    static let run = [
        "CMCR:UN\ttarget\tapp\t/Applications/Gra.app\tGra\t1.0\tpl.test.gra\t2048\tapps",
        "CMCR:UN\trunning\tprocess\t/Applications/Gra.app\tuczen\t123 456",
        "CMCR:UN\tplan\tapp\t/Applications/Gra.app\t2048",
        "CMCR:UN\tplan\tdaemon\t/Library/LaunchDaemons/pl.test.gra.plist\tpl.test.gra.helper",
        "CMCR:UN\tkept\tpkgfiles\t/Library/Gra/a.txt\t2\t/Library/Gra/a.txt|/Library/Gra/b.txt",
        "CMCR:UN\tplan\treceipt\tpl.test.gra.pkg\t",
        "CMCR:UN\trefused\tapp\t/Applications/Pages.app\tto aplikacja Apple (com.apple.iWork.Pages)",
        "CMCR:UN\tmissing\tapp\tBrak.app\tnie ma takiej aplikacji",
        "CMCR:UN\tnote\tmdm\t\tKomputer jest zarządzany przez MDM",
        "błąd narzędzia",
        "CMCR:UN\tdone\tsummary\t\t0 1 0 3 1 1 2048 0",
    ].joined(separator: "\n")

    @Test func parsesTheReportAndItsSummary() throws {
        let report = UninstallReport.parse(Self.run)
        #expect(report.targets.map(\.path) == ["/Applications/Gra.app"])
        #expect(report.planned.count == 3)
        #expect(report.hasWork)
        #expect(report.refusals.count == 1)
        #expect(report.other == ["błąd narzędzia"])
        let s = try #require(report.summary)
        #expect(s.dryRun && s.planned == 3 && s.refused == 1 && s.kept == 1 && s.plannedKB == 2048)
        #expect(UninstallRecord(line: "CMCR:UN\tnieznane\tapp\t/x") == nil)
        #expect(UninstallRecord(line: "CMCR:UNX\tplan\tapp\t/x") == nil)
    }

    @Test func rendersPolishLines() {
        let text = UninstallReport.render(Self.run)
        let mb = AppInventory.sizeText(2048)
        #expect(text.contains("▸ Gra – wersja 1.0, pl.test.gra, \(mb): /Applications/Gra.app"))
        #expect(UninstallReport.line(UninstallRecord(verb: .target, what: "app", path: "/Applications/B.app", detail: "B",
                                                     extra: ["", "pl.test.b", "", "apps"])) == "▸ B – wersja —, pl.test.b: /Applications/B.app")
        #expect(text.contains("Aplikacja jest uruchomiona – konto: uczen (PID 123 456)"))
        #expect(text.contains("• Do usunięcia – aplikację: /Applications/Gra.app (\(mb))"))
        #expect(text.contains("usługę systemową (LaunchDaemon) pl.test.gra.helper (najpierw zatrzymana)"))
        #expect(text.contains("Zostaje 2 pliki pakietu poza aplikacją (np. /Library/Gra/a.txt, /Library/Gra/b.txt)"))
        #expect(text.contains("Do wyrejestrowania – pakiet pl.test.gra.pkg"))
        #expect(text.contains("✘ Odmowa: /Applications/Pages.app – to aplikacja Apple"))
        #expect(text.contains("• Nie znaleziono: Brak.app"))
        #expect(text.contains("ℹ︎ Komputer jest zarządzany przez MDM"))
        #expect(text.contains("błąd narzędzia"))
        #expect(text.hasSuffix("Podgląd: do usunięcia 3 elementy (\(mb)), pozostawiono 1, odmowa: 1 – nic jeszcze nie zmieniono."))
        #expect(!text.contains("CMCR:UN"))
        var done = UninstallSummary()
        done.removed = 5
        done.removedKB = 1_048_576
        done.failed = 1
        #expect(UninstallReport.summaryLine(done) == "Wynik: usunięto 5 elementów (\(AppInventory.sizeText(1_048_576))), błędy: 1.")
        #expect(UninstallReport.line(UninstallRecord(verb: .failed, what: "app", path: "/Applications/X.app", detail: "Operation not permitted"))
                == "  ✘ Nie udało się usunąć /Applications/X.app: Operation not permitted")
    }

    /// cmcrctl and the app's Zadania get the records converted as they arrive, also when a line is split
    /// between chunks; other output passes unchanged.
    @Test func streamRendererConvertsLineByLine() {
        let r = UninstallReport.StreamRenderer()
        var out = Data()
        let line = "CMCR:UN\tremoved\tapp\t/Applications/Gra.app\t2048\n"
        let bytes = Array(Data(("zwykły wiersz\n" + line + "reszta bez końca").utf8))
        for chunk in stride(from: 0, to: bytes.count, by: 7) {
            out += r.feed(.stdout, Data(bytes[chunk..<min(chunk + 7, bytes.count)]))
        }
        out += r.finish(.stdout)
        #expect(String(decoding: out, as: UTF8.self)
                == "zwykły wiersz\n  ✔ Usunięto aplikację: /Applications/Gra.app (\(AppInventory.sizeText(2048)))\nreszta bez końca")
        #expect(r.finish(.stderr).isEmpty)
    }

    // MARK: - Scripts

    @Test func scriptsRunAsRootOnlyForUninstalling() {
        #expect(!Scripts.appInventory(studentUser: "uczen").asRoot)
        #expect(Scripts.uninstallApps(["Gra"], studentUser: "uczen").asRoot)
        let body = Scripts.uninstallApps(["it's \"q\" $(id)", "/Applications/B.app"], studentUser: "a'b", dryRun: true,
                                         packageFiles: true).body
        #expect(body.contains(#"TARGETS=('it'\''s "q" $(id)' '/Applications/B.app')"#))
        #expect(body.contains("STUDENT='a'\\''b'; DRY=1; PKGFILES=1"))
        #expect(Scripts.uninstallApp("/Applications/X.app").body.contains("DRY=0; PKGFILES=0"))
    }

    /// bash 3.2 (macOS) cannot parse a case pattern inside $( ) – it fails at run time, not under bash -n.
    @Test func noCaseInsideCommandSubstitution() {
        for script in [Scripts.appInventory(studentUser: "s", receipts: true), Scripts.uninstallApps(["x"], studentUser: "s")] {
            #expect(script.body.range(of: #"\$\(\s*case"#, options: .regularExpression) == nil)
        }
    }

    // MARK: - Versions on several Macs

    static let lab = (1...11).map { String(format: "imac%02d", $0) }

    @Test func versionsAreListedWithTheirMacs() {
        let pairs = Self.lab.map { ($0, $0 == "imac11" ? "12.0" : "12.1") }
        #expect(VersionSummary.text(pairs.map { (host: $0.0, version: $0.1) }, order: Self.lab) == "12.1 (imac01–imac10), 12.0 (imac11)")
        // One version on every Mac: just the version; no version anywhere: „—”.
        #expect(VersionSummary.text([("imac01", "3.0"), ("imac02", "3.0")], order: Self.lab) == "3.0")
        #expect(VersionSummary.text([("imac01", ""), ("imac02", "")], order: Self.lab) == "—")
        #expect(VersionSummary.text([], order: Self.lab) == "—")
        // A Mac without a version is shown, last.
        #expect(VersionSummary.text([("imac02", ""), ("imac01", "2.0")], order: Self.lab) == "2.0 (imac01), — (imac02)")
        // As many Macs: the newest version first (numerically: 1.10 > 1.9).
        #expect(VersionSummary.text([("imac01", "1.9"), ("imac02", "1.10")], order: Self.lab) == "1.10 (imac02), 1.9 (imac01)")
    }

    /// A range never hides a Mac that does not have this version (or the app), and two Macs are not a range.
    @Test func hostRangesFollowTheListOrder() {
        #expect(VersionSummary.hostList(["imac01", "imac02", "imac03", "imac05"], order: Self.lab) == "imac01–imac03, imac05")
        #expect(VersionSummary.hostList(["imac01", "imac02"], order: Self.lab) == "imac01, imac02")
        #expect(VersionSummary.hostList(["imac03", "imac01", "imac02"], order: Self.lab) == "imac03, imac01, imac02")
        #expect(VersionSummary.groups([("imac03", "1"), ("imac01", "1"), ("imac02", "1")], order: Self.lab).first?.hosts
                == ["imac01", "imac02", "imac03"])
        #expect(VersionSummary.hostList(["x", "imac01"], order: Self.lab) == "x, imac01")
    }

    @Test func uninstallVersionLinesPerApp() {
        func report(_ version: String) -> UninstallReport {
            UninstallReport.parse("CMCR:UN\ttarget\tapp\t/Applications/Gra.app\tGra\t\(version)\tpl.test.gra\t10\tapps\n"
                                  + "CMCR:UN\ttarget\tapp\t/Applications/Edytor.app\tEdytor\t7\tpl.test.e\t10\tapps")
        }
        let lines = UninstallReport.versionLines([("imac01", report("1.0")), ("imac02", report("2.0")), ("imac03", report(""))])
        #expect(lines == ["Gra: 2.0 (imac02), 1.0 (imac01), — (imac03)", "Edytor: 7"])
        #expect(AppInventory.parse("CMCR:APP\tapps\tapp\t/Applications/A.app\ta\t 1.2 \t1\t").apps.first?.version == "1.2")
        #expect(InstalledApp(path: "/Applications/A.app", location: "apps", kind: .app).versionText == "—")
    }

    // MARK: - Running the scripts locally

    /// Folders of the test: Applications, Users/<account>/Applications and the system folders (fsroot), plus fakes:
    /// sudo runs as the current user, pkgutil knows no packages, profiles says „not enrolled”, launchctl only logs.
    struct Lab {
        let dir: URL
        var apps: URL { dir.appendingPathComponent("Applications") }
        var home: URL { dir.appendingPathComponent("Users/\(Lab.me)") }
        static let me = NSUserName()

        init() throws {
            dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("cmcr-apps-\(UUID().uuidString)")
            for sub in ["Applications/Utilities", "Users/\(Lab.me)/Applications", "fsroot/Library/LaunchDaemons"] {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            let fakes = #"""
            _lab_log() { printf '%s\n' "$*" >> "$LAB_DIR/log"; }
            sudo() {
              while [ $# -gt 0 ]; do
                case "$1" in -A|-n|-k|-H) shift ;; -u|-g|-p|-C|-h) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac
              done
              [ $# -eq 0 ] && return 0
              SUDO_USER="$(id -un)" "$@"
            }
            pkgutil() { _lab_log "pkgutil $*"; case "$1" in --pkgs) return 0 ;; *) return 1 ;; esac; }
            profiles() { printf 'MDM enrollment: No\n'; }
            launchctl() { _lab_log "launchctl $*"; return 0; }
            kill() { _lab_log "kill $*"; return 0; }
            export -f _lab_log sudo pkgutil profiles launchctl kill
            """#
            try fakes.write(to: dir.appendingPathComponent("fakes.sh"), atomically: true, encoding: .utf8)
        }

        var environment: [String: String] {
            ["BASH_ENV": dir.appendingPathComponent("fakes.sh").path, "LAB_DIR": dir.path, "CMCR_APPS_DIR": apps.path,
             "CMCR_USERS_DIR": dir.appendingPathComponent("Users").path, "CMCR_FS_PREFIX": dir.appendingPathComponent("fsroot").path]
        }

        /// `version` is CFBundleShortVersionString and `build` CFBundleVersion; nil leaves the key out.
        func makeApp(_ folder: URL, _ name: String, bundleID: String, version: String? = "1.0", build: String? = nil) throws {
            let contents = folder.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            var plist: [String: Any] = ["CFBundleIdentifier": bundleID]
            if let version { plist["CFBundleShortVersionString"] = version }
            if let build { plist["CFBundleVersion"] = build }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try Data(count: 4096).write(to: contents.appendingPathComponent("MacOS/\(name)"))
        }

        func run(_ script: RemoteScript) async -> CommandResult {
            await ProcessRunner.run("/bin/sh", ["-c", script.remoteCommand()], environment: environment,
                                    stdin: Data("haslo\n".utf8), timeout: 120)
        }

        /// Error output apart from the wrapper's own markers (SSH.run removes those).
        static func errors(_ r: CommandResult) -> [Substring] {
            r.stderrText.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("CMCR:SESSION-") }
        }

        func log() -> String { (try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? "" }
        func remove() { try? FileManager.default.removeItem(at: dir) }

        /// The fakes must be in place in every bash (also the root re-exec) before anything runs.
        func guardFakes() async -> Bool {
            let r = await ProcessRunner.run("/bin/bash", ["--noprofile", "--norc", "-c", "/bin/bash --noprofile --norc -c 'type -t sudo pkgutil launchctl kill'"],
                                            environment: environment)
            return r.stdoutText == "function\nfunction\nfunction\nfunction\n"
        }
    }

    @Test func inventoryListsTheFoldersOfTheTest() async throws {
        let lab = try Lab()
        defer { lab.remove() }
        try #require(await lab.guardFakes())
        try lab.makeApp(lab.apps, "Edytor", bundleID: "pl.test.edytor", version: "2.5")
        try lab.makeApp(lab.apps.appendingPathComponent("Utilities"), "Narzędzie", bundleID: "pl.test.narzedzie")
        try lab.makeApp(lab.home.appendingPathComponent("Applications"), "Gra", bundleID: "pl.test.gra")
        try lab.makeApp(lab.apps, "Pages Test", bundleID: "com.apple.test")
        // Version fallbacks: CFBundleVersion without CFBundleShortVersionString (or with a blank one), neither,
        // and a Unity editor (its folder's name).
        try lab.makeApp(lab.apps, "Tylko Build", bundleID: "pl.test.build", version: nil, build: "77")
        try lab.makeApp(lab.apps, "Pusta Wersja", bundleID: "pl.test.pusta", version: "  ", build: "5.0.1")
        try lab.makeApp(lab.apps, "Bez Wersji", bundleID: "pl.test.bez", version: nil, build: nil)
        try lab.makeApp(lab.apps.appendingPathComponent("Unity/Hub/Editor/6000.6.8f1"), "Unity",
                        bundleID: "com.unity3d.UnityEditor5.x", version: "6000.6.8f1")
        let r = await lab.run(Scripts.appInventory(studentUser: Lab.me))
        #expect(r.exitCode == 0)
        #expect(Lab.errors(r).isEmpty, "\(r.stderrText)")
        let inv = AppInventory.parse(r.stdoutText)
        #expect(inv.complete && inv.mdmEnrolled == false)
        let byName = Dictionary(inv.apps.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["Edytor"]?.version == "2.5" && byName["Edytor"]?.location == "apps")
        #expect((byName["Edytor"]?.sizeKB ?? 0) > 0)
        #expect(byName["Narzędzie"]?.location == "utilities")
        #expect(byName["Gra"]?.location == "user:\(Lab.me)")
        #expect(byName["Pages Test"]?.kind == .apple)
        #expect(byName["Tylko Build"]?.version == "77")
        #expect(byName["Pusta Wersja"]?.version == "5.0.1")
        #expect(byName["Bez Wersji"]?.version == "" && byName["Bez Wersji"]?.versionText == "—")
        #expect(byName["Unity 6000.6.8f1"]?.version == "6000.6.8f1" && byName["Unity 6000.6.8f1"]?.kind == .unity)
        #expect(inv.apps.contains { $0.kind == .system && $0.path.hasPrefix("/System/Applications/") })
    }

    @Test func dryRunChangesNothingAndTheRealRunRemoves() async throws {
        let lab = try Lab()
        defer { lab.remove() }
        try #require(await lab.guardFakes())
        try lab.makeApp(lab.apps, "Gra", bundleID: "pl.test.gra", version: nil, build: "42")
        let app = lab.apps.appendingPathComponent("Gra.app").path
        let dry = await lab.run(Scripts.uninstallApps(["Gra"], studentUser: Lab.me, dryRun: true))
        #expect(dry.exitCode == 0, "\(dry.stdoutText)\(dry.stderrText)")
        #expect(Lab.errors(dry).isEmpty, "\(dry.stderrText)")
        let plan = UninstallReport.parse(dry.stdoutText)
        #expect(plan.planned.map(\.path) == [app])
        #expect(plan.targets.first?.version == "42", "wersja z CFBundleVersion, gdy brak CFBundleShortVersionString")
        #expect(plan.summary?.dryRun == true)
        #expect(FileManager.default.fileExists(atPath: app))
        let real = await lab.run(Scripts.uninstallApps([app], studentUser: Lab.me))
        #expect(real.exitCode == 0, "\(real.stdoutText)\(real.stderrText)")
        let done = UninstallReport.parse(real.stdoutText)
        #expect(done.records.contains { $0.verb == .removed && $0.path == app })
        #expect(done.summary?.removed == 1)
        #expect(!FileManager.default.fileExists(atPath: app))
        let again = await lab.run(Scripts.uninstallApps([app], studentUser: Lab.me))
        #expect(again.exitCode == 0)
        #expect(UninstallReport.parse(again.stdoutText).records.first?.verb == .missing)
    }

    @Test func refusalsLeaveEverythingInPlace() async throws {
        let lab = try Lab()
        defer { lab.remove() }
        try #require(await lab.guardFakes())
        try lab.makeApp(lab.apps, "Apple Test", bundleID: "com.apple.test")
        let outside = lab.dir.appendingPathComponent("gdzie-indziej")
        try lab.makeApp(outside, "Obca", bundleID: "pl.test.obca")
        let r = await lab.run(Scripts.uninstallApps(["Apple Test", outside.appendingPathComponent("Obca.app").path,
                                                     lab.apps.appendingPathComponent("../gdzie-indziej/Obca.app").path],
                                                    studentUser: Lab.me))
        #expect(r.exitCode == 2, "\(r.stdoutText)\(r.stderrText)")
        let report = UninstallReport.parse(r.stdoutText)
        #expect(report.refusals.count == 3)
        #expect(report.summary?.removed == 0)
        #expect(FileManager.default.fileExists(atPath: lab.apps.appendingPathComponent("Apple Test.app").path))
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Obca.app").path))
        #expect(!lab.log().contains("kill"))
    }
}
