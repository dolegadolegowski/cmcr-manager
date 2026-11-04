import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// CMCR Screen Agent in the app (docs/screen-agent.md): what the job log says about an installation, the readiness
/// texts that replaced the manual sshd-keygen-wrapper steps, and the fixes offered from a screen tile.
@MainActor
@Suite struct ScreenAgentTextTests {
    @Test func installReportReadsTheMachineLines() {
        let out = """
        → Wysyłanie usługi podglądu…
        CMCR:AGENT updated 1.0.0
        CMCR:AGENT-SESSION student 501 AGENT 1.0.0 perm=denied locked=0 console=1 asleep=0 user=student
        CMCR:AGENT-SESSION nauczyciel 502 ERR unreachable Usługa nie odpowiada
        CMCR:AGENT-SESSION gosc 503 ERR noperm Brak uprawnienia
        CMCR:AGENT-SESSION ania 504 AGENT 1.0.0 perm=granted locked=0 console=0 asleep=0 user=ania
        CMCR:AGENT-SESSION
        """
        let r = ScreenAgentInstallReport.parse(out)
        #expect(r.change == .updated)
        #expect(r.version == "1.0.0")
        #expect(r.sessions.map(\.user) == ["student", "nauczyciel", "gosc", "ania"])
        #expect(r.sessions.map(\.state) == [.noPermission, .notAnswering("Usługa nie odpowiada"), .noPermission, .ready])
        #expect(r.needsPermission)
        #expect(r.short == "Usługa podglądu: zaktualizowana do 1.0.0 – bez uprawnienia nagrywania ekranu.")
        // One line per session, the outcome last (it becomes the job's summary).
        #expect(r.lines.count == 5)
        #expect(r.lines[1] == "nauczyciel: usługa nie odpowiada (Usługa nie odpowiada).")
        #expect(r.lines.last?.hasPrefix("Usługa podglądu zaktualizowana do wersji 1.0.0.") == true)
        #expect(r.lines.last?.contains("Poproś o uprawnienie nagrywania ekranu") == true)
    }

    @Test func installReportWithoutSessionsOrLines() {
        let unchanged = ScreenAgentInstallReport.parse("CMCR:AGENT unchanged 1.0.0\n")
        #expect(unchanged.lines == ["Usługa podglądu bez zmian – wersja 1.0.0 była już zainstalowana. Nikt nie jest zalogowany – usługa uruchomi się przy najbliższym logowaniu."])
        #expect(unchanged.short == "Usługa podglądu: bez zmian (1.0.0).")
        // Nothing machine-readable (an older core, a changed format): still a sensible sentence, no crash.
        let unknown = ScreenAgentInstallReport.parse("cokolwiek\nCMCR:AGENT\n")
        #expect(unknown.change == nil && unknown.sessions.isEmpty)
        #expect(unknown.short == "Usługa podglądu: zainstalowana.")
        let fresh = ScreenAgentInstallReport.parse("CMCR:AGENT installed 1.0.0\nCMCR:AGENT-SESSION s 501 AGENT 1.0.0 perm=granted\n")
        #expect(fresh.lines == ["s: usługa działa i ma uprawnienie nagrywania ekranu.", "Usługa podglądu zainstalowana (wersja 1.0.0)."])
    }

    @Test func machineLinesStayOutOfTheJobLog() {
        let seen = Recorder()
        let filter = AgentLineFilter { channel, data in seen.add(channel, String(decoding: data, as: UTF8.self)) }
        filter.callback(.stdout, Data("→ Wysyłanie…\nCMCR:AGENT inst".utf8))
        filter.callback(.stdout, Data("alled 1.0.0\nCMCR:AGENT-SESSION s 501 AGENT 1.0.0 perm=granted\nGotowe.\n".utf8))
        filter.callback(.stderr, Data("CMCR:AGENT na stderr zostaje\n".utf8))
        #expect(seen.text(.stdout) == "→ Wysyłanie…\nGotowe.\n")
        #expect(seen.text(.stderr) == "CMCR:AGENT na stderr zostaje\n")
    }

