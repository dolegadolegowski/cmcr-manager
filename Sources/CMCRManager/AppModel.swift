import AppKit
import CMCRCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, commands, files, browser, apps, install, updates, screens, power, jobs, setup
    case classroom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Komputery"
        case .commands: return "Polecenia"
        case .files: return "Pliki"
        case .browser: return "Przeglądarka plików"
        case .apps: return "Aplikacje"
        case .install: return "Instalacja"
        case .updates: return "Aktualizacje"
        case .screens: return "Podgląd ekranów"
        case .power: return "Sesja i zasilanie"
        case .jobs: return "Zadania"
        case .setup: return "Konfiguracja"
        case .classroom: return "Zajęcia"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "desktopcomputer"
        case .commands: return "terminal"
        case .files: return "folder"
        case .browser: return "externaldrive.connected.to.line.below"
        case .apps: return "square.grid.2x2"
        case .install: return "shippingbox"
        case .updates: return "arrow.triangle.2.circlepath"
        case .screens: return "eye"
        case .power: return "power"
        case .jobs: return "list.bullet.rectangle"
        case .setup: return "gearshape"
        case .classroom: return "graduationcap"
        }
    }
}

/// One operation on one Mac. Mutated on the main thread only.
final class Job: ObservableObject, Identifiable, @unchecked Sendable {
    enum State { case queued, running, succeeded, failed, cancelled, skipped }

    /// Why a job never started.
    enum SkipReason: Equatable {
        case unreachable(Reachability)
        case loggedInUser

        var text: String {
            switch self {
            case .unreachable(.authFailed):
                return "Pominięto – błąd logowania przy ostatnim sprawdzeniu (sprawdź hasło lub klucz)."
            case .unreachable:
                return "Pominięto – komputer był niedostępny przy ostatnim sprawdzeniu."
            case .loggedInUser:
                return "Pominięto – na komputerze był zalogowany użytkownik."
            }
        }
    }

    let id = UUID()
    let machine: Machine
    let handle = ProcessHandle()
    @Published var state: State = .queued
    @Published var summary = ""
    @Published var startedAt: Date?
    @Published var finishedAt: Date?
    @Published private(set) var lastLine = ""
    /// Full log on disk (history), set once the finished job was archived.
    @Published var logURL: URL?
    var exitCode: Int32?
    private(set) var skipReason: SkipReason?
    /// Digest of the whole output taken before the in-memory log was cut to its tail (`trimAfterArchive`).
    private(set) var trimmedOutputDigest: String?

    // `output` is served straight from the bounded buffer: a second published copy would make every
    // append copy the whole log (copy-on-write).
    private var log = BoundedText(limit: Job.maxOutput)
    private var lines = LastLineTracker()
    private let incoming = OutputCoalescer()

    init(machine: Machine) { self.machine = machine }

    static let maxOutput = 300_000
    /// What stays in memory after the job was archived to disk.
    static let keptAfterArchive = 48_000
    static let flushInterval: TimeInterval = 0.1

    var output: String { log.text }
    /// Changes whenever the beginning of `output` is dropped (incremental log views reload then).
    var outputGeneration: Int { log.generation }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        objectWillChange.send()
        log.append(text)
        lines.consume(text)
        if lines.lastLine != lastLine { lastLine = lines.lastLine }
    }

    func note(_ line: String) { append("▸ \(line)\n") }

    /// Streamed output from any thread; it reaches `output` in batches at most every 100 ms.
    func receive(_ text: String) {
        guard incoming.add(text) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in self?.flushIncoming() }
    }

    /// Moves buffered streamed output into the log now (main thread), e.g. before the summary is computed.
    func flushIncoming() { append(incoming.drain()) }

    func skip(_ reason: SkipReason) {
        skipReason = reason
        state = .skipped
        summary = reason.text
        append("▸ \(reason.text)\n")
    }

    /// Keeps only the tail in memory once the saved output (up to `maxOutput`) is on disk.
    func trimAfterArchive() {
        guard log.text.utf8.count > Self.keptAfterArchive else { return }
        objectWillChange.send()
        trimmedOutputDigest = OutputDigest.of(log.text.trimmingCharacters(in: .whitespacesAndNewlines))
        log.keepLast(Self.keptAfterArchive, marker: "…(początek pominięty – dłuższa część wyniku: „Otwórz zapisany wynik”)…\n")
    }

    var isFinished: Bool { state == .succeeded || state == .failed || state == .cancelled || state == .skipped }

    /// Worth repeating: failed, interrupted or skipped because the Mac was unreachable (not skipped on purpose).
    var isRetryable: Bool {
        switch state {
        case .failed, .cancelled: return true
        case .skipped: return skipReason != .loggedInUser
        default: return false
        }
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

/// A group of jobs started together (one action on many Macs).
final class Batch: ObservableObject, Identifiable, @unchecked Sendable {
    let id = UUID()
    let title: String
    let createdAt = Date()
    let jobs: [Job]
    let section: AppSection?
    @Published var completed = 0
    @Published var finished = false
    @Published var finishedAt: Date?
    /// Starts the same operation again on other hosts (set by `AppModel.runBatch`); use `AppModel.retry`.
    var rerun: (([Machine]) -> Void)?
    /// Set when the operator had to confirm the action: a retry asks again.
    var confirmation: BatchConfirmation?

    init(title: String, jobs: [Job], section: AppSection? = nil) {
        self.title = title
        self.jobs = jobs
        self.section = section
    }

    var succeeded: Int { jobs.filter { $0.state == .succeeded }.count }
    var failed: Int { jobs.filter { $0.state == .failed }.count }
    var skipped: Int { jobs.filter { $0.state == .skipped }.count }
    var cancelled: Int { jobs.filter { $0.state == .cancelled }.count }
    var running: Int { jobs.filter { $0.state == .running }.count }
    var retryableMachines: [Machine] { jobs.filter(\.isRetryable).map(\.machine) }
    var problemMachines: [Machine] { jobs.filter { $0.state == .failed || $0.state == .cancelled || $0.state == .skipped }.map(\.machine) }

    var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(createdAt) }

    func cancel() { jobs.forEach { $0.handle.cancel() } }
}

