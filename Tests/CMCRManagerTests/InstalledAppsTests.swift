import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Aplikacje › Zainstalowane aplikacje: one row per app over the checked Macs, what „Odinstaluj…” sends to the Macs.
@MainActor
@Suite struct InstalledAppsTests {
    static func app(_ path: String, _ kind: InstalledApp.Kind = .app, version: String = "1.0", kb: Int64? = 100,
                    location: String = "apps") -> InstalledApp {
        InstalledApp(path: path, location: location, kind: kind, bundleID: "pl.test", version: version, sizeKB: kb)
    }

    @Test func rowsCountMacsVersionsAndSizes() throws {
        let a = HostInventory(apps: [Self.app("/Applications/Gra.app", version: "1.0", kb: 100),
                                     Self.app("/Applications/blender.app")])
        let b = HostInventory(apps: [Self.app("/Applications/Gra.app", version: "1.1", kb: 300),
                                     Self.app("/Users/u/Applications/Gra.app", location: "user:u")])
        let rows = InstalledAppsSection.rows([a, b])
        #expect(rows.map(\.app.path) == ["/Applications/blender.app", "/Applications/Gra.app", "/Users/u/Applications/Gra.app"])
        let gra = try #require(rows.first { $0.app.path == "/Applications/Gra.app" })
        #expect(gra.count == 2)
        #expect(gra.versions == ["1.0", "1.1"] && gra.versionText == "różne (2)")
        #expect(gra.sizeKB == 300)
        #expect(rows[0].versionText == "1.0" && rows[0].count == 1)
        let packages = InstalledAppsSection.packageRows([
            HostInventory(packages: [InstalledPackage(id: "b"), InstalledPackage(id: "a")]),
            HostInventory(packages: [InstalledPackage(id: "a")]),
        ])
        #expect(packages.map(\.id) == ["a", "b"] && packages.map(\.count) == [2, 1])
    }

    @Test func onlyRemovableAppsAreSentOnce() {
        let apps = [Self.app("/Applications/Gra.app"), Self.app("/Applications/Pages.app", .apple),
                    Self.app("/Applications/Gra.app"), Self.app("/System/Applications/Calculator.app", .system, location: "system"),
                    Self.app("/Applications/Unity/Hub/Editor/6000.3.7f1/Unity.app", .unity, location: "unity")]
        #expect(AppModel.uninstallPaths(apps) == ["/Applications/Gra.app", "/Applications/Unity/Hub/Editor/6000.3.7f1/Unity.app"])
        #expect(AppModel.uninstallTitle(Array(apps.prefix(2))) == "Gra, Pages")
        #expect(AppModel.uninstallTitle(apps) == "Gra, Pages i 3 innych")
    }
}

/// The dry run before uninstalling, against a Mac that cannot be reached: it reports why and offers nothing to run.
@Suite(.serialized, .enabled(if: AppTestEnvironment.isIsolated, "uruchamiaj przez scripts/test.sh (izolowana konfiguracja)"))
@MainActor
struct UninstallPreviewTests {
    @Test func unreachableMacGetsAReasonAndNoJob() async {
        let a = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([a])
        let preview = UninstallPreview(apps: [InstalledAppsTests.app("/Applications/Gra.app")], targets: [a], model: model)
        preview.load()
        #expect(preview.isLoading)
        #expect(await AppTestEnvironment.wait(30) { !preview.isLoading })
        guard case .error(let message)? = preview.results[a.id] else {
            Issue.record("brak błędu połączenia: \(String(describing: preview.results[a.id]))")
            return
        }
        #expect(!message.isEmpty)
        #expect(preview.readyTargets.isEmpty)
        #expect(preview.confirm() == nil)
        #expect(model.batches.isEmpty)
    }
}