    @Test func permissionNoteFollowsTheAgentsAnswer() {
        #expect(AppModel.permissionNote("PERMISSION granted\n").contains("ma już uprawnienie"))
        let denied = AppModel.permissionNote("PERMISSION denied\n")
        #expect(denied.hasPrefix("Na iMacu pojawiło się okno macOS."))
        #expect(denied.contains("Nagrywanie ekranu i dźwięku systemowego") && denied.contains(ScreenAgentInfo.displayName))
        #expect(AppModel.permissionNote("").hasPrefix("Prośba wysłana."))
    }

    /// The readiness texts guide through the agent's permission: no ssh tool to add by hand any more.
    @Test func screenRecordingStepIsAboutTheAgent() {
        let step = ManualStep.screenRecording
        let all = ([step.title, step.summary] + step.steps + step.notes).joined(separator: "\n")
        for old in ["sshd-keygen-wrapper", "sshd-session", "⌘⇧G", "„+”"] {
            #expect(!all.contains(old), "\(old) w instrukcji nagrywania ekranu")
        }
        #expect(step.steps.count == 4)
        #expect(step.steps[0].contains("Poproś o uprawnienie"))
        #expect(step.steps[1].contains("Nagrywanie ekranu i dźwięku systemowego") && step.steps[1].contains("macOS 14"))
        #expect(step.steps[2].contains("„\(ScreenAgentInfo.displayName)”"))
        #expect(step.notes.contains { $0.contains("raz na iMaca") })
        #expect(step.notes.contains { $0.contains("ad-hoc") })
        #expect(step.notes.contains { $0.contains("AllowStandardUserToSetSystemService") })
        #expect(step.notes.contains { $0.contains("cmcr-screen-capture-alert.mobileconfig") })
        #expect(ReadinessCheck.screen.header == "Podgląd\nekranu")
    }

    /// No text of the app sends the teacher to the ssh tools any more (the whole CMCRManager source).
    @Test func appHasNoSSHPermissionWording() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CMCRManager")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // („Kopiuj ścieżkę” stays: the file browser copies remote paths with it.)
            for old in ["sshd-keygen-wrapper", "sshd-session", "⌘⇧G", "Kopiuj ścieżkę /usr/libexec"] {
                #expect(!text.contains(old), "\(file.lastPathComponent): \(old)")
            }
        }
    }

    @Test func tileOffersTheFixForAgentProblems() {
        #expect(ScreenIssue.agentMissing.agentFix == .screenAgent)
        #expect(ScreenIssue.agentDown("x").agentFix == .screenAgent)
        #expect(ScreenIssue.agentUntrusted("x").agentFix == .screenAgent)
        #expect(ScreenIssue.agentPermission.agentFix == .screenPermission)
        #expect(ScreenIssue.captureFailed("x").agentFix == nil)
        #expect(ScreenIssue.noUser.agentFix == nil)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [OutputChannel: String] = [:]
    func add(_ channel: OutputChannel, _ text: String) { lock.withLock { parts[channel, default: ""] += text } }
    func text(_ channel: OutputChannel) -> String { lock.withLock { parts[channel] ?? "" } }
}

/// The jobs: installing from Przygotowanie iMaców and as the first step of „Skonfiguruj zaznaczone”. The Macs are
/// closed ports (nothing is installed anywhere); the agent's location is replaced for the test.
@MainActor
@Suite(.serialized, .enabled(if: AppTestEnvironment.isIsolated, "uruchamiaj przez scripts/test.sh (izolowana konfiguracja)"))
struct ScreenAgentModelTests {
    func withAgent<T>(_ url: URL?, _ body: () async throws -> T) async rethrows -> T {
        let saved = AppModel.bundledScreenAgent
        AppModel.bundledScreenAgent = { url }
        defer { AppModel.bundledScreenAgent = saved }
        return try await body()
    }