struct HostApps {
    var user: String?
    var apps: [RunningApp] = []
    var error: String?
    var updatedAt = Date()
}

struct UpdateInfo {
    var titles: [String] = []
    var raw = ""
    var checkedAt = Date()
}

/// Forwards process output into a job's log; the job coalesces it before it reaches the UI.
final class OutputSink: @unchecked Sendable {
    private weak var job: Job?
    private let out = UTF8StreamDecoder()
    private let err = UTF8StreamDecoder()

    init(_ job: Job) { self.job = job }

    var callback: Operations.Output {
        { [self] channel, data in
            let text = channel == .stdout ? out.decode(data) : err.decode(data)
            guard !text.isEmpty else { return }
            job?.receive(text)
        }
    }
}

enum OwnerChoice: String, CaseIterable, Identifiable {
    case keep, student, console, admin, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keep: return "Bez zmian"
        case .student: return "Konto ucznia"
        case .console: return "Zalogowany użytkownik"
        case .admin: return "Administrator (root:admin)"
        case .custom: return "Inny…"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var machines: [Machine] {
        didSet {
            ConfigStore.saveHosts(machines)
            pruneSelection()
            closeStaleConnections(oldMachines: oldValue)
        }
    }
    @Published var settings: AppSettings {
        didSet {
            if settings != oldValue {
                ConfigStore.saveSettings(settings)
                closeStaleConnections(oldSettings: oldValue)
            }
        }
    }
    /// Problems found while loading hosts.json/settings.json (shown once at start).
    @Published var configIssues: [String] = []
    /// A password could not be saved in (or removed from) the Keychain; shown as an alert.
    @Published var keychainError: String?
    @Published var statuses: [UUID: HostStatus] = [:] {
        didSet { rememberSettledReachability() }
    }
    @Published var selection: Set<UUID> = [] {
        didSet { if selection != oldValue { TargetUIState.selection = selection } }
    }
    @Published var section: AppSection? = .dashboard
    @Published var batches: [Batch] = []
    @Published var lastBatch: [AppSection: Batch] = [:]
    /// Jobs started and not finished yet (stored, so that the sidebar badge and Dock badge stay current).
    @Published private(set) var runningJobCount = 0 {
        didSet { runningJobsChanged(from: oldValue) }
    }
    /// A lesson routine has not finished – also during the end-of-lesson countdown, when no job runs. Set by
    /// ClassroomModel; quitting or closing the last window must not silently drop its remaining steps.
    @Published var lessonInProgress = false {
        didSet { if lessonInProgress != oldValue { runningJobsChanged(from: runningJobCount) } }
    }
    /// Jobs or a lesson routine are running: quitting the app would cut them short.
    var hasRunningWork: Bool { runningJobCount > 0 || lessonInProgress }
    /// Host keys waiting for the user's decision (HostTrustSheet).
    @Published var hostTrustReview: HostTrustReview?
    /// Macs whose first-contact question was answered with "Nie teraz" in this session: not asked again automatically.
    var hostTrustPostponed = Set<UUID>()
    /// Macs whose last status check was refused because their key was never trusted.
    var untrustedHosts = Set<UUID>()
    /// Of those, the ones found since the last offer (`offerTrustForNewHosts`).
    var newlyUntrustedHosts = Set<UUID>()
    /// Skip hosts known to be offline or failing to log in instead of waiting for their timeouts.
    @Published var skipUnreachable = TargetUIState.skipUnreachable {
        didSet { TargetUIState.skipUnreachable = skipUnreachable }
    }
    @Published var toast: ActionToast?
    /// Batch the Jobs view should show (set by "Pokaż" in the toast or the activity popover).
    @Published var focusedBatchID: UUID?
    var pendingSkip: (ids: Set<UUID>, reason: Job.SkipReason)?
    var pendingConfirmation: BatchConfirmation?
    /// Confirmation asked before repeating a confirmed batch (presented by ContentView).
    @Published var retryConfirmation: ConfirmRequest?
    /// Last reachability other than `.checking`: a re-check must not make offline hosts count as reachable.
    var settledReachability: [UUID: Reachability] = [:]
    var sleepActivity: NSObjectProtocol?
    var toastTask: Task<Void, Never>?
    @Published var runningApps: [UUID: HostApps] = [:]
    @Published var installedApps: [UUID: [String]] = [:]
    @Published var updates: [UUID: UpdateInfo] = [:]
    @Published var hasSharedPassword = false

