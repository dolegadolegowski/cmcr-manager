import AppKit
import CMCRCore
import Combine
import SwiftUI

/// Progress of one lesson routine: one row per Mac, one column per step. Mutated on the main thread only.
final class LessonRun: ObservableObject, Identifiable, @unchecked Sendable {
    let id = UUID()
    let plan: LessonPlan
    let machines: [Machine]
    let startedAt = Date()
    @Published var states: [UUID: [StepState]]
    @Published var countdownEnd: Date?
    @Published var finished = false
    @Published var phase = ""
    var batches: [Batch] = []
    private(set) var cancelled = false
    var skipCountdown = false
    /// The end-of-lesson countdown (and the steps after it) was started. A repeated warning batch – "Powtórz na
    /// nieudanych" reuses its completion – must not start them a second time.
    var restScheduled = false

    init(plan: LessonPlan, machines: [Machine]) {
        self.plan = plan
        self.machines = machines
        states = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, Array(repeating: StepState.pending, count: plan.steps.count)) })
    }

    func update(_ host: UUID, _ index: Int, _ state: StepState) {
        guard var row = states[host], row.indices.contains(index) else { return }
        row[index] = state
        states[host] = row
    }

    func cancel() {
        cancelled = true
        countdownEnd = nil
        batches.forEach { $0.cancel() }
    }

    func state(_ host: UUID, _ index: Int) -> StepState { states[host]?[index] ?? .pending }

    /// Marks the run finished; steps that never ran (cancelled, or a phase that was not started) are skipped.
    func complete() {
        for (id, row) in states where row.contains(where: { !$0.isFinished }) {
            states[id] = row.map { $0.isFinished ? $0 : .skipped(cancelled ? "anulowano" : "nie wykonano") }
        }
        countdownEnd = nil
        phase = "Zakończono"
        finished = true
    }

    var progress: Double {
        let total = machines.count * max(1, plan.steps.count)
        let done = states.values.reduce(0) { $0 + $1.filter(\.isFinished).count }
        return Double(done) / Double(max(1, total))
    }

    var failedHosts: Int {
        states.values.filter { $0.contains { if case .failed = $0 { return true } else { return false } } }.count
    }
}

struct LockInfo {
    var mode: String
    var since: Date
    var autoUnlockAt: Date?

    var label: String { mode == "lockscreen" ? "blokada systemowa" : "komunikat na pełnym ekranie" }
}

/// One "Zapytaj uczniów" round. Mutated on the main thread only.
final class QuestionRound: ObservableObject, Identifiable, @unchecked Sendable {
    let id = UUID()
    let question: String
    let machines: [Machine]
    let askedAt = Date()
    @Published var answers: [UUID: StudentAnswer] = [:]
    @Published var answeredAt: [UUID: Date] = [:]
    @Published var errors: [UUID: String] = [:]
    var batch: Batch?

    init(question: String, machines: [Machine]) {
        self.question = question
        self.machines = machines
    }

    var pending: Int { machines.filter { answers[$0.id] == nil && errors[$0.id] == nil }.count }
}

struct ScheduleInfo {
    var events: [RepeatingPowerEvent] = []
    var policy: [String: String] = [:]
    var error: String?
    var checkedAt = Date()
}

struct ComputerNameInfo {
    var computerName: String
    var localHostName: String
    var hostName: String
}

struct AppVersionsResult {
    var appName: String
    var results: [UUID: [AppVersionInfo]] = [:]
    var errors: [UUID: String] = [:]
    var pending: Set<UUID> = []
}

/// State and actions of the classroom features (Zajęcia, tryb uwagi, harmonogram, nazwy, raporty).
/// Lives as long as the app, independent of the visible section.
@MainActor
final class ClassroomModel: ObservableObject {
    static let shared = ClassroomModel()

    @Published var config: ClassroomConfig {
        didSet { if config != oldValue { scheduleSave() } }
    }
    @Published var run: LessonRun?
    @Published var locks: [UUID: LockInfo] = [:]
    @Published var question: QuestionRound?
    @Published var schedules: [UUID: ScheduleInfo] = [:]
    @Published var fileVault: [UUID: Bool] = [:]
    @Published var lastSeen: [UUID: Date] = [:]
    @Published var names: [UUID: ComputerNameInfo] = [:]
    @Published var appVersions: AppVersionsResult?

    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var saveWork: DispatchWorkItem?

