import Foundation

/// One step of the "Rozpocznij zajęcia" / "Zakończ zajęcia" routines.
public enum LessonStepKind: String, Codable, CaseIterable, Sendable {
    case wake, materials, openApps, greet
    case warn, collect, quitApps, cleanShared, cleanDownloads, logout, sleep, shutdown

    public var title: String {
        switch self {
        case .wake: return "Obudź komputery"
        case .materials: return "Wyślij materiały"
        case .openApps: return "Uruchom aplikacje"
        case .greet: return "Wyślij powitanie"
        case .warn: return "Uprzedź uczniów"
        case .collect: return "Zbierz prace"
        case .quitApps: return "Zamknij aplikacje"
        case .cleanShared: return "Wyczyść folder ucznia"
        case .cleanDownloads: return "Wyczyść Pobrane"
        case .logout: return "Wyloguj"
        case .sleep: return "Uśpij"
        case .shutdown: return "Wyłącz"
        }
    }

    public var icon: String {
        switch self {
        case .wake: return "sunrise"
        case .materials: return "paperplane"
        case .openApps: return "macwindow.badge.plus"
        case .greet: return "hand.wave"
        case .warn: return "exclamationmark.bubble"
        case .collect: return "tray.and.arrow.down"
        case .quitApps: return "xmark.app"
        case .cleanShared: return "folder.badge.minus"
        case .cleanDownloads: return "arrow.down.circle.dotted"
        case .logout: return "rectangle.portrait.and.arrow.right"
        case .sleep: return "moon.zzz"
        case .shutdown: return "power"
        }
    }
}

public enum StepState: Equatable, Sendable {
    case pending, running
    case done(String)
    case skipped(String)
    case failed(String)

    public var isFinished: Bool {
        switch self {
        case .pending, .running: return false
        default: return true
        }
    }

    public var detail: String {
        switch self {
        case .pending: return "oczekuje"
        case .running: return "w toku…"
        case .done(let s), .skipped(let s), .failed(let s): return s
        }
    }
}

/// Everything a routine needs, prepared once for all Macs.
public struct LessonPlan: Sendable {
    public enum Kind: String, Sendable {
        case start, end
        public var title: String { self == .start ? "Rozpoczęcie zajęć" : "Zakończenie zajęć" }
    }

    public var kind: Kind
    public var steps: [LessonStepKind]
    public var start: LessonStartConfig
    public var end: LessonEndConfig
    public var settings: AppSettings
    /// Base folder of this collection run, e.g. `~/Public/cmcr/zebrane/2026-10-05_14-30 3A`.
    public var collectFolder: URL?

    public static func start(_ c: LessonStartConfig, settings: AppSettings) -> LessonPlan {
        var steps: [LessonStepKind] = []
        if c.wake { steps.append(.wake) }
        if c.sendMaterials { steps.append(.materials) }
        if c.openApps && !c.appList.isEmpty { steps.append(.openApps) }
        if c.greet && !c.greetingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { steps.append(.greet) }
        return LessonPlan(kind: .start, steps: steps, start: c, end: LessonEndConfig(), settings: settings, collectFolder: nil)
    }

    public static func end(_ c: LessonEndConfig, settings: AppSettings, date: Date = Date()) -> LessonPlan {
        var steps: [LessonStepKind] = []
        if c.warn { steps.append(.warn) }
        // Apps are closed before collecting, so a graceful quit (autosave) lands in the collected copy.
        if c.quitApps && (c.quitAllApps || !c.appList.isEmpty) { steps.append(.quitApps) }
        if c.collect { steps.append(.collect) }
        // The student's cmcr folder is only ever emptied after its contents were collected.
        if c.cleanShared && c.collect { steps.append(.cleanShared) }
        if c.cleanDownloads { steps.append(.cleanDownloads) }
        if c.logout { steps.append(.logout) }
        switch c.power {
        case .sleep: steps.append(.sleep)
        case .shutdown: steps.append(.shutdown)
        case .none: break
        }
        let folder = c.collect ? collectFolder(base: settings.localFolder, label: c.collectLabel, date: date) : nil
        return LessonPlan(kind: .end, steps: steps, start: LessonStartConfig(), end: c, settings: settings, collectFolder: folder)
    }