    // Drafts kept while switching sections.
    @Published var commandDraft = "whoami; ls -l ~/"
    @Published var commandAsRoot = false
    @Published var pushItems: [URL] = []
    @Published var installItems: [URL] = []
    /// Installs also packages and apps without a valid Apple signature and notarization (in-house installers).
    /// Off by default and not saved: the teacher switches it on for a trusted installer only.
    @Published var installAllowUnsigned = false
    lazy var files = FilesState(app: self)

    /// Screen preview engine (ScreenCenter.swift).
    lazy var screens = ScreenCenter(model: self)
    let askpassPath = ConfigStore.ensureAskpass()

    init() {
        machines = ConfigStore.loadHosts()
        settings = ConfigStore.loadSettings()
        configIssues = ConfigStore.loadIssues
        hasSharedPassword = Keychain.exists(Keychain.sharedAccount)
        selection = TargetUIState.selection.intersection(machines.map(\.id))
        AppModel.shared = self
        JobHistory.purgeInBackground()
        observeAppActivation()
        // Start-up hooks for scripted UI checks: CMCR_SECTION=<section>, CMCR_SELECT_ALL=1.
        let env = ProcessInfo.processInfo.environment
        if let s = env["CMCR_SECTION"].flatMap(AppSection.init(rawValue:)) { section = s }
        if env["CMCR_SELECT_ALL"] == "1" { selection = Set(machines.map(\.id)) }
    }

    // MARK: - Basics

    var sshSettings: SSHSettings { SSHSettings(settings, askpassPath: askpassPath) }

    var selectedMachines: [Machine] { machines.filter { selection.contains($0.id) } }

    func status(_ m: Machine) -> HostStatus { statuses[m.id] ?? HostStatus() }

    func password(for m: Machine) -> String? { Keychain.password(for: m) }

    func machine(_ id: UUID) -> Machine? { machines.first { $0.id == id } }

    func setSharedPassword(_ pw: String) {
        let saved = Keychain.set(pw, for: Keychain.sharedAccount)
        hasSharedPassword = saved ? !pw.isEmpty : Keychain.exists(Keychain.sharedAccount)
        if !saved { keychainError = Self.keychainFailure(removing: pw.isEmpty) }
        if saved && !pw.isEmpty { recheckAfterCredentialChange(machines) }
    }

    func setPassword(_ pw: String, for m: Machine) {
        if !Keychain.set(pw, for: Keychain.account(for: m)) {
            keychainError = Self.keychainFailure(removing: pw.isEmpty)
        } else if !pw.isEmpty {
            recheckAfterCredentialChange([m])
        }
    }

    private static func keychainFailure(removing: Bool) -> String {
        (removing ? "Nie udało się usunąć hasła z Pęku kluczy." : "Nie udało się zapisać hasła w Pęku kluczy.")
            + " Sprawdź, czy pęk kluczy „login” jest odblokowany (aplikacja Dostęp do pęku kluczy), i spróbuj ponownie."
    }

    // MARK: - Batch execution

