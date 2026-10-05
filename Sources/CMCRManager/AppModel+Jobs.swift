import AppKit
import CMCRCore
import SwiftUI
import UserNotifications

/// Short message shown at the bottom of the window right after an action starts.
struct ActionToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var icon = "play.circle.fill"
    var batchID: UUID?
}

extension Job.State {
    /// Name stored in the job history.
    var historyName: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .skipped: return "skipped"
        }
    }

    var label: String {
        switch self {
        case .queued: return "W kolejce"
        case .running: return "W toku"
        case .succeeded: return "Gotowe"
        case .failed: return "Błąd"
        case .cancelled: return "Przerwano"
        case .skipped: return "Pominięto"
        }
    }
}

/// What the operator confirmed before a batch started (see `ConfirmSheet`); a retry of such a batch asks again.
struct BatchConfirmation {
    let button: String
    let destructive: Bool
}

extension Job {
    /// The whole saved output: once the job is archived, `output` keeps only its tail in memory.
    var fullOutput: String {
        logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? output
    }

    /// Equal for jobs with the same (whitespace-trimmed) output, also after their logs were cut to the tail.
    var outputComparisonKey: String {
        trimmedOutputDigest.map { "sha256:" + $0 } ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Batch {
    /// The operator chose to leave out Macs with a logged-in user.
    var skippedLoggedIn: Bool { jobs.contains { $0.skipReason == .loggedInUser } }
}

extension AppModel {
    static weak var shared: AppModel?
    static let maxBatches = 100

    // MARK: - Targets

    /// Selected hosts an action will actually run on (unreachable ones are left out when `skipUnreachable`).
    var actionTargets: [Machine] {
        skipUnreachable ? selectedMachines.filter { !knownReachability($0).isUnreachable } : selectedMachines
    }

    func willSkip(_ m: Machine) -> Bool { skipUnreachable && knownReachability(m).isUnreachable }

    /// Reachability for skip decisions: while a host is being checked again, its last settled state counts,
    /// so an offline Mac keeps being skipped during a refresh instead of costing a connect timeout.
    func knownReachability(_ m: Machine) -> Reachability {
        let r = status(m).reachability
        return r == .checking ? settledReachability[m.id] ?? .checking : r
    }

    func rememberSettledReachability() {
        for (id, st) in statuses where st.reachability != .checking && settledReachability[id] != st.reachability {
            settledReachability[id] = st.reachability
        }
    }

    func pruneSelection() {
        let ids = Set(machines.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
    }

    var groups: [String] { HostGroups.all(in: machines) }

    func selectGroup(_ group: String, adding: Bool = false) {
        let ids = Set(HostGroups.members(of: group, in: machines).map(\.id))
        selection = adding ? selection.union(ids) : ids
    }

    func selectOnline() {
        selection = Set(machines.filter { status($0).reachability == .online }.map(\.id))
    }

    func invertSelection() {
        selection = Set(machines.map(\.id)).subtracting(selection)
    }

    /// Files dropped on a host in the list: prepare them for sending in Pliki with that host as the target.
    @discardableResult
    func dropFiles(_ urls: [URL], on m: Machine) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        for url in files where !pushItems.contains(url) { pushItems.append(url) }
        if !selection.contains(m.id) { selection = [m.id] }
        section = .files
        let target = selection.count == 1 ? m.name : Polish.computers(selection.count)
        showToast(ActionToast(message: "Dodano \(Polish.files(files.count)) do wysłania (cel: \(target)) – sprawdź folder docelowy i wyślij.",
                        icon: "tray.and.arrow.up"))
        return true
    }

    /// Runs `action` (which starts batches synchronously) with `ids` turned into skipped jobs; the batches
    /// remember `confirmation`, so that repeating them asks again.
    func perform(skipping ids: Set<UUID>, reason: Job.SkipReason, confirmation: BatchConfirmation? = nil,
                 _ action: () -> Void) {
        pendingSkip = ids.isEmpty ? nil : (ids, reason)
        pendingConfirmation = confirmation
        defer {
            pendingSkip = nil
            pendingConfirmation = nil
        }
        action()
    }

    /// Repeats `batch` on `hosts`. A batch that had to be confirmed (restart, log out, wipe a folder…) is
    /// confirmed again with the hosts and their logged-in users listed, never re-run straight away.
    func retry(_ batch: Batch, on hosts: [Machine]) {
        guard let rerun = batch.rerun, !hosts.isEmpty else { return }
        guard let confirmation = batch.confirmation else {
            rerun(hosts)
            return
        }
        retryConfirmation = ConfirmRequest(
            title: "Powtórzyć „\(batch.title)”?",
            message: "Ta operacja wymagała potwierdzenia – może przerwać pracę zalogowanych uczniów lub usunąć dane. "
                + "Zostanie wykonana ponownie \(Polish.onComputers(hosts.count)).",
            button: confirmation.button, destructive: confirmation.destructive, targets: hosts,
            skipLoggedIn: batch.skippedLoggedIn) {
            rerun(hosts)
        }
    }

    // MARK: - Status re-checks

    /// After a password change, hosts that failed to log in (or were never checked) are checked again right away,
    /// so their state does not wait for the periodic refresh.
    func recheckAfterCredentialChange(_ hosts: [Machine]) {
        let stale = hosts.filter { [.unknown, .authFailed, .error].contains(status($0).reachability) }
        if !stale.isEmpty { refreshStatus(stale) }
    }

    /// A remote command just logged in to a host the status still shows as not online: refresh that host.
    func recheckAfterLogin(_ m: Machine, _ r: CommandResult) {
        if r.succeeded, ![.online, .checking].contains(status(m).reachability) { refreshStatus([m]) }
    }

    /// Woken Macs need a while to boot: check them again after ~40 s and ~90 s, so that they stop being
    /// skipped as offline as soon as they answer.
    func recheckWhileWaking(_ hosts: [Machine]) {
        let ids = Set(hosts.map(\.id))
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            for pause in [40, 50] as [UInt64] {
                try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
                guard let self else { return }
                let pending = self.machines.filter { ids.contains($0.id) && self.status($0).reachability != .online }
                if pending.isEmpty { return }
                self.refreshStatus(pending)
            }
        }
    }

    // MARK: - Batches

    static func retryTitle(_ title: String) -> String {
        title.hasSuffix(" (ponowienie)") ? title : title + " (ponowienie)"
    }

    /// Keeps memory bounded: the oldest finished batches go first (their logs stay in the history).
    func trimBatches() {
        guard batches.count > Self.maxBatches else { return }
        var excess = batches.count - Self.maxBatches
        var i = batches.count - 1
        while excess > 0 && i >= 0 {
            if batches[i].finished {
                batches.remove(at: i)
                excess -= 1
            }
            i -= 1
        }
        let kept = Set(batches.map(\.id))
        lastBatch = lastBatch.filter { kept.contains($0.value.id) }
    }

    func batch(_ id: UUID?) -> Batch? { id.flatMap { id in batches.first { $0.id == id } } }

    func showJobs(_ batchID: UUID?) {
        focusedBatchID = batchID
        section = .jobs
    }

    /// Selects the hosts where the batch did not succeed.
    func selectProblems(of batch: Batch) {
        let ids = Set(batch.problemMachines.map(\.id))
        if !ids.isEmpty { selection = ids }
    }

    func showToast(_ toast: ActionToast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled, self.toast?.id == toast.id { self.toast = nil }
        }
    }