    private init() {
        config = ClassroomStore.loadConfig()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = config
        let work = DispatchWorkItem { ClassroomStore.saveConfig(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Last-known state

    /// Restores the statuses saved by the previous run and keeps saving them (debounced).
    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        let snapshots = ClassroomStore.loadSnapshots()
        for m in model.machines {
            guard model.statuses[m.id] == nil, let snap = snapshots[m.id] else { continue }
            model.statuses[m.id] = snap.restored
        }
        lastSeen = snapshots.compactMapValues(\.lastSeen)
        model.$statuses
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] statuses in self?.persist(statuses) }
            .store(in: &cancellables)
    }

    private func persist(_ statuses: [UUID: HostStatus]) {
        guard let model else { return }
        var snapshots: [UUID: HostSnapshot] = [:]
        for m in model.machines {
            guard let st = statuses[m.id] else { continue }
            if st.reachability == .online { lastSeen[m.id] = st.updatedAt ?? Date() }
            if st.info.isEmpty && lastSeen[m.id] == nil { continue }
            var snap = HostSnapshot(st, lastSeen: lastSeen[m.id])
            if snap.reachability == .checking { snap.reachability = .unknown }
            snapshots[m.id] = snap
        }
        DispatchQueue.global(qos: .utility).async { ClassroomStore.saveSnapshots(snapshots) }
    }

    // MARK: - Wake-on-LAN

    /// MAC addresses to wake a Mac with: the Ethernet MAC reported by the status script first, then the one
    /// stored in the host list, then the MAC of the default-route interface.
    func wakeMACs(_ m: Machine, status: HostStatus) -> [String] {
        var out: [String] = []
        for candidate in [status.info["mac_ethernet"], m.macAddress, status.mac] {
            guard let c = candidate, let mac = WakeOnLAN.normalizeMAC(c), !out.contains(mac) else { continue }
            out.append(mac)
        }
        return out
    }

    private func lessonHost(_ m: Machine, _ model: AppModel) -> LessonRunner.Host {
        let st = model.status(m)
        return LessonRunner.Host(machine: m, password: model.password(for: m), macs: wakeMACs(m, status: st),
                                 extraBroadcasts: st.ip.flatMap(WakeOnLAN.subnetBroadcast).map { [$0] } ?? [])
    }

