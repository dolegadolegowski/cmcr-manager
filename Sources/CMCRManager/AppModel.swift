import AppKit
import CMCRCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, commands, files, apps, install, updates, screens, power, jobs, setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Komputery"
        case .commands: return "Polecenia"
        case .files: return "Pliki"
        case .apps: return "Aplikacje"
        case .install: return "Instalacja"
        case .updates: return "Aktualizacje"
        case .screens: return "Podgląd ekranów"
        case .power: return "Sesja i zasilanie"
        case .jobs: return "Zadania"
        case .setup: return "Konfiguracja"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "desktopcomputer"
        case .commands: return "terminal"
        case .files: return "folder"
        case .apps: return "square.grid.2x2"
        case .install: return "shippingbox"
        case .updates: return "arrow.triangle.2.circlepath"
        case .screens: return "eye"
        case .power: return "power"
        case .jobs: return "list.bullet.rectangle"
        case .setup: return "gearshape"
        }
    }
}

/// One operation on one Mac. Mutated on the main thread only.
final class Job: ObservableObject, Identifiable, @unchecked Sendable {
    enum State { case queued, running, succeeded, failed, cancelled }

    let id = UUID()
    let machine: Machine
    let handle = ProcessHandle()
    @Published var state: State = .queued
    @Published var output = ""
    @Published var summary = ""
    @Published var startedAt: Date?
    @Published var finishedAt: Date?

    init(machine: Machine) { self.machine = machine }

    static let maxOutput = 300_000

    func append(_ text: String) {
        output += text
        if output.utf8.count > Self.maxOutput {
            output = "…(początek obcięty)…\n" + String(output.suffix(Self.maxOutput / 2))
        }
    }

    func note(_ line: String) { append("▸ \(line)\n") }

    var isFinished: Bool { state == .succeeded || state == .failed || state == .cancelled }