    func announce(_ batch: Batch) {
        let started = batch.jobs.count - batch.skipped
        if started == 0 {
            showToast(ActionToast(message: "Nie uruchomiono „\(batch.title)” – zaznaczone komputery są niedostępne",
                            icon: "exclamationmark.triangle.fill", batchID: batch.id))
            return
        }
        var message = "Uruchomiono „\(batch.title)” \(Polish.onComputers(started))"
        if batch.skipped > 0 { message += " · pominięto \(batch.skipped)" }
        showToast(ActionToast(message: message, batchID: batch.id))
    }

    func batchFinished(_ batch: Batch) {
        if batch.duration >= 30, !NSApp.isActive { JobNotifier.post(batch) }
    }

    /// Writes the job to the persistent history; the in-memory log is trimmed once the full one is on disk.
    func archive(_ job: Job, in batch: Batch) {
        let output = job.output
        let record = JobRecord(
            id: job.id, batchID: batch.id, title: batch.title, section: batch.section?.rawValue,
            operatorName: JobHistory.operatorName, hostID: job.machine.id, host: job.machine.name,
            address: job.machine.address, state: job.state.historyName, exitCode: job.exitCode,
            batchStartedAt: batch.createdAt, startedAt: job.startedAt, finishedAt: job.finishedAt ?? Date(),
            summary: job.summary,
            outputFile: output.isEmpty ? nil : JobHistory.outputPath(batchID: batch.id, batchStartedAt: batch.createdAt,
                                                                     host: job.machine.name, jobID: job.id),
            outputBytes: output.utf8.count)
        JobHistory.record(record, output: output.isEmpty ? nil : output) { url in
            guard let url else { return }
            DispatchQueue.main.async {
                job.logURL = url
                job.trimAfterArchive()
            }
        }
    }

    // MARK: - Running jobs: sleep, Dock badge

    func runningJobsChanged(from old: Int) {
        if runningJobCount > 0, sleepActivity == nil {
            // An idle-sleeping admin Mac would drop every ssh connection and leave installs half done.
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "CMCR Manager: trwają zadania na iMacach")
        } else if runningJobCount == 0, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        NSApp?.dockTile.badgeLabel = runningJobCount > 0 ? "\(runningJobCount)" : nil
    }
}