    var fakeAgent: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-unit-\(UUID().uuidString)/\(ScreenAgentInfo.appName)")
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        return url
    }

    var options: SetupOptions {
        var o = SetupOptions()
        o.installKey = false
        return o
    }

    @Test func installWithoutABundledAgentExplainsAndStartsNothing() async throws {
        let model = AppTestEnvironment.makeModel([AppTestEnvironment.closedHost("imac01")])
        model.notice = nil
        await withAgent(nil) {
            #expect(model.installScreenAgent(on: model.machines) == nil)
            model.applyReadinessFix(.screenAgent, on: model.machines)
        }
        let notice = try #require(model.notice)
        #expect(notice.title == "Brak usługi podglądu w tej kopii aplikacji")
        #expect(notice.message.contains("scripts/build-app.sh"))
        #expect(model.batches.isEmpty)
    }

    @Test func quickFixesStartTheirJobs() async throws {
        let m = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([m])
        let agent = fakeAgent
        defer { try? FileManager.default.removeItem(at: agent.deletingLastPathComponent()) }
        await withAgent(agent) {
            model.applyReadinessFix(.screenAgent, on: [m])
            model.applyReadinessFix(.screenPermission, on: [m])
            model.applyReadinessFix(.removeScreenAgent, on: [m])
        }
        #expect(model.batches.map(\.title) == [AppModel.screenAgentRemoveTitle, AppModel.screenAgentPermissionTitle,
                                               AppModel.screenAgentInstallTitle])
        #expect(model.batches.allSatisfy { $0.section == .setup })
        #expect(await AppTestEnvironment.wait { model.batches.allSatisfy(\.finished) })
        // Nothing listens on the closed port: every job fails, none claims success.
        #expect(model.batches.allSatisfy { $0.failed == 1 })
    }

    @Test func setupInstallsTheAgentFirst() async throws {
        let m = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([m])
        let agent = fakeAgent
        defer { try? FileManager.default.removeItem(at: agent.deletingLastPathComponent()) }
        await withAgent(agent) { model.runSetupScript(options, mode: .apply, on: [m]) }
        let batch = try #require(model.batches.first)
        #expect(batch.title == "Konfiguracja iMaców (skrypt \(SetupScript.version), usługa podglądu \(ScreenAgentInfo.version))")
        #expect(await AppTestEnvironment.wait { batch.finished })
        let job = try #require(batch.jobs.first)
        #expect(job.output.hasPrefix("▸ Usługa podglądu ekranu (\(ScreenAgentInfo.displayName) \(ScreenAgentInfo.version)) – instalacja lub aktualizacja…"),
                "\(job.output)")
        #expect(job.state == .failed)
    }

    @Test func setupWithoutABundledAgentWarnsAndGoesOn() async throws {
        let m = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([m])
        model.notice = nil
        await withAgent(nil) { model.runSetupScript(options, mode: .apply, on: [m]) }
        let batch = try #require(model.batches.first)
        #expect(await AppTestEnvironment.wait { batch.finished })
        let job = try #require(batch.jobs.first)
        // A warning in the job, not an alert that would stop the whole configuration.
        #expect(model.notice == nil)
        #expect(job.output.contains(AppModel.screenAgentMissingText + " Usługa podglądu zostaje pominięta, reszta konfiguracji się wykona."))
        #expect(!job.output.contains("instalacja lub aktualizacja…"))
    }

    @Test func verifyAndSwitchedOffInstallNothing() async throws {
        let m = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([m])
        let agent = fakeAgent
        defer { try? FileManager.default.removeItem(at: agent.deletingLastPathComponent()) }
        var off = options
        off.screenAgent = false
        await withAgent(agent) {
            model.runSetupScript(options, mode: .verify, on: [m])
            model.runSetupScript(off, mode: .apply, on: [m])
        }
        #expect(model.batches.map(\.title) == ["Konfiguracja iMaców (skrypt \(SetupScript.version))",
                                               "Sprawdzenie konfiguracji iMaców (bez zmian)"])
        #expect(await AppTestEnvironment.wait { model.batches.allSatisfy(\.finished) })
        for job in model.batches.flatMap(\.jobs) {
            #expect(!job.output.contains("Usługa podglądu"), "\(job.output)")
        }
    }
}