    var lastLine: String {
        output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// A group of jobs started together (one action on many Macs).
final class Batch: ObservableObject, Identifiable, @unchecked Sendable {
    let id = UUID()
    let title: String
    let createdAt = Date()
    let jobs: [Job]
    @Published var completed = 0
    @Published var finished = false

    init(title: String, jobs: [Job]) {
        self.title = title
        self.jobs = jobs
    }

    var succeeded: Int { jobs.filter { $0.state == .succeeded }.count }
    var failed: Int { jobs.filter { $0.state == .failed }.count }

    func cancel() { jobs.forEach { $0.handle.cancel() } }
}

/// Live screen preview of one Mac.
final class ScreenState: ObservableObject, @unchecked Sendable {
    @Published var image: NSImage?
    @Published var user: String?
    @Published var message: String?
    @Published var updatedAt: Date?
    @Published var loading = false
    var notified = false
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

/// Forwards process output into a job's log on the main thread.
final class OutputSink: @unchecked Sendable {
    private let job: Job
    private let out = UTF8StreamDecoder()
    private let err = UTF8StreamDecoder()

    init(_ job: Job) { self.job = job }

    var callback: Operations.Output {
        { [self] channel, data in
            let text = channel == .stdout ? out.decode(data) : err.decode(data)
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { self.job.append(text) }
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
        didSet { ConfigStore.saveHosts(machines) }
    }
    @Published var settings: AppSettings {
        didSet { if settings != oldValue { ConfigStore.saveSettings(settings) } }
    }
    @Published var statuses: [UUID: HostStatus] = [:]
    @Published var selection: Set<UUID> = []
    @Published var section: AppSection? = .dashboard
    @Published var batches: [Batch] = []
    @Published var lastBatch: [AppSection: Batch] = [:]
    @Published var runningApps: [UUID: HostApps] = [:]
    @Published var installedApps: [UUID: [String]] = [:]
    @Published var updates: [UUID: UpdateInfo] = [:]
    @Published var hasSharedPassword = false

    // Drafts kept while switching sections.
    @Published var commandDraft = "whoami; ls -l ~/"
    @Published var commandAsRoot = false
    @Published var pushItems: [URL] = []
    @Published var installItems: [URL] = []

    private var screenStates: [UUID: ScreenState] = [:]
    let askpassPath = ConfigStore.ensureAskpass()

    init() {
        machines = ConfigStore.loadHosts()
        settings = ConfigStore.loadSettings()
        hasSharedPassword = Keychain.get(Keychain.sharedAccount) != nil
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

    var runningJobCount: Int {
        batches.filter { !$0.finished }.reduce(0) { $0 + $1.jobs.filter { !$0.isFinished }.count }
    }

    func setSharedPassword(_ pw: String) {
        Keychain.set(pw, for: Keychain.sharedAccount)
        hasSharedPassword = !pw.isEmpty
    }

    func setPassword(_ pw: String, for m: Machine) {
        Keychain.set(pw, for: Keychain.account(for: m))
    }

    // MARK: - Batch execution

    /// Runs `operation` on every target with limited parallelism and records the results as a batch.
    @discardableResult
    func runBatch(_ title: String, on targets: [Machine], section: AppSection? = nil,
                  operation: @escaping @MainActor (Machine, Job) async -> CommandResult,
                  completion: (@MainActor (Batch) -> Void)? = nil) -> Batch? {
        guard !targets.isEmpty else { return nil }
        let jobs = targets.map { Job(machine: $0) }
        let batch = Batch(title: title, jobs: jobs)
        batches.insert(batch, at: 0)
        if batches.count > 200 { batches.removeLast(batches.count - 200) }
        if let s = section ?? self.section { lastBatch[s] = batch }
        ConfigStore.log("\(title) → \(targets.map(\.name).joined(separator: ", "))")
        let limit = max(1, settings.maxParallel)

        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                var active = 0
                for job in jobs {
                    if active >= limit {
                        await group.next()
                        active -= 1
                    }
                    group.addTask { await self.execute(job, in: batch, operation: operation) }
                    active += 1
                }
            }
            batch.finished = true
            completion?(batch)
        }
        return batch
    }

    private func execute(_ job: Job, in batch: Batch,
                         operation: @MainActor (Machine, Job) async -> CommandResult) async {
        defer { batch.completed += 1 }
        if job.handle.isCancelled {
            job.state = .cancelled
            job.summary = "Anulowano"
            return
        }
        job.state = .running
        job.startedAt = Date()
        let r = await operation(job.machine, job)
        job.finishedAt = Date()
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

    /// Runs a remote script on one Mac, streaming its output into the job.
    func ssh(_ script: RemoteScript, on m: Machine, job: Job, timeout: TimeInterval? = nil,
             stdoutFile: URL? = nil) async -> CommandResult {
        await SSH.run(script, on: m, password: password(for: m), settings: sshSettings, stdoutFile: stdoutFile,
                      timeout: timeout, handle: job.handle, onOutput: OutputSink(job).callback)
    }

    @discardableResult
    func runScript(_ title: String, on targets: [Machine], section: AppSection? = nil,
                   script: @escaping (Machine) -> RemoteScript,
                   onResult: (@MainActor (Machine, CommandResult) -> Void)? = nil) -> Batch? {
        runBatch(title, on: targets, section: section) { m, job in
            let r = await self.ssh(script(m), on: m, job: job)
            onResult?(m, r)
            return r
        }
    }

    func clearFinishedBatches() {
        batches.removeAll { $0.finished }
        lastBatch = lastBatch.filter { !$0.value.finished }
    }

    // MARK: - Status

    func refreshStatus(_ targets: [Machine]? = nil, quietly: Bool = false) {
        let list = targets ?? machines
        for m in list where !quietly || statuses[m.id] == nil {
            var st = statuses[m.id] ?? HostStatus()
            st.reachability = .checking
            statuses[m.id] = st
        }
        let ss = sshSettings
        let timeout = TimeInterval(settings.connectTimeout + 25)
        let jobs = list.map { ($0, password(for: $0)) }
        Task {
            await withTaskGroup(of: Void.self) { group in
                var active = 0
                for (m, pw) in jobs {
                    if active >= 16 {
                        await group.next()
                        active -= 1
                    }
                    group.addTask {
                        let r = await SSH.run(Scripts.status(), on: m, password: pw, settings: ss, timeout: timeout)
                        await self.applyStatus(m, r)
                    }
                    active += 1
                }
            }
        }
    }

    private func applyStatus(_ m: Machine, _ r: CommandResult) {
        var st = HostStatus()
        st.updatedAt = Date()
        if r.succeeded {
            st.reachability = .online
            st.info = Parsers.keyValues(r.stdoutText)
            if let mac = st.mac, let i = machines.firstIndex(where: { $0.id == m.id }), machines[i].macAddress.isEmpty {
                machines[i].macAddress = mac
            }
        } else {
            let (reach, message) = SSH.diagnose(r)
            st.reachability = reach == .online ? .error : reach
            st.message = message
            st.info = statuses[m.id]?.info ?? [:]
        }
        statuses[m.id] = st
    }

    // MARK: - Commands

    func runCommand(_ text: String, asRoot: Bool, on targets: [Machine]) {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let title = "\(asRoot ? "[root] " : "")\(firstLine.prefix(60))"
        runScript(title, on: targets) { _ in RemoteScript(text, asRoot: asRoot) }
    }

    /// cmcr-go: interactive ssh session in Terminal.app.
    func openTerminal(_ m: Machine) {
        let args = SSH.interactiveArguments(for: m, settings: sshSettings).map(shQuote).joined(separator: " ")
        let script = """
        #!/bin/zsh
        clear
        echo "cmcr-go → \(m.destination)"
        exec /usr/bin/ssh \(args)

        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-go-\(m.name).command")
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
        let dest = settings.resolve(destination)
        let payloadTask = Task { await Payload.make(items) }
        runBatch("Wysyłanie \(items.count) el. → \(dest)", on: targets, operation: { m, job in
            switch await payloadTask.value {
            case .failure(let e):
                return .failure(e.localizedDescription)
            case .success(let payload):
                return await Operations.push(payload: payload, to: m, destination: dest, owner: owner, mode: mode,
                                             asRoot: asRoot, password: self.password(for: m),
                                             settings: self.sshSettings, handle: job.handle,
                                             onOutput: OutputSink(job).callback)
            }
        }, completion: { _ in
            Task {
                if case .success(let url) = await payloadTask.value { try? FileManager.default.removeItem(at: url) }
            }
        })
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
                        let r = await SSH.run(Scripts.runningApps(), on: m, password: pw, settings: ss, timeout: 40)
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
                        let r = await SSH.run(Scripts.installedApps(), on: m, password: pw, settings: ss, timeout: 40)
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
                  script: { _ in Scripts.killProcess(app.pid, force: force) }) { m, _ in
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
        let payloadTask = Task { await Payload.make(items) }
        runBatch("Instalacja: \(items.map(\.lastPathComponent).joined(separator: ", "))", on: targets, operation: { m, job in
            switch await payloadTask.value {
            case .failure(let e):
                return .failure(e.localizedDescription)
            case .success(let payload):
                return await Operations.install(payload: payload, on: m, password: self.password(for: m),
                                                settings: self.sshSettings, handle: job.handle,
                                                onOutput: OutputSink(job).callback)
            }
        }, completion: { _ in
            Task {
                if case .success(let url) = await payloadTask.value { try? FileManager.default.removeItem(at: url) }
            }
        })
    }

    // MARK: - Updates

    func checkUpdates(_ targets: [Machine]) {
        runScript("Sprawdzanie aktualizacji macOS", on: targets, script: { _ in Scripts.listUpdates() }) { m, r in
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
        runBatch("Wake-on-LAN", on: targets) { m, job in
            let mac = m.macAddress.isEmpty ? (self.status(m).mac ?? "") : m.macAddress
            guard !mac.isEmpty else {
                return .failure("Brak adresu MAC – odśwież stan, gdy komputer jest włączony, lub wpisz MAC w Konfiguracji.")
            }
            do {
                for _ in 0..<3 { try WakeOnLAN.wake(mac: mac) }
                job.note("Wysłano pakiet Wake-on-LAN do \(mac). Działa przy połączeniu Ethernet i włączonym „Budź przy dostępie do sieci”.")
                return CommandResult(exitCode: 0)
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }

    // MARK: - Setup

    func distributeKey(_ targets: [Machine]) {
        guard let key = SSHKeys.currentPrivateKey(settings: settings), let pub = SSHKeys.publicKey(for: key) else {
            NSSound.beep()
            return
        }
        runScript("Dystrybucja klucza SSH (\(key.lastPathComponent).pub)", on: targets) { _ in Scripts.distributeKey(pub) }
    }

    func forgetHostKeys(_ targets: [Machine]) {
        runBatch("Zapomnij klucz hosta (known_hosts)", on: targets) { m, job in
            let r = await SSHKeys.forgetHostKey(m)
            job.append(r.stdoutText + r.stderrText)
            return r
        }
    }

    // MARK: - Screen preview

    func screenState(for id: UUID) -> ScreenState {
        if let s = screenStates[id] { return s }
        let s = ScreenState()
        screenStates[id] = s
        return s
    }

    /// Ends an observation session: the next preview notifies the user again.
    func endObservation() {
        screenStates.values.forEach { $0.notified = false }
    }

    func captureScreen(_ m: Machine, maxSize: Int) async {
        let st = screenState(for: m.id)
        guard !st.loading else { return }
        st.loading = true
        let notify = settings.notifyOnObserve && !st.notified
        let shot = await Operations.screenshot(of: m, maxSize: maxSize, settings: settings, notify: notify,
                                               password: password(for: m), sshSettings: sshSettings)
        st.loading = false
        st.updatedAt = Date()
        if let data = shot.imageData, let image = NSImage(data: data) {
            if !st.notified { ConfigStore.log("Podgląd ekranu → \(m.name) (użytkownik \(shot.user ?? "?"))") }
            st.notified = true
            st.image = image
            st.user = shot.user
            st.message = nil
        } else {
            st.image = nil
            st.message = shot.message ?? "Brak obrazu."
        }
    }
}