// MARK: - Persistence of small UI choices

enum TargetUIState {
    /// Isolated runs (CMCR_CONFIG_DIR, tests, UI snapshots) never read or write the user's preferences.
    private static var defaults: UserDefaults? {
        ProcessInfo.processInfo.environment["CMCR_CONFIG_DIR"] == nil ? .standard : nil
    }

    static var selection: Set<UUID> {
        get { Set((defaults?.stringArray(forKey: "selectedHosts") ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults?.set(newValue.map(\.uuidString).sorted(), forKey: "selectedHosts") }
    }

    static var skipUnreachable: Bool {
        get { defaults?.object(forKey: "skipUnreachable") as? Bool ?? true }
        set { defaults?.set(newValue, forKey: "skipUnreachable") }
    }
}

// MARK: - Payload shared by a batch and its retries

/// Archive of local files used by every job of a batch and of its retries: packed on first use, packed again
/// when a retry needs it after cleanup, and deleted once its batch finished and no job uses it.
final class SharedPayload: @unchecked Sendable {
    private actor Store {
        let items: [URL]
        var file: URL?
        var building: Task<Result<URL, PayloadFailure>, Never>?
        var users = 0
        var discardWhenIdle = false

        init(_ items: [URL]) { self.items = items }

        func acquire() async -> Result<URL, PayloadFailure> {
            users += 1
            discardWhenIdle = false
            if let file, FileManager.default.fileExists(atPath: file.path) { return .success(file) }
            if let building { return await building.value }
            let items = self.items
            let task = Task { () -> Result<URL, PayloadFailure> in
                switch await Payload.make(items) {
                case .success(let url): return .success(url)
                case .failure(let error): return .failure(PayloadFailure(message: error.localizedDescription))
                }
            }
            building = task
            let result = await task.value
            building = nil
            if case .success(let url) = result { file = url }
            return result
        }

        func release() {
            users = max(0, users - 1)
            if users == 0 && discardWhenIdle { removeFile() }
        }

        func discard() {
            discardWhenIdle = true
            if users == 0 { removeFile() }
        }

        private func removeFile() {
            if let file { try? FileManager.default.removeItem(at: file) }
            file = nil
            discardWhenIdle = false
        }
    }

    struct PayloadFailure: Error { let message: String }

    private let store: Store

    init(_ items: [URL]) { store = Store(items) }

    @MainActor
    func use(_ body: @MainActor (URL) async -> CommandResult) async -> CommandResult {
        switch await store.acquire() {
        case .failure(let failure):
            await store.release()
            return .failure(failure.message)
        case .success(let url):
            let result = await body(url)
            await store.release()
            return result
        }
    }

    func discard() {
        Task { await store.discard() }
    }
}

// MARK: - Notifications

/// Completion notifications for long batches finished while the app is in the background.
enum JobNotifier {
    private final class Router: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let id = UUID(uuidString: response.notification.request.identifier)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                MainActor.assumeIsolated { AppModel.shared?.showJobs(id) }
            }
            completionHandler()
        }
    }

    private static let router = Router()

    /// UNUserNotificationCenter needs an app bundle; the bare `swift run` executable has none.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func post(_ batch: Batch) {
        guard isAvailable else { return }
        let title = batch.failed > 0 ? "Zakończono z błędami: \(batch.title)" : "Zakończono: \(batch.title)"
        var parts = ["Gotowe \(Polish.onComputers(batch.succeeded))"]
        if batch.failed > 0 { parts.append("błędy: \(batch.failed)") }
        if batch.skipped > 0 { parts.append("pominięto: \(batch.skipped)") }
        if batch.cancelled > 0 { parts.append("przerwano: \(batch.cancelled)") }
        let body = parts.joined(separator: " · ")
        let id = batch.id.uuidString
        let center = UNUserNotificationCenter.current()
        center.delegate = router
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

// MARK: - Quitting while jobs run

extension AppDelegate {
    @MainActor @objc
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.shared, model.runningJobCount > 0 else { return .terminateNow }
        let n = model.runningJobCount
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(Polish.plural(n, "Trwa", "Trwają", "Trwa")) \(Polish.jobs(n)) na iMacach"
        alert.informativeText = "Zakończenie aplikacji przerwie połączenia – wysyłanie plików i instalacje mogą "
            + "pozostać niedokończone. Zamknięcie samego okna nie przerywa zadań."
        alert.addButton(withTitle: "Nie kończ")
        let quit = alert.addButton(withTitle: "Przerwij zadania i zakończ")
        quit.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.batches.forEach { $0.cancel() }
        return .terminateNow
    }
}
