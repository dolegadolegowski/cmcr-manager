import AppKit
import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Records the Wake-on-LAN sends instead of putting packets on the network.
private final class WakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func record(_ macs: [String]) { lock.lock(); calls.append(macs); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
}

@MainActor
@Suite(.serialized, .enabled(if: AppTestEnvironment.isIsolated, "uruchamiaj przez scripts/test.sh (izolowana konfiguracja)"))
struct AppLogicTests {
    let classroom = ClassroomModel.shared

    /// End of lesson: warning first (1 min countdown, skipped by the test), then logging out.
    func endPlan() {
        var end = LessonEndConfig()
        end.warn = true
        end.warnMinutes = 1
        end.collect = false
        end.quitApps = false
        end.cleanShared = false
        end.cleanDownloads = false
        end.logout = true
        end.power = .none
        classroom.config.end = end
    }

    /// Runs the end of the lesson, skips the countdown and waits until the routine finished.
    func finishEndLesson(_ model: AppModel, _ start: () -> Void) async throws {
        start()
        let run = try #require(classroom.run)
        #expect(await AppTestEnvironment.wait { run.phase == "Odliczanie" })
        run.skipCountdown = true
        #expect(await AppTestEnvironment.wait { run.finished })
        #expect(await AppTestEnvironment.wait { model.batches.allSatisfy(\.finished) })
    }

    // lesson-warn-retry-reruns-whole-end
    @Test func retryingTheWarningDoesNotRunTheEndOfLessonAgain() async throws {
        let a = AppTestEnvironment.closedHost("imac01"), b = AppTestEnvironment.closedHost("imac02")
        let model = AppTestEnvironment.makeModel([a, b])
        endPlan()
        try await finishEndLesson(model) { classroom.endLesson(model, targets: [a, b]) }
        let ends = { model.batches.filter { $0.title == "Zakończenie zajęć" }.count }
        #expect(ends() == 1)
        let warning = try #require(model.batches.first { $0.title == "Zakończenie zajęć – ostrzeżenie" })
        #expect(warning.retryableMachines.count == 2)
        model.retry(warning, on: [b])
        let retry = try #require(model.batches.first { $0.title == "Zakończenie zajęć – ostrzeżenie (ponowienie)" })
        #expect(retry.jobs.map(\.machine.id) == [b.id])
        #expect(await AppTestEnvironment.wait { retry.finished })
        // The completion (countdown → rest) would start the disruptive steps within a moment.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(ends() == 1, "powtórzenie ostrzeżenia uruchomiło ponownie zakończenie zajęć na wszystkich komputerach")
        #expect(classroom.run?.restScheduled == true)
    }

    // lesson-end-skip-and-confirmation-lost
    @Test func stepsAfterTheCountdownKeepTheSkipAndTheConfirmation() async throws {
        let a = AppTestEnvironment.closedHost("imac01"), b = AppTestEnvironment.closedHost("imac02")
        let model = AppTestEnvironment.makeModel([a, b])
        endPlan()
        let confirmation = BatchConfirmation(button: "Zakończ zajęcia", destructive: true)
        try await finishEndLesson(model) {
            model.perform(skipping: [a.id], reason: .loggedInUser, confirmation: confirmation) {
                classroom.endLesson(model, targets: [a, b])
            }
        }
        #expect(model.pendingSkip == nil && model.pendingConfirmation == nil)
        let rest = try #require(model.batches.first { $0.title == "Zakończenie zajęć" })
        let skipped = try #require(rest.jobs.first { $0.machine.id == a.id })
        #expect(skipped.state == .skipped, "komputer wyłączony przez nauczyciela został wylogowany")
        #expect(skipped.skipReason == .loggedInUser)
        #expect(rest.jobs.first { $0.machine.id == b.id }?.state == .failed)
        #expect(rest.confirmation?.button == "Zakończ zajęcia")
        #expect(rest.skippedLoggedIn)
        let run = try #require(classroom.run)
        #expect(run.state(a.id, 1) == .skipped("pominięto – zalogowany użytkownik"))
    }