    /// `<local>/zebrane/<yyyy-MM-dd_HH-mm>[ <label>]` – a new folder per lesson, so earlier work is never
    /// merged or overwritten and nothing lands in the cmcr-push source folders.
    public static func collectFolder(base: String, label: String, date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        var name = f.string(from: date)
        let clean = label.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { name += " " + clean }
        return URL(fileURLWithPath: expandTilde(base), isDirectory: true)
            .appendingPathComponent("zebrane", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Remote folder that receives the lesson materials.
    public var materialsDestination: String {
        switch start.destination {
        case .sharedFolder: return settings.sharedFolder
        case .studentDesktop: return settings.resolve("/Users/{student}/Desktop")
        }
    }
}

/// Executes a lesson routine on one Mac, step by step.
public enum LessonRunner {
    public typealias StepUpdate = @Sendable (Int, StepState) -> Void

    public struct Host: Sendable {
        public var machine: Machine
        public var password: String?
        /// Wake-on-LAN candidates (Ethernet MAC first).
        public var macs: [String]
        public var extraBroadcasts: [String]

        public init(machine: Machine, password: String?, macs: [String], extraBroadcasts: [String] = []) {
            self.machine = machine
            self.password = password
            self.macs = macs
            self.extraBroadcasts = extraBroadcasts
        }
    }

    /// Runs `plan.steps[range]` (all by default). `materials` is the payload archive made from the materials
    /// folder (see `Payload.make`); `nil` skips the materials step. With a `limiter`, every step except waking
    /// runs inside one of its slots, so Macs that are still waking up do not hold back the others.
    public static func run(_ plan: LessonPlan, on host: Host, ssh: SSHSettings, materials: URL?,
                           range: Range<Int>? = nil, limiter: ConcurrencyLimiter? = nil, handle: ProcessHandle? = nil,
                           onOutput: Operations.Output? = nil, onStep: StepUpdate? = nil) async -> CommandResult {
        let indices = range ?? 0..<plan.steps.count
        var failures: [String] = []
        var collected = false
        var collectFailed = false
        var unreachable = false
        var holdsSlot = false
        func say(_ s: String) { onOutput?(.stdout, Data((s + "\n").utf8)) }

        for i in indices {
            let step = plan.steps[i]
            if step != .wake, let limiter, !holdsSlot, !unreachable, handle?.isCancelled != true {
                await limiter.acquire()
                holdsSlot = true
            }
            if handle?.isCancelled == true {
                onStep?(i, .skipped("anulowano"))
                continue
            }
            if unreachable {
                onStep?(i, .skipped("komputer niedostępny"))
                continue
            }
            if step == .cleanShared && !collected {
                let why = collectFailed ? "zbieranie prac się nie udało" : "prace nie były zbierane"
                onStep?(i, .skipped("nie zebrano prac – folder pozostawiono"))
                say("▸ \(step.title): pominięto, bo \(why) (pliki uczniów pozostają na miejscu).")
                continue
            }
            if step == .cleanDownloads && collectFailed {
                onStep?(i, .skipped("nie zebrano prac – folder pozostawiono"))
                say("▸ \(step.title): pominięto, bo zbieranie prac się nie udało (pliki uczniów pozostają na miejscu).")
                continue
            }
            onStep?(i, .running)
            say("▸ [\(i + 1)/\(plan.steps.count)] \(step.title)")
            let state = await perform(step, plan: plan, host: host, ssh: ssh, materials: materials,
                                      handle: handle, onOutput: onOutput)
            onStep?(i, state)
            switch state {
            case .failed(let why):
                failures.append("\(step.title): \(why)")
                say("✘ \(why)")
                if step == .wake { unreachable = true }
                if step == .collect { collectFailed = true }
            case .skipped(let why):
                say("– \(why)")
            case .done(let what):
                say("✔ \(what)")
                if step == .collect { collected = true }
            default:
                break
            }
        }
        if holdsSlot { await limiter?.release() }
        if handle?.isCancelled == true { return CommandResult(exitCode: 130, cancelled: true) }
        if failures.isEmpty { return CommandResult(exitCode: 0, stdout: Data("Wszystkie kroki wykonane.\n".utf8)) }
        return CommandResult(exitCode: 1, stderr: Data((failures.joined(separator: "\n") + "\n").utf8))
    }

    static func perform(_ step: LessonStepKind, plan: LessonPlan, host: Host, ssh: SSHSettings, materials: URL?,
                        handle: ProcessHandle?, onOutput: Operations.Output?) async -> StepState {
        let m = host.machine
        let pw = host.password
        func remote(_ script: RemoteScript, timeout: TimeInterval? = nil) async -> CommandResult {
            await SSH.run(script, on: m, password: pw, settings: ssh, timeout: timeout, handle: handle, onOutput: onOutput)
        }
        func outcome(_ r: CommandResult, ok: String, noUser: String = "nikt nie jest zalogowany") -> StepState {
            if r.succeeded { return .done(ok) }
            if r.exitCode == ScriptCode.noConsoleUser { return .skipped(noUser) }
            return .failed(SSH.diagnose(r).1)
        }

        switch step {
        case .wake:
            return await wake(host, ssh: ssh, minutes: plan.start.wakeWaitMinutes, handle: handle, onOutput: onOutput)

        case .materials:
            guard let materials else { return .skipped("brak materiałów do wysłania") }
            let dest = plan.materialsDestination
            let owner = plan.settings.studentUser
            let mode = plan.start.destination == .sharedFolder ? "777" : ""
            let r = await Operations.push(payload: materials, to: m, destination: dest, owner: owner, mode: mode,
                                          asRoot: true, password: pw, settings: ssh, handle: handle, onOutput: onOutput)
            return r.succeeded ? .done("materiały w \(dest)") : .failed(SSH.diagnose(r).1)

        case .openApps:
            var opened: [String] = [], failed: [String] = []
            for app in plan.start.appList {
                let r = await remote(Scripts.launchApp(app), timeout: 60)
                if r.exitCode == ScriptCode.noConsoleUser { return .skipped("nikt nie jest zalogowany") }
                if r.succeeded { opened.append(app) } else { failed.append(app) }
            }
            if failed.isEmpty { return .done("uruchomiono: \(opened.joined(separator: ", "))") }
            return .failed("nie uruchomiono: \(failed.joined(separator: ", "))")

        case .greet:
            let r = await remote(Scripts.message(title: plan.start.greetingTitle, text: plan.start.greetingText,
                                                 asDialog: plan.start.greetingAsDialog), timeout: 60)
            return outcome(r, ok: "powitanie wyświetlone")

        case .warn:
            let r = await remote(Scripts.message(title: "Koniec zajęć", text: plan.end.warnText, asDialog: true), timeout: 60)
            return outcome(r, ok: "ostrzeżenie wyświetlone")

        case .collect:
            guard let base = plan.collectFolder else { return .skipped("brak folderu docelowego") }
            let dest = base.appendingPathComponent(m.name, isDirectory: true)
            let r = await Operations.pull(source: plan.settings.sharedFolder, from: m, into: dest, asRoot: true,
                                          password: pw, settings: ssh, handle: handle, onOutput: onOutput)
            guard r.succeeded else { return .failed(SSH.diagnose(r).1) }
            let count = fileCount(dest)
            return .done(count == 0 ? "folder ucznia był pusty" : "zebrano \(count) \(Plural.files(count))")

        case .quitApps:
            if plan.end.quitAllApps {
                return outcome(await remote(Scripts.quitAllApps(), timeout: 60), ok: "aplikacje zamknięte")
            }
            var failed: [String] = []
            for app in plan.end.appList {
                let r = await remote(Scripts.quitApp(app, force: false), timeout: 60)
                if !r.succeeded { failed.append(app) }
            }
            return failed.isEmpty ? .done("zamknięto: \(plan.end.appList.joined(separator: ", "))")
                : .failed("nie zamknięto: \(failed.joined(separator: ", "))")

        case .cleanShared:
            let path = plan.settings.sharedFolder
            return outcome(await remote(Scripts.cleanFolder(path), timeout: 120), ok: "wyczyszczono \(path)")

        case .cleanDownloads:
            let path = plan.settings.resolve("/Users/{student}/Downloads")
            return outcome(await remote(Scripts.cleanFolder(path), timeout: 120), ok: "wyczyszczono \(path)")

        case .logout:
            return outcome(await remote(Scripts.logoutUser(), timeout: 60), ok: "użytkownik wylogowany")

        case .sleep:
            return outcome(await remote(Scripts.power(.sleep), timeout: 60), ok: "usypianie")

        case .shutdown:
            return outcome(await remote(Scripts.power(.shutdown), timeout: 60), ok: "wyłączanie")
        }
    }

    /// Waits until the Mac answers over SSH, sending Wake-on-LAN packets while it does not.
    public static func wake(_ host: Host, ssh: SSHSettings, minutes: Int, handle: ProcessHandle?,
                            onOutput: Operations.Output?) async -> StepState {
        let m = host.machine
        let probeTimeout = TimeInterval(ssh.connectTimeout + 15)
        func online() async -> Bool {
            await SSH.run(Scripts.ping(), on: m, password: host.password, settings: ssh, timeout: probeTimeout,
                          handle: handle).succeeded
        }
        if await online() { return .done("komputer jest włączony") }
        let macs = host.macs.filter { WakeOnLAN.parseMAC($0) != nil }
        guard !macs.isEmpty else {
            return .failed("nie odpowiada, a brak adresu MAC do Wake-on-LAN")
        }
        let started = Date()
        let deadline = started.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        var lastSent = Date.distantPast
        while Date() < deadline {
            if handle?.isCancelled == true { return .skipped("anulowano") }
            if Date().timeIntervalSince(lastSent) >= 30 {
                for mac in macs { _ = try? WakeOnLAN.wake(mac: mac, extraBroadcasts: host.extraBroadcasts) }
                onOutput?(.stdout, Data("Wysłano Wake-on-LAN (\(macs.joined(separator: ", "))), czekam na odpowiedź…\n".utf8))
                lastSent = Date()
            }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if await online() {
                return .done("obudzony po \(Int(Date().timeIntervalSince(started))) s")
            }
        }
        return .failed("nie obudził się w ciągu \(max(1, minutes)) min (wyłączony? Wake-on-LAN działa tylko z uśpienia)")
    }

    static func fileCount(_ dir: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var n = 0
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            if url.lastPathComponent != ".DS_Store" { n += 1 }
        }
        return n
    }
}

/// Counting semaphore for async code: at most `limit` holders at a time, the others wait in FIFO order.
public actor ConcurrencyLimiter {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    public func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the slot to the next waiter (which then counts as active) or frees it.
    public func release() {
        if waiting.isEmpty {
            active = max(0, active - 1)
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Polish plural forms (1 plik, 2 pliki, 5 plików).
public enum Plural {
    public static func form(_ n: Int, one: String, few: String, many: String) -> String {
        if n == 1 { return one }
        let r10 = n % 10, r100 = n % 100
        if (2...4).contains(r10) && !(12...14).contains(r100) { return few }
        return many
    }

    public static func files(_ n: Int) -> String { form(n, one: "plik", few: "pliki", many: "plików") }
    public static func computers(_ n: Int) -> String { form(n, one: "komputer", few: "komputery", many: "komputerów") }
    /// Locative: "na 1 komputerze", "na 5 komputerach".
    public static func computersLocative(_ n: Int) -> String { n == 1 ? "komputerze" : "komputerach" }
}