    /// Runs `operation` on every target with limited parallelism and records the results as a batch.
    /// Hosts known to be unreachable are skipped (unless `includeUnreachable`, e.g. Wake-on-LAN) when
    /// `skipUnreachable` is on; they stay in the batch as skipped jobs, so "Powtórz" can pick them up later.
    /// A retry is an explicit request and always tries every host it is given.
    /// `maxParallel` overrides the setting for jobs that mostly wait (questions, waking up).
    @discardableResult
    func runBatch(_ title: String, on targets: [Machine], section: AppSection? = nil, maxParallel: Int? = nil,
                  includeUnreachable: Bool = false,
                  operation: @escaping @MainActor (Machine, Job) async -> CommandResult,
                  completion: (@MainActor (Batch) -> Void)? = nil) -> Batch? {
        guard !targets.isEmpty else { return nil }
        let jobs = targets.map { Job(machine: $0) }
        for job in jobs {
            if let skip = pendingSkip, skip.ids.contains(job.machine.id) {
                job.skip(skip.reason)
            } else if !includeUnreachable, willSkip(job.machine) {
                job.skip(.unreachable(knownReachability(job.machine)))
            }
        }
        let owner = section ?? self.section
        let batch = Batch(title: title, jobs: jobs, section: owner)
        batch.completed = batch.skipped
        batch.confirmation = pendingConfirmation
        batch.rerun = { [weak self] hosts in
            guard let self else { return }
            let retry = self.runBatch(Self.retryTitle(title), on: hosts, section: owner, maxParallel: maxParallel,
                                      includeUnreachable: true, operation: operation, completion: completion)
            if self.section == .jobs, let retry { self.focusedBatchID = retry.id }
        }
        batches.insert(batch, at: 0)
        trimBatches()
        if let owner { lastBatch[owner] = batch }
        let active = jobs.filter { !$0.isFinished }
        runningJobCount += active.count
        ConfigStore.log("\(title) → \(targets.map(\.name).joined(separator: ", "))"
                        + (batch.skipped > 0 ? " (pominięto: \(jobs.filter { $0.state == .skipped }.map(\.machine.name).joined(separator: ", ")))" : ""))
        jobs.filter { $0.state == .skipped }.forEach { archive($0, in: batch) }
        announce(batch)
        let limit = max(1, maxParallel ?? settings.maxParallel)

        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for job in active {
                    if running >= limit {
                        await group.next()
                        running -= 1
                    }
                    group.addTask { await self.execute(job, in: batch, operation: operation) }
                    running += 1
                }
            }
            batch.finishedAt = Date()
            batch.finished = true
            // Views that only observe the model (sidebar sections, "Wyczyść zakończone") must see the change.
            objectWillChange.send()
            completion?(batch)
            batchFinished(batch)
        }
        return batch
    }

    private func execute(_ job: Job, in batch: Batch,
                         operation: @MainActor (Machine, Job) async -> CommandResult) async {
        defer {
            batch.completed += 1
            runningJobCount -= 1
            archive(job, in: batch)
        }
        if job.handle.isCancelled {
            job.state = .cancelled
            job.summary = "Anulowano"
            return
        }
        job.state = .running
        job.startedAt = Date()
        let r = await operation(job.machine, job)
        job.flushIncoming()
        job.finishedAt = Date()
        job.exitCode = r.exitCode
        if r.cancelled || job.handle.isCancelled {
            job.state = .cancelled
            job.summary = "Anulowano"
        } else if r.succeeded {
            job.state = .succeeded
            job.summary = job.lastLine.isEmpty ? "OK" : job.lastLine
        } else {
            job.state = .failed
            let (reach, message) = SSH.diagnose(r)
            let stderr = r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty && !job.output.contains(stderr) { job.append(stderr + "\n") }
            let detail = message.hasPrefix("Polecenie zakończone") && !job.lastLine.isEmpty
                ? "\(job.lastLine) (kod \(r.exitCode))" : message
            job.summary = detail
            job.note(detail)
            if reach != .online {
                var st = statuses[job.machine.id] ?? HostStatus()
                st.reachability = reach
                st.message = message
                statuses[job.machine.id] = st
            }
        }
    }

    /// Output kept per job result; the job log itself is capped separately (Job.maxOutput).
    static let jobCapture = 4 << 20

    /// Runs a remote script on one Mac, streaming its output into the job. Cancelling the job also stops
    /// the command on the Mac; a lost connection does not.
    func ssh(_ script: RemoteScript, on m: Machine, job: Job, timeout: TimeInterval? = nil,
             stdoutFile: URL? = nil) async -> CommandResult {
        await SSH.run(script, on: m, password: password(for: m), settings: sshSettings, stdoutFile: stdoutFile,
                      timeout: timeout, handle: job.handle, retry: .job, maxCapture: Self.jobCapture,
                      onOutput: OutputSink(job).callback)
    }

    @discardableResult
    func runScript(_ title: String, on targets: [Machine], section: AppSection? = nil, includeUnreachable: Bool = false,
                   timeout: TimeInterval? = nil,
                   script: @escaping (Machine) -> RemoteScript,
                   onResult: (@MainActor (Machine, CommandResult) -> Void)? = nil) -> Batch? {
        runBatch(title, on: targets, section: section, includeUnreachable: includeUnreachable) { m, job in
            let r = await self.ssh(script(m), on: m, job: job, timeout: timeout)
            onResult?(m, r)
            return r
        }
    }

    func clearFinishedBatches() {
        batches.removeAll { $0.finished }
        lastBatch = lastBatch.filter { !$0.value.finished }
        if let id = focusedBatchID, !batches.contains(where: { $0.id == id }) { focusedBatchID = nil }
    }

    // MARK: - Status

    /// Macs whose check is running: a new refresh skips them (no duplicate probes, no out-of-order results).
    private var statusInFlight = Set<UUID>()
    /// Macs that are off whose ssh port is being probed in the background.
    private var portProbes = Set<UUID>()
    /// Failed background checks in a row of Macs that are off, and when to check them again.
    private var offlineStreak: [UUID: Int] = [:]
    private var nextQuietProbe: [UUID: Date] = [:]
    private var lastQuietRefresh = Date.distantPast
    private var activationObserver: NSObjectProtocol?

    /// `quietly` is the background refresh: it pauses while no window can be seen, and a Mac that is off gets
    /// a full check less and less often (up to every 10 min); in between only its ssh port is probed (a TCP
    /// connect, no login), so a Mac that was switched on shows up in the next background round. An explicit
    /// refresh always checks every target.
    func refreshStatus(_ targets: [Machine]? = nil, quietly: Bool = false) {
        let now = Date()
        if quietly {
            // Every window runs its own refresh loop; one background round per minute is enough.
            guard isWindowVisible, now.timeIntervalSince(lastQuietRefresh) >= 60 else { return }
            lastQuietRefresh = now
        }
        let list = (targets ?? machines).filter {
            !statusInFlight.contains($0.id) && !(quietly && portProbes.contains($0.id))
        }
        guard !list.isEmpty else { return }
        let probeFirst = Set(list.filter { quietly && (nextQuietProbe[$0.id] ?? .distantPast) > now }.map(\.id))
        statusInFlight.formUnion(list.map(\.id).filter { !probeFirst.contains($0) })
        portProbes.formUnion(probeFirst)
        for m in list where !probeFirst.contains(m.id) && (!quietly || statuses[m.id] == nil) {
            var st = statuses[m.id] ?? HostStatus()
            st.reachability = .checking
            statuses[m.id] = st
        }
        let ss = sshSettings
        let timeout = OperationTimeout.status(connectTimeout: settings.connectTimeout)
        let jobs = list.map { ($0, password(for: $0)) }
        Task {
            defer { offerTrustForNewHosts() }
            await withTaskGroup(of: Void.self) { group in
                var active = 0
                for (m, pw) in jobs {
                    if active >= 16 {
                        await group.next()
                        active -= 1
                    }
                    group.addTask {
                        if probeFirst.contains(m.id) {
                            let answers = await SSH.portAnswers(m, settings: ss) == true
                            guard await self.finishPortProbe(m, answered: answers) else { return }
                        }
                        let r = await SSH.run(Scripts.status(), on: m, password: pw, settings: ss, timeout: timeout)
                        await self.applyStatus(m, r)
                    }
                    active += 1
                }
            }
        }
    }

    /// Returns whether to run the full check now (the port answered and no other check has started meanwhile).
    private func finishPortProbe(_ m: Machine, answered: Bool) -> Bool {
        portProbes.remove(m.id)
        guard answered, !statusInFlight.contains(m.id) else { return false }
        statusInFlight.insert(m.id)
        return true
    }

    /// After a status check: Macs that have just been refused because their key was never trusted (first contact
    /// at start, a Mac added to the list) are offered in HostTrustSheet – once, and not again after "Nie teraz"
    /// in this session. A changed key is never offered by itself: it needs a deliberate look in
    /// Konfiguracja › Przygotowanie iMaców.
    private func offerTrustForNewHosts() {
        let candidates = machines.filter { newlyUntrustedHosts.contains($0.id) && !hostTrustPostponed.contains($0.id) }
        newlyUntrustedHosts = []
        guard !candidates.isEmpty else { return }
        reviewHostKeys(candidates, automatic: true)
    }

    private func applyStatus(_ m: Machine, _ r: CommandResult) {
        statusInFlight.remove(m.id)
        if !r.started, HostTrust.refusal(r) == .unknown {
            if untrustedHosts.insert(m.id).inserted { newlyUntrustedHosts.insert(m.id) }
        } else {
            untrustedHosts.remove(m.id)
        }
        var st = HostStatus()
        st.updatedAt = Date()
        if r.succeeded {
            st.reachability = .online
            st.info = Parsers.keyValues(r.stdoutText)
            if let mac = st.mac, let i = machines.firstIndex(where: { $0.id == m.id }), machines[i].macAddress.isEmpty {
                machines[i].macAddress = mac
            }
            offlineStreak[m.id] = nil
            nextQuietProbe[m.id] = nil
        } else {
            let (reach, message) = SSH.diagnose(r)
            st.reachability = reach == .online ? .error : reach
            st.message = message
            st.info = statuses[m.id]?.info ?? [:]
            if reach == .offline {
                // Full background checks after 2, 4, 8 and then every 10 min (minus slack for the 2 min timer).
                let n = (offlineStreak[m.id] ?? 0) + 1
                offlineStreak[m.id] = n
                let delay = min(120 * pow(2, Double(min(n, 4) - 1)), 600) - 30
                nextQuietProbe[m.id] = Date().addingTimeInterval(delay)
            }
        }
        statuses[m.id] = st
    }

    private var isWindowVisible: Bool {
        NSApp.isActive || NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    /// Catches up on the background refresh that was skipped while the app was hidden; Macs that were off
    /// get a full check again (they may have been switched on in the meantime).
    private func observeAppActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastQuietRefresh) > 120 else { return }
                self.nextQuietProbe = [:]
                self.refreshStatus(quietly: true)
            }
        }
    }

    // MARK: - Shared SSH connections

    /// Settings and Mac entries as they were before the latest edits. Every keystroke in a settings field
    /// changes the model, so the shared connections opened with them are retired once editing pauses.
    private var sshSettingsBeforeEdit: SSHSettings?
    private var machinesBeforeEdit: [UUID: Machine] = [:]
    private var retireConnectionsTask: Task<Void, Never>?

    /// A shared connection keeps the key, options and address it was opened with; retire it when they change.
    private func closeStaleConnections(oldSettings: AppSettings) {
        if sshSettingsBeforeEdit == nil { sshSettingsBeforeEdit = SSHSettings(oldSettings, askpassPath: askpassPath) }
        scheduleStaleConnectionClose()
    }

    private func closeStaleConnections(oldMachines: [Machine]) {
        let current = Dictionary(machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for old in oldMachines where machinesBeforeEdit[old.id] == nil {
            let now = current[old.id]
            if now?.destination != old.destination || now?.port != old.port {
                machinesBeforeEdit[old.id] = old
                changed = true
            }
        }
        if changed { scheduleStaleConnectionClose() }
    }

    private func scheduleStaleConnectionClose() {
        retireConnectionsTask?.cancel()
        retireConnectionsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.closeStaleConnectionsNow()
        }
    }

    private func closeStaleConnectionsNow() {
        let new = sshSettings
        let old = sshSettingsBeforeEdit ?? new
        let current = Dictionary(machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var hosts = machinesBeforeEdit.values.filter { before in
            let now = current[before.id]
            return now?.destination != before.destination || now?.port != before.port
        }
        if old.identityFile != new.identityFile || old.extraOptions != new.extraOptions
            || old.reuseConnections != new.reuseConnections {
            hosts += machines
        }
        sshSettingsBeforeEdit = nil
        machinesBeforeEdit = [:]
        guard !hosts.isEmpty else { return }
        Task.detached { await SSH.closeMasters(hosts, settings: old) }
    }

    // MARK: - Commands

    func runCommand(_ text: String, asRoot: Bool, on targets: [Machine]) {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let title = "\(asRoot ? "[root] " : "")\(firstLine.prefix(60))"
        runScript(title, on: targets) { _ in RemoteScript(text, asRoot: asRoot) }
    }

    /// cmcr-go: interactive ssh session in Terminal.app. Every host field in the script is quoted
    /// (`SSH.terminalScript`): an address from an imported list must never run as shell code.
    func openTerminal(_ m: Machine) {
        let script = SSH.terminalScript(for: m, settings: sshSettings)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(SSH.terminalFileName(for: m))
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
            NSWorkspace.shared.open(url)
            ConfigStore.log("Sesja SSH (Terminal) → \(m.name)")
        } catch {
            NSSound.beep()
        }
    }

    /// Opens the built-in Screen Sharing app (VNC) – full remote view/control, if enabled on the Mac.
    func openScreenSharing(_ m: Machine) {
        if let url = URL(string: "vnc://\(m.user)@\(m.address)") {
            NSWorkspace.shared.open(url)
            ConfigStore.log("Udostępnianie ekranu (VNC) → \(m.name)")
        }
    }

    // MARK: - Files

    func ownerString(_ choice: OwnerChoice, custom: String) -> String {
        switch choice {
        case .keep: return ""
        case .student: return settings.studentUser
        case .console: return "{console}"
        case .admin: return "root:admin"
        case .custom: return custom
        }
    }

    func pushFiles(_ items: [URL], destination: String, owner: String, mode: String, asRoot: Bool,
                   on targets: [Machine]) {
        guard !targets.isEmpty, !items.isEmpty else { return }
        let dest = settings.resolve(destination)
        let payload = SharedPayload(items)
        runBatch("Wysyłanie \(items.count) el. → \(dest)", on: targets, operation: { m, job in
            await payload.use { url in
                await Operations.push(payload: url, to: m, destination: dest, owner: owner, mode: mode,
                                      asRoot: asRoot, password: self.password(for: m),
                                      settings: self.sshSettings, handle: job.handle,
                                      onOutput: OutputSink(job).callback)
            }
        }, completion: { _ in payload.discard() })
    }

    /// cmcr-push convention: `<local>/all/*` and `<local>/<host>/*` → shared folder on each host.
    func pushConvention(on targets: [Machine], includeAll: Bool) {
        let base = settings.localFolder
        let dest = settings.sharedFolder
        let owner = settings.studentUser
        runBatch("cmcr-push → \(dest)", on: targets) { m, job in
            let items = Operations.conventionItems(base: base, host: m, includeAll: includeAll)
            if items.isEmpty {
                job.note("Brak plików w \(base)/all ani \(base)/\(m.folderKey) – nic do wysłania.")
                return CommandResult(exitCode: 0)
            }
            job.note("Elementy: \(items.map(\.lastPathComponent).joined(separator: ", "))")
            switch await Payload.make(items) {
            case .failure(let e):
                return .failure(e.localizedDescription)
            case .success(let payload):
                defer { try? FileManager.default.removeItem(at: payload) }
                return await Operations.push(payload: payload, to: m, destination: dest, owner: owner, mode: "777",
                                             asRoot: true, password: self.password(for: m),
                                             settings: self.sshSettings, handle: job.handle,
                                             onOutput: OutputSink(job).callback)
            }
        }
    }

    /// cmcr-pull: remote folder → `<local>/<host>`.
    func pullFiles(source: String, localBase: String, asRoot: Bool, on targets: [Machine]) {
        let src = settings.resolve(source)
        let base = URL(fileURLWithPath: expandTilde(localBase), isDirectory: true)
        runBatch("Pobieranie \(src) → \(localBase)", on: targets) { m, job in
            await Operations.pull(source: src, from: m, into: base.appendingPathComponent(m.folderKey),
                                  asRoot: asRoot, password: self.password(for: m), settings: self.sshSettings,
                                  handle: job.handle, onOutput: OutputSink(job).callback)
        }
    }

    func prepareLocalFolders() {
        do {
            let url = try Operations.prepareLocalFolders(base: settings.localFolder, hosts: machines)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    func openLocalFolder(_ path: String) {
        let url = URL(fileURLWithPath: expandTilde(path), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Applications

    func refreshRunningApps(_ targets: [Machine]) {
        let ss = sshSettings
        let jobs = targets.map { ($0, password(for: $0)) }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for (m, pw) in jobs {
                    group.addTask {
                        let r = await SSH.run(Scripts.runningApps(), on: m, password: pw, settings: ss,
                                              timeout: OperationTimeout.list)
                        await MainActor.run {
                            if r.succeeded {
                                let parsed = Parsers.runningApps(r.stdoutText)
                                self.runningApps[m.id] = HostApps(user: parsed.user, apps: parsed.apps)
                            } else {
                                self.runningApps[m.id] = HostApps(error: SSH.diagnose(r).1)
                            }
                        }
                    }
                }
            }
        }
    }

    func refreshInstalledApps(_ targets: [Machine]) {
        let ss = sshSettings
        let jobs = targets.map { ($0, password(for: $0)) }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for (m, pw) in jobs {
                    group.addTask {
                        let r = await SSH.run(Scripts.installedApps(), on: m, password: pw, settings: ss,
                                              timeout: OperationTimeout.list)
                        await MainActor.run {
                            if r.succeeded { self.installedApps[m.id] = Parsers.lines(r.stdoutText) }
                        }
                    }
                }
            }
        }
    }

    func launchApp(_ name: String, arguments: String = "", on targets: [Machine]) {
        runScript("Uruchom: \(name)", on: targets, script: { _ in Scripts.launchApp(name, arguments: arguments) }) { m, _ in
            self.scheduleAppsRefresh(m)
        }
    }

    func quitApp(_ name: String, force: Bool, on targets: [Machine]) {
        runScript("\(force ? "Wymuś zamknięcie" : "Zamknij"): \(name)", on: targets,
                  script: { _ in Scripts.quitApp(name, force: force) }) { m, _ in
            self.scheduleAppsRefresh(m)
        }
    }

    func kill(_ app: RunningApp, on m: Machine, force: Bool) {
        runScript("\(force ? "Wymuś zamknięcie" : "Zamknij"): \(app.name) (PID \(app.pid))", on: [m],
                  script: { _ in force ? Scripts.killProcess(app.pid, force: true) : Scripts.quitApp(app.bundlePath, force: false) }) { m, _ in
            self.scheduleAppsRefresh(m)
        }
    }

    func openURL(_ url: String, on targets: [Machine]) {
        runScript("Otwórz: \(url)", on: targets) { _ in Scripts.openURL(url) }
    }

    func uninstall(_ path: String, on targets: [Machine]) {
        runScript("Odinstaluj: \((path as NSString).lastPathComponent)", on: targets,
                  script: { _ in Scripts.uninstallApp(path) }) { m, _ in
            self.refreshInstalledApps([m])
        }
    }

    private func scheduleAppsRefresh(_ m: Machine) {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.refreshRunningApps([m])
        }
    }

    // MARK: - Installing

    func installPackages(_ items: [URL], on targets: [Machine]) {
        guard !targets.isEmpty else { return }
        let payload = SharedPayload(items)
        let allowUnsigned = installAllowUnsigned
        runBatch("Instalacja: \(items.map(\.lastPathComponent).joined(separator: ", "))", on: targets, operation: { m, job in
            await payload.use { url in
                await Operations.install(payload: url, on: m, allowUnsigned: allowUnsigned, password: self.password(for: m),
                                         settings: self.sshSettings, handle: job.handle,
                                         onOutput: OutputSink(job).callback)
            }
        }, completion: { _ in payload.discard() })
    }

    // MARK: - Updates

    func checkUpdates(_ targets: [Machine]) {
        runScript("Sprawdzanie aktualizacji macOS", on: targets, timeout: OperationTimeout.updateList,
                  script: { _ in Scripts.listUpdates() }) { m, r in
            if r.succeeded || !r.stdout.isEmpty {
                self.updates[m.id] = UpdateInfo(titles: Parsers.softwareUpdates(r.stdoutText), raw: r.stdoutText)
            }
        }
    }

    // MARK: - Power & session

    func power(_ action: PowerAction, on targets: [Machine]) {
        runScript(action.label, on: targets) { _ in Scripts.power(action) }
    }

    func wake(_ targets: [Machine]) {
        ClassroomModel.shared.wake(self, targets)
    }

    // MARK: - Setup

    func distributeKey(_ targets: [Machine]) {
        guard let key = SSHKeys.currentPrivateKey(settings: settings), let pub = SSHKeys.publicKey(for: key) else {
            NSSound.beep()
            return
        }
        runScript("Dystrybucja klucza SSH (\(key.lastPathComponent).pub)", on: targets, includeUnreachable: true,
                  script: { _ in Scripts.distributeKey(pub) },
                  onResult: { [weak self] m, r in self?.recheckAfterLogin(m, r) })
    }

    // MARK: - Host keys (first contact, reinstalled Macs)

    /// Fetches the key each Mac presents (no login, no password) and asks the user to trust it in
    /// HostTrustSheet, with its fingerprint and – for a changed key – the one trusted before.
    /// `automatic`: offered after a status check found Macs that were never trusted.
    func reviewHostKeys(_ targets: [Machine], automatic: Bool = false) {
        guard !targets.isEmpty else { return }
        if let open = hostTrustReview {
            // One sheet at a time: add the Macs to the one already shown.
            let known = Set(open.entries.map(\.machine.id))
            let added = targets.filter { !known.contains($0.id) }
            guard !added.isEmpty else { return }
            open.entries += added.map { HostTrustReview.Entry(machine: $0) }
            scanHostKeys(added, into: open)
            return
        }
        let review = HostTrustReview(machines: targets, automatic: automatic)
        hostTrustReview = review
        scanHostKeys(targets, into: review)
    }

    private func scanHostKeys(_ targets: [Machine], into review: HostTrustReview) {
        let ss = sshSettings
        Task {
            await withTaskGroup(of: Void.self) { group in
                var active = 0
                for m in targets {
                    if active >= 8 {
                        await group.next()
                        active -= 1
                    }
                    group.addTask {
                        let scan = await HostTrust.scan(m, settings: ss)
                        await MainActor.run { review.setScan(scan) }
                    }
                    active += 1
                }
            }
        }
    }

    /// Trusts the keys the user confirmed in `review` (exactly the scanned ones), then checks those Macs again.
    /// The sheet closes when every key was saved; otherwise it stays open with the reason next to the Mac.
    func trustHostKeys(in review: HostTrustReview) async {
        let scans = review.chosenScans
        guard !scans.isEmpty, !review.saving else { return }
        review.saving = true
        defer { review.saving = false }
        let ss = sshSettings
        var trusted: [Machine] = []
        // One after another: every trust rewrites the same known_hosts file.
        for scan in scans {
            let r = await HostTrust.trust(scan, settings: ss)
            if r.succeeded {
                trusted.append(scan.host)
                review.markTrusted(scan.host.id)
            } else {
                review.setError(scan.host.id, r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        hostTrustPostponed.subtract(trusted.map(\.id))
        if !trusted.isEmpty {
            showToast(ActionToast(message: "Zaufano kluczom: \(trusted.map(\.name).joined(separator: ", "))",
                                  icon: "checkmark.shield.fill"))
            refreshStatus(trusted)
        }
        if trusted.count == scans.count, hostTrustReview === review { hostTrustReview = nil }
    }

    /// "Nie teraz": the automatic question is not repeated for these Macs until the app restarts.
    func postponeHostTrust(_ review: HostTrustReview) {
        if review.automatic { hostTrustPostponed.formUnion(review.entries.map(\.machine.id)) }
    }

    /// Removes the Macs' trusted keys (cmcrctl __forget-host-key does the same); connections are then refused
    /// until a key is trusted again. Kept for scripted checks; the app offers `reviewHostKeys` instead.
    func forgetHostKeys(_ targets: [Machine]) {
        runBatch("Zapomnij klucz komputera (known_hosts)", on: targets, includeUnreachable: true) { m, job in
            let r = await SSHKeys.forgetHostKey(m, settings: self.sshSettings)
            job.append(r.stdoutText + r.stderrText)
            return r
        }
    }
}