    // lesson-countdown-not-a-running-job
    @Test func theCountdownCountsAsRunningWork() async throws {
        let a = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([a])
        endPlan()
        classroom.endLesson(model, targets: [a])
        let run = try #require(classroom.run)
        #expect(await AppTestEnvironment.wait { run.phase == "Odliczanie" })
        #expect(model.runningJobCount == 0)
        #expect(model.hasRunningWork)
        #expect(model.sleepActivity != nil)
        let delegate = AppDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
                "zamknięcie okna podczas odliczania zakończyłoby aplikację bez wykonania kroków")
        let question = try #require(model.quitQuestion(quittingForUpdate: false))
        #expect(question.title == "Trwa zakończenie zajęć")
        #expect(question.quitButton == "Przerwij zajęcia i zakończ")
        run.skipCountdown = true
        #expect(await AppTestEnvironment.wait { run.finished })
        #expect(!model.hasRunningWork)
        #expect(model.sleepActivity == nil)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        #expect(model.quitQuestion(quittingForUpdate: false) == nil)
    }

    // update-install-vs-quit-alert
    @Test func anUpdateRestartIsNotAskedAboutTwice() async throws {
        let a = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([a])
        let batch = try #require(model.runBatch("Długie zadanie", on: [a]) { _, job in
            while !job.handle.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
            return .cancelledResult
        })
        #expect(await AppTestEnvironment.wait { model.runningJobCount == 1 })
        #expect(model.quitQuestion(quittingForUpdate: false) != nil)
        // The update sheet asked "Przerwać trwające zadania?" already; the installer waits only 60 s.
        #expect(model.quitQuestion(quittingForUpdate: true) == nil)

        let suite = "pl.cmcr.manager.unit-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = Updater(defaults: defaults)
        #expect(updater.needsJobsConfirmation, "instalacja przy trwających zadaniach musi najpierw zapytać w oknie uaktualnienia")
        updater.install(jobsConfirmed: true)
        #expect(!updater.needsJobsConfirmation)
        // Quitting was cancelled after the installer started: nothing may report a failed update at the next start.
        defaults.set("9.9.9", forKey: "update.pendingVersion")
        defaults.set("1.0.0", forKey: "update.pendingFrom")
        updater.quitForUpdateCancelled()
        #expect(defaults.string(forKey: "update.pendingVersion") == nil)
        #expect(defaults.string(forKey: "update.pendingFrom") == nil)
        #expect(!updater.isQuittingForUpdate)
        #expect(!updater.jobsConfirmed)
        #expect(updater.phase != .installing)
        batch.cancel()
        #expect(await AppTestEnvironment.wait { batch.finished })
    }

    // lesson-start-retry-deleted-payload
    @Test func retryingTheLessonStartSendsTheMaterialsAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-materials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 0x61, count: 30_000).write(to: folder.appendingPathComponent("zadanie.txt"))
        var start = LessonStartConfig()
        start.wake = false
        start.greet = false
        start.openApps = false
        start.sendMaterials = true
        start.materialsFolder = folder.path
        classroom.config.start = start
        let a = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([a])
        classroom.startLesson(model, targets: [a])
        let run = try #require(classroom.run)
        #expect(await AppTestEnvironment.wait { run.finished })
        let first = try #require(model.batches.first { $0.title == "Rozpoczęcie zajęć" })
        let sending = { (job: Job) in job.output.split(separator: "\n").first { $0.contains("Wysyłanie") }.map(String.init) }
        let line = try #require(sending(first.jobs[0]))
        let zero = "Wysyłanie \(ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))"
        #expect(!line.contains(zero))
        // The first batch's completion removed its archive; a retry must pack it again.
        try await Task.sleep(nanoseconds: 300_000_000)
        model.retry(first, on: [a])
        let retry = try #require(model.batches.first { $0.title == "Rozpoczęcie zajęć (ponowienie)" })
        #expect(await AppTestEnvironment.wait { retry.finished })
        let again = try #require(sending(retry.jobs[0]))
        #expect(again == line, "powtórzenie wysłało usunięte archiwum: \(again)")
        #expect(!retry.jobs[0].output.contains("No such file"))
    }

    // wake-retry-stale-errors
    @Test func retryingWakeOnLANSendsAgainWithTheCurrentMAC() async throws {
        let recorder = WakeRecorder()
        let original = ClassroomModel.wakeSender
        defer { ClassroomModel.wakeSender = original }
        ClassroomModel.wakeSender = { hosts in
            var errors: [UUID: String] = [:]
            for h in hosts {
                recorder.record(h.macs)
                // Never a real packet: a MAC is reported back instead of being sent.
                errors[h.machine.id] = h.macs.isEmpty ? "Brak adresu MAC" : "test: pakiet do \(h.macs.joined(separator: ",")) przechwycony"
            }
            return errors
        }
        let a = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([a])
        classroom.wake(model, [a])
        let first = try #require(model.batches.first { $0.title == "Wake-on-LAN" })
        #expect(await AppTestEnvironment.wait { first.finished })
        #expect(first.jobs[0].summary.contains("Brak adresu MAC"))
        // The teacher types the MAC in Konfiguracja and repeats on the failed Mac.
        model.machines[0].macAddress = "02:00:00:00:00:01"
        model.retry(first, on: first.retryableMachines)
        let retry = try #require(model.batches.first { $0.title == "Wake-on-LAN (ponowienie)" })
        #expect(await AppTestEnvironment.wait { retry.finished })
        #expect(recorder.all == [[], ["02:00:00:00:00:01"]], "powtórzenie nie wysłało pakietu ponownie")
        #expect(retry.jobs[0].summary.contains("przechwycony"))
    }

    // job-timeout-marks-offline
    @Test func aTimeoutAfterTheStartDoesNotMarkTheMacOffline() async throws {
        let a = AppTestEnvironment.closedHost("imac01"), b = AppTestEnvironment.closedHost("imac02")
        let model = AppTestEnvironment.makeModel([a, b])
        var online = HostStatus()
        online.reachability = .online
        model.statuses = [a.id: online, b.id: online]
        let batch = try #require(model.runBatch("Wolne polecenie", on: [a, b]) { m, _ in
            // imac01: the script ran on the Mac and was stopped by the time limit; imac02: never connected.
            CommandResult(exitCode: -1, stderr: Data("▸ Przekroczono limit czasu.\n".utf8), timedOut: true,
                          started: m.id == a.id)
        })
        #expect(await AppTestEnvironment.wait { batch.finished })
        #expect(model.status(a).reachability == .online, "komputer, na którym polecenie działało, oznaczono jako offline")
        #expect(!model.willSkip(a))
        #expect(model.status(b).reachability == .offline)
        #expect(batch.jobs[0].summary.contains("zbyt długo"))
    }

    // dev-run-wipes-update-cache
    @Test func aDevelopmentRunKeepsTheInstalledAppsStagedUpdate() throws {
        let state = try #require(ProcessInfo.processInfo.environment["CMCR_UPDATE_STATE_DIR"])
        // Never anywhere else than the test's own folder (the real cache holds the installed app's update).
        try #require(Updater.cachesFolder.path.hasPrefix(state))
        let marker = Updater.cachesFolder.appendingPathComponent("9.9.9-zainstalowana-aplikacja", isDirectory: true)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: marker) }
        let suite = "pl.cmcr.manager.unit-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Updater(defaults: defaults).removeLeftovers()
        #expect(FileManager.default.fileExists(atPath: marker.path), "uruchomienie deweloperskie usunęło przygotowane uaktualnienie")

        let app = InstallLocation.writable(URL(fileURLWithPath: "/Applications/CMCR Manager.app"))
        #expect(Updater.cleansUpdateCache(version: SemanticVersion("1.2.0"), location: app, environment: [:]))
        #expect(!Updater.cleansUpdateCache(version: nil, location: app, environment: [:]))
        #expect(!Updater.cleansUpdateCache(version: SemanticVersion("1.2.0"), location: .unsupported("x"), environment: [:]))
        #expect(!Updater.cleansUpdateCache(version: SemanticVersion("1.2.0"), location: app,
                                           environment: ["CMCR_SNAPSHOT_DIR": "/tmp/x"]))
        #expect(!Updater.cleansUpdateCache(version: SemanticVersion("1.2.0"), location: app,
                                           environment: ["CMCR_CONFIG_DIR": "/tmp/x"]))
    }

    // tofu-password-disclosure-spoofed-mdns (app side): "Zaufaj" stores exactly the key the sheet showed.
    @Test func trustingStoresExactlyTheShownKey() async throws {
        let a = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([a])
        let file = AppTestEnvironment.knownHostsFile
        try? FileManager.default.removeItem(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("hostkey")
        #expect(await ProcessRunner.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path]).succeeded)
        let pub = try String(contentsOf: URL(fileURLWithPath: key.path + ".pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = await ProcessRunner.run("/usr/bin/ssh-keygen", ["-l", "-f", key.path + ".pub"]).stdoutText
        let fp = try #require(listing.split(separator: " ").first { $0.hasPrefix("SHA256:") }.map(String.init))

        let review = HostTrustReview(machines: [a])
        var scan = HostTrust.Scan(host: a)
        scan.keys = [HostTrust.Key(type: "ED25519", fingerprint: fp, line: "[127.0.0.1]:1 \(pub)")]
        review.setScan(scan)
        model.hostTrustReview = review
        await model.trustHostKeys(in: review)
        #expect(model.hostTrustReview == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "[127.0.0.1]:1 \(pub)\n")
        let trusted = await HostTrust.trustedKeys(for: a, settings: model.sshSettings)
        #expect(trusted.map(\.fingerprint) == [fp])
        scan.trusted = trusted
        #expect(scan.state == .trusted)
    }

    @Test func aRefusedUnknownKeyIsOfferedForTrustNotAccepted() async throws {
        let a = AppTestEnvironment.closedHost("imac01")
        let model = AppTestEnvironment.makeModel([a])
        let review = HostTrustReview(machines: [a, AppTestEnvironment.closedHost("imac02")])
        var scan = HostTrust.Scan(host: a)
        scan.keys = [HostTrust.Key(type: "ED25519", fingerprint: "SHA256:nowy", line: "[127.0.0.1]:1 ssh-ed25519 AAAA")]
        review.setScan(scan)
        #expect(review.entries[0].chosen, "nowy klucz jest proponowany do zaufania")
        #expect(review.isScanning)
        var changed = HostTrust.Scan(host: review.entries[1].machine)
        changed.keys = [HostTrust.Key(type: "ED25519", fingerprint: "SHA256:inny", line: "x")]
        changed.trusted = [HostTrust.Key(type: "ED25519", fingerprint: "SHA256:stary")]
        review.setScan(changed)
        #expect(!review.entries[1].chosen, "zmieniony klucz nigdy nie jest zaznaczony z góry")
        #expect(review.hasChangedKey)
        #expect(review.chosenScans.map(\.host.id) == [a.id])
        _ = model
    }
}