    /// Sends magic packets for all hosts concurrently, off the main thread. Returns per-host errors.
    nonisolated static func sendWake(_ hosts: [LessonRunner.Host]) async -> [UUID: String] {
        await Task.detached(priority: .userInitiated) { () -> [UUID: String] in
            let lock = NSLock()
            var errors: [UUID: String] = [:]
            DispatchQueue.concurrentPerform(iterations: hosts.count) { i in
                let h = hosts[i]
                var failure: String? = h.macs.isEmpty
                    ? "Brak adresu MAC – odśwież stan, gdy komputer jest włączony, lub wpisz MAC w Konfiguracji." : nil
                var sent = false
                for mac in h.macs {
                    do {
                        try WakeOnLAN.wake(mac: mac, extraBroadcasts: h.extraBroadcasts)
                        sent = true
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                if sent { failure = nil }
                if let failure {
                    lock.lock()
                    errors[h.machine.id] = failure
                    lock.unlock()
                }
            }
            return errors
        }.value
    }

    /// Sends the magic packets (`sendWake`); tests replace it so that nothing goes out on the network.
    static var wakeSender: @Sendable ([LessonRunner.Host]) async -> [UUID: String] = { await sendWake($0) }

    /// Sends magic packets to every target at once, then waits (per Mac) until it answers over SSH.
    func wake(_ model: AppModel, _ targets: [Machine], section: AppSection? = nil) {
        let ss = model.sshSettings
        let send = Self.wakeSender
        // Waiting is cheap (a probe every few seconds), so every Mac waits at once – and every job starts at once,
        // so the packets still go out together. Each job sends its own packet: "Powtórz na nieudanych" reuses this
        // closure and must send again, with the MAC the host list has now (e.g. typed in Konfiguracja after a
        // "Brak adresu MAC"), not repeat the first attempt's result.
        model.runBatch("Wake-on-LAN", on: targets, section: section, maxParallel: targets.count,
                       includeUnreachable: true) { m, job in
            // A retry passes the batch's copy of the Mac; the host list entry may have changed since.
            let host = self.lessonHost(model.machine(m.id) ?? m, model)
            if let error = await send([host])[m.id] { return .failure(error) }
            job.note("Wysłano pakiet Wake-on-LAN (\(host.macs.joined(separator: ", "))) – czekam do 3 min, aż komputer odpowie.")
            let state = await LessonRunner.wake(host, ssh: ss, minutes: 3, handle: job.handle, onOutput: OutputSink(job).callback)
            switch state {
            case .done(let s):
                job.note(s.prefix(1).uppercased() + s.dropFirst())
                model.refreshStatus([m])
                return CommandResult(exitCode: 0)
            case .skipped(let s):
                return CommandResult(exitCode: -1, stderr: Data((s + "\n").utf8), cancelled: true)
            case .failed(let s):
                return .failure("Pakiet wysłany, ale komputer \(s).")
            default:
                return CommandResult(exitCode: 0)
            }
        }
    }

    // MARK: - Lesson routines

    /// Tells the app whether a lesson routine is still in progress (quitting and closing the last window ask
    /// first, also during the end-of-lesson countdown when no job runs).
    private func syncLessonState(_ model: AppModel) {
        model.lessonInProgress = !(run?.finished ?? true)
    }

    func startLesson(_ model: AppModel, targets: [Machine]) {
        let plan = LessonPlan.start(config.start, settings: model.settings)
        guard !plan.steps.isEmpty, !targets.isEmpty else { NSSound.beep(); return }
        let run = LessonRun(plan: plan, machines: targets)
        run.phase = "W toku"
        self.run = run
        syncLessonState(model)
        if plan.steps.contains(.wake) {
            // Wake everything at once; each Mac's job then only waits for its machine.
            let sleeping = targets.filter { model.status($0).reachability != .online }.map { lessonHost($0, model) }
            let send = Self.wakeSender
            if !sleeping.isEmpty { Task { _ = await send(sleeping) } }
        }
        var items: [URL] = []
        if plan.steps.contains(.materials) {
            items = materialItems(config.start.materialsFolder)
        }
        // Packed on first use and again for "Powtórz na nieudanych" after the cleanup (a retry reuses the batch's
        // operation, so a one-off archive would already be deleted then).
        let payload = items.isEmpty ? nil : SharedPayload(items)
        // Macs that are still waking up must not hold back the ones that are ready: waking runs for all Macs at
        // once, the other steps share the usual number of parallel connections.
        let limiter = plan.steps.contains(.wake) ? ConcurrencyLimiter(limit: model.settings.maxParallel) : nil
        launch(plan, run: run, title: "Rozpoczęcie zajęć", range: nil, model: model, payload: payload,
               limiter: limiter) { [weak self] in
            payload?.discard()          // deferred until no job (a retry included) uses the archive
            run.complete()
            self?.syncLessonState(model)
            model.refreshStatus(targets)
        }
    }

    func endLesson(_ model: AppModel, targets: [Machine]) {
        let plan = LessonPlan.end(config.end, settings: model.settings)
        guard !plan.steps.isEmpty, !targets.isEmpty else { NSSound.beep(); return }
        if let folder = plan.collectFolder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // What the confirmation sheet decided ("Pomiń komputery z zalogowanym użytkownikiem", the confirmed
        // button) is set only while this call runs; the steps after the countdown start later and need it too.
        let skip = model.pendingSkip
        let confirmation = model.pendingConfirmation
        let run = LessonRun(plan: plan, machines: targets)
        self.run = run
        syncLessonState(model)
        let finish = { [weak self] in
            run.complete()
            self?.syncLessonState(model)
            model.refreshStatus(targets)
        }
        let rest = { [weak self] in
            guard let self, !run.cancelled else { finish(); return }
            let first = plan.steps.first == .warn ? 1 : 0
            guard first < plan.steps.count else { finish(); return }
            run.phase = "W toku"
            model.perform(skipping: skip?.ids ?? [], reason: skip?.reason ?? .loggedInUser, confirmation: confirmation) {
                self.launch(plan, run: run, title: "Zakończenie zajęć", range: first..<plan.steps.count, model: model,
                            completion: finish)
            }
        }
        guard plan.steps.first == .warn else { rest(); return }
        run.phase = "Ostrzeżenie"
        launch(plan, run: run, title: "Zakończenie zajęć – ostrzeżenie", range: 0..<1, model: model) {
            // A retry of the warning only shows the message again: the countdown and the steps after it run once.
            guard !run.restScheduled else { return }
            run.restScheduled = true
            guard !run.cancelled else { finish(); return }
            let end = Date().addingTimeInterval(TimeInterval(max(1, plan.end.warnMinutes) * 60))
            run.countdownEnd = end
            run.phase = "Odliczanie"
            Task { @MainActor in
                while Date() < end && !run.skipCountdown && !run.cancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                run.countdownEnd = nil
                rest()
            }
        }
    }

    private func launch(_ plan: LessonPlan, run: LessonRun, title: String, range: Range<Int>?, model: AppModel,
                        payload: SharedPayload? = nil, limiter: ConcurrencyLimiter? = nil,
                        completion: @escaping @MainActor () -> Void) {
        let ss = model.sshSettings
        // A lesson that starts by waking the Macs must not skip the ones that are still asleep.
        let batch = model.runBatch(title, on: run.machines, section: .classroom,
                                   maxParallel: limiter == nil ? nil : run.machines.count,
                                   includeUnreachable: plan.steps.contains(.wake), operation: { m, job in
            // A retry passes the batch's copy of the Mac; the host list entry may have changed since.
            let host = self.lessonHost(model.machine(m.id) ?? m, model)
            let steps: @MainActor (URL?) async -> CommandResult = { materials in
                await LessonRunner.run(plan, on: host, ssh: ss, materials: materials, range: range, limiter: limiter,
                                       handle: job.handle, onOutput: OutputSink(job).callback) { index, state in
                    DispatchQueue.main.async { run.update(m.id, index, state) }
                }
            }
            guard let payload else { return await steps(nil) }
            return await payload.useIfAvailable { materials, failure in
                if let failure { job.note("Materiały: \(failure)") }
                return await steps(materials)
            }
        }, completion: { _ in
            // Step updates are queued on the main queue; run the completion after them.
            DispatchQueue.main.async { completion() }
        })
        guard let batch else { return }
        run.batches.append(batch)
        // Macs left out on purpose or known to be off never run their steps: say why in the lesson table.
        for job in batch.jobs where job.state == .skipped {
            let why = job.skipReason == .loggedInUser ? "pominięto – zalogowany użytkownik" : "pominięto – komputer niedostępny"
            for i in range ?? 0..<plan.steps.count { run.update(job.machine.id, i, .skipped(why)) }
        }
    }

    /// Files and folders inside the materials folder (the folder itself is not sent).
    func materialItems(_ folder: String) -> [URL] {
        guard !folder.isEmpty else { return [] }
        let url = URL(fileURLWithPath: expandTilde(folder), isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Attention mode

    func lock(_ model: AppModel, _ targets: [Machine]) {
        let message = config.lockMessage, mode = config.lockMode, minutes = config.autoUnlockMinutes
        model.runScript("Tryb uwagi: zablokuj ekrany", on: targets, section: .classroom,
                        script: { _ in Scripts.lockScreen(message: message, mode: mode, autoUnlockMinutes: minutes) }) { m, r in
            guard r.succeeded else { return }
            let used = r.stdoutText.split(whereSeparator: \.isNewline)
                .first { $0.hasPrefix("CMCR:LOCK:") }.map { String($0.dropFirst("CMCR:LOCK:".count)) } ?? ""
            if used == "lockscreen" || used == "overlay" {
                self.locks[m.id] = LockInfo(mode: used, since: Date(),
                                            autoUnlockAt: minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil)
            }
        }
    }

    func unlock(_ model: AppModel, _ targets: [Machine]) {
        model.runScript("Tryb uwagi: odblokuj ekrany", on: targets, section: .classroom,
                        script: { _ in Scripts.unlockScreen() }) { m, r in
            if r.succeeded { self.locks[m.id] = nil }
        }
    }

    func isLocked(_ id: UUID) -> Bool {
        guard let info = locks[id] else { return false }
        if let end = info.autoUnlockAt, end < Date() { return false }
        return true
    }

    // MARK: - Questions

    /// Shows the question on every target at once (each dialog keeps its connection open until the student
    /// answers, so the usual parallel limit would delay the question on the remaining Macs). Without `buttons`
    /// the student types the answer.
    func ask(_ model: AppModel, _ targets: [Machine], buttons: [String]) {
        let text = config.lastQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !targets.isEmpty else { return }
        let seconds = max(1, config.questionTimeoutMinutes) * 60
        let round = QuestionRound(question: text, machines: targets)
        question = round
        round.batch = model.runBatch("Pytanie: \(text.prefix(50))", on: targets, section: .classroom,
                                     maxParallel: targets.count) { m, job in
            let r = await model.ssh(Scripts.ask(title: "Pytanie od nauczyciela", prompt: text, buttons: buttons,
                                                 timeoutSeconds: seconds),
                                    on: m, job: job, timeout: TimeInterval(seconds + 60))
            if let answer = StudentAnswer.parse(r.stdoutText) {
                round.answers[m.id] = answer
                round.answeredAt[m.id] = Date()
            } else if !r.succeeded {
                round.errors[m.id] = SSH.diagnose(r).1
            }
            return r
        }
    }

    // MARK: - Delayed power

    func delayedPower(_ model: AppModel, _ action: PowerAction, minutes: Int, warning: String?, _ targets: [Machine]) {
        let title = minutes > 0 ? "\(action.label) za \(minutes) min" : action.label
        model.runScript(title, on: targets, section: .power) { _ in
            minutes > 0 ? Scripts.delayedPower(action, minutes: minutes, warning: warning) : Scripts.power(action)
        }
    }

    func cancelDelayedPower(_ model: AppModel, _ targets: [Machine]) {
        model.runScript("Anuluj zaplanowane wyłączenie/restart", on: targets, section: .power) { _ in
            Scripts.cancelDelayedPower()
        }
    }

    /// Asks each target (without a job entry) whether FileVault is on.
    func checkFileVault(_ model: AppModel, _ targets: [Machine]) {
        let ss = model.sshSettings
        for m in targets {
            let pw = model.password(for: m)
            Task {
                let r = await SSH.run(Scripts.fileVaultStatus(), on: m, password: pw, settings: ss, timeout: 25)
                guard r.succeeded else { return }
                let kv = Parsers.keyValues(r.stdoutText)
                self.fileVault[m.id] = kv["fv"] == "on"
                var st = model.statuses[m.id] ?? HostStatus()
                st.info["fv"] = kv["fv"]
                model.statuses[m.id] = st
            }
        }
    }

    // MARK: - Energy schedule

    func applySchedule(_ model: AppModel, _ targets: [Machine]) {
        let s = config.schedule, restart = config.autoRestartAfterPowerLoss, womp = config.wakeOnLAN
        model.runScript("Harmonogram zasilania: \(s.summary)", on: targets, section: .power,
                        script: { _ in Scripts.applyEnergySchedule(s, autoRestart: restart, wakeOnLAN: womp) }) { m, r in
            self.storeSchedule(m, r)
        }
    }

    func cancelSchedule(_ model: AppModel, _ targets: [Machine]) {
        model.runScript("Usuń harmonogram zasilania", on: targets, section: .power,
                        script: { _ in Scripts.cancelEnergySchedule() }) { m, r in
            self.storeSchedule(m, r)
        }
    }

    func loadSchedules(_ model: AppModel, _ targets: [Machine]) {
        let ss = model.sshSettings
        for m in targets {
            let pw = model.password(for: m)
            Task {
                let r = await SSH.run(Scripts.energyScheduleStatus(), on: m, password: pw, settings: ss, timeout: 30)
                self.storeSchedule(m, r)
            }
        }
    }

    private func storeSchedule(_ m: Machine, _ r: CommandResult) {
        if r.succeeded {
            schedules[m.id] = ScheduleInfo(events: PowerScheduleParser.repeating(r.stdoutText),
                                           policy: PowerScheduleParser.policy(r.stdoutText))
        } else {
            schedules[m.id] = ScheduleInfo(error: SSH.diagnose(r).1)
        }
    }

    // MARK: - Computer names

    func loadNames(_ model: AppModel, _ targets: [Machine]) {
        let ss = model.sshSettings
        for m in targets {
            let pw = model.password(for: m)
            Task {
                let r = await SSH.run(Scripts.computerNames(), on: m, password: pw, settings: ss, timeout: 25)
                guard r.succeeded else { return }
                let kv = Parsers.keyValues(r.stdoutText)
                self.names[m.id] = ComputerNameInfo(computerName: kv["cn"] ?? "", localHostName: kv["lhn"] ?? "",
                                                    hostName: kv["hn"] ?? "")
            }
        }
    }

    struct RenameEntry {
        var machine: Machine
        var computerName: String
        var localHostName: String
    }

    /// Renames the Macs; on success optionally updates the app's host list (name and `.local` address).
    func rename(_ model: AppModel, _ entries: [RenameEntry], updateList: Bool) {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.machine.id, $0) })
        model.runScript("Zmiana nazw komputerów", on: entries.map(\.machine), section: .dashboard,
                        script: { m in
                            let e = byID[m.id]!
                            return Scripts.renameComputer(computerName: e.computerName, localHostName: e.localHostName)
                        }) { m, r in
            guard r.succeeded, let e = byID[m.id] else { return }
            self.names[m.id] = ComputerNameInfo(computerName: e.computerName, localHostName: e.localHostName,
                                                hostName: e.localHostName)
            guard updateList, let i = model.machines.firstIndex(where: { $0.id == m.id }) else { return }
            if model.machines[i].name != e.computerName { model.machines[i].name = e.computerName }
            if let address = ComputerNames.addressAfterRename(model.machines[i].address, localHostName: e.localHostName),
               address != model.machines[i].address {
                model.machines[i].address = address
            }
        }
    }

    // MARK: - App versions

    func queryAppVersions(_ model: AppModel, name: String, _ targets: [Machine]) {
        let app = name.trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty else { return }
        config.lastAppVersionQuery = app
        var result = AppVersionsResult(appName: app)
        result.pending = Set(targets.map(\.id))
        appVersions = result
        let ss = model.sshSettings
        for m in targets {
            let pw = model.password(for: m)
            Task {
                let r = await SSH.run(Scripts.appVersion(app), on: m, password: pw, settings: ss, timeout: 40)
                guard self.appVersions?.appName == app else { return }
                self.appVersions?.pending.remove(m.id)
                if r.succeeded {
                    self.appVersions?.results[m.id] = AppVersionInfo.parse(r.stdoutText)
                } else {
                    self.appVersions?.errors[m.id] = SSH.diagnose(r).1
                }
            }
        }
    }

    // MARK: - Reports

    func inventoryCSV(_ model: AppModel) -> String {
        CSV.render(InventoryReport.rows(machines: model.machines, status: { model.status($0) },
                                        lastSeen: { self.lastSeen[$0.id] }))
    }

    func exportInventory(_ model: AppModel) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let url = Pickers.save(name: "pracownia-\(f.string(from: Date())).csv") else { return }
        do {
            try inventoryCSV(model).write(to: url, atomically: true, encoding: .utf8)
            ConfigStore.log("Raport CSV → \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }

    func exportCSV(_ rows: [[String]], suggestedName: String) {
        guard let url = Pickers.save(name: suggestedName) else { return }
        do {
            try CSV.render(rows).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }
}
