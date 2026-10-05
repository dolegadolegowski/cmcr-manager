import AppKit
import CMCRCore
import Combine
import SwiftUI

/// What one tile or window wants to see of a Mac.
struct ScreenRequest: Equatable {
    /// Pixel width of the image (already quantized, see `ScreenLayout.captureSize`).
    var pixels: Int
    /// Seconds between frames; 0 uses the interval from the settings.
    var interval: Int = 0
}

/// Live preview of one Mac, shared by every tile and window that shows it.
@MainActor
final class ScreenFeed: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case idle, connecting, live, paused, offline
        case waiting(until: Date)
    }

    let id: UUID
    @Published fileprivate(set) var image: CGImage?
    @Published fileprivate(set) var user: String?
    @Published fileprivate(set) var frontApp: String?
    @Published fileprivate(set) var issue: ScreenIssue?
    @Published fileprivate(set) var phase: Phase = .idle
    /// When the shown image was last confirmed to match the screen (a new frame or an "unchanged" report).
    @Published fileprivate(set) var confirmedAt: Date?
    @Published fileprivate(set) var displayCount = 1
    @Published fileprivate(set) var privileged = false
    /// Effective seconds between frames, used to judge freshness.
    @Published fileprivate(set) var interval = 10

    init(id: UUID) { self.id = id }

    /// Assigns only real changes, so viewers are not re-rendered by the engine's periodic reconciliation.
    fileprivate func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<ScreenFeed, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func freshness(at now: Date) -> ScreenFreshness? {
        guard let t = confirmedAt else { return nil }
        if case .paused = phase { return .fresh }
        return ScreenFreshness.of(age: now.timeIntervalSince(t), interval: interval)
    }

    /// One short Polish line describing the state of the preview (for tiles and accessibility).
    var statusText: String {
        if let issue { return issue.title }
        switch phase {
        case .idle: return "Oczekiwanie"
        case .connecting: return "Łączenie…"
        case .live: return "Na żywo"
        case .paused: return "Wstrzymano"
        case .offline: return "Komputer nie odpowiada"
        case .waiting: return "Ponowna próba wkrótce"
        }
    }
}

/// Capture engine of the screen preview, separate from `AppModel`.
///
/// Every Mac that is visible in some tile or window gets one long-lived capture stream (one SSH connection,
/// at most one sudo per session) that serves all its viewers: the largest requested size and the shortest
/// interval win. Hosts are independent, so a slow or offline Mac never delays the others. Streams pause
/// while no viewer is visible, stop when nobody looks at the Mac any more, restart with backoff after
/// failures and skip Macs known to be offline. Frames are decoded off the main thread.
@MainActor
final class ScreenCenter: ObservableObject {
    static let maxConcurrentStarts = 4
    /// A Mac nobody looks at keeps its stream this long (scrolling, switching windows).
    static let stopGrace: TimeInterval = 5
    /// A paused stream (hidden window) is closed after this long.
    static let pauseLimit: TimeInterval = 300
    /// Default scope for viewers outside any `screenScope` (always visible).
    static let defaultScope = UUID()

    /// Stops every stream (menu "Wstrzymaj podgląd ekranów").
    @Published var paused = false {
        didSet { if paused != oldValue { reconcileAll() } }
    }
    @Published private(set) var appActive = NSApp?.isActive ?? true

    private weak var model: AppModel?
    private var feeds: [UUID: ScreenFeed] = [:]
    private var sessions: [UUID: Session] = [:]
    private var observers: [UUID: Observer] = [:]
    private var scopes: [UUID: Scope] = [:]
    private var displays: [UUID: ScreenDisplay] = [:]
    private var ledger = ObservationLedger()
    private var startQueue: [UUID] = []
    private var starting: Set<UUID> = []
    private var appHidden = false
    private var systemAsleep = false
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var restrictionsKey = ""
    /// `CMCR_SCREEN_TRACE=1` prints the engine's decisions to stderr (diagnostics).
    private let tracing = ProcessInfo.processInfo.environment["CMCR_SCREEN_TRACE"] == "1"

    private func trace(_ host: UUID, _ text: @autoclosure () -> String) {
        guard tracing else { return }
        let name = model?.machine(host)?.name ?? host.uuidString
        FileHandle.standardError.write(Data("[screens] \(Date().timeIntervalSince1970) \(name): \(text())\n".utf8))
    }

    private struct Observer {
        let host: UUID
        var request: ScreenRequest
        let scope: UUID
    }

    private struct Scope {
        var visible = true
        var pausesWhenInactive = false
    }

    private enum StopReason { case unobserved, paused, restart, watchdog, removed }

    private final class Session {
        let host: UUID
        var stream: ScreenStream?
        var generation = 0
        var helloSeen = false
        var lastMessage: Date?
        var sent = (pixels: 0, interval: 0, display: ScreenDisplay.main)
        var remotePaused = false
        var pausedSince: Date?
        var idleSince: Date?
        var failures = 0
        var retryAt: Date?
        var stopReason: StopReason?
        var exitIssue: ScreenIssue?
        var byeReason: String?
        var displayImages: [Int: CGImage] = [:]

        init(host: UUID) { self.host = host }
    }

    init(model: AppModel) {
        self.model = model
        restrictionsKey = Self.restrictionsKey(model.settings)
        // @Published emits before the new value is stored: act on the next turn of the main queue.
        model.$settings
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.settingsChanged(s) }
            .store(in: &cancellables)
        model.$statuses
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] st in self?.statusesChanged(st) }
            .store(in: &cancellables)
        model.$machines
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in self?.machinesChanged(list) }
            .store(in: &cancellables)
        model.$hasSharedPassword
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.retryCredentialFailures() }
            .store(in: &cancellables)

        let nc = NotificationCenter.default
        let app: [(Notification.Name, (ScreenCenter) -> Void)] = [
            (NSApplication.didBecomeActiveNotification, { $0.appActive = true }),
            (NSApplication.didResignActiveNotification, { $0.appActive = false }),
            (NSApplication.didHideNotification, { $0.appHidden = true }),
            (NSApplication.didUnhideNotification, { $0.appHidden = false }),
        ]
        for (name, apply) in app {
            nc.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self else { return }
                    apply(self)
                    self.reconcileAll()
                }
                .store(in: &cancellables)
        }
        let ws = NSWorkspace.shared.notificationCenter
        let system: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
            (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        for (name, asleep) in system {
            ws.publisher(for: name)
                .sink { [weak self] _ in
                    self?.systemAsleep = asleep
                    self?.reconcileAll()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - API for views

    func feed(for host: UUID) -> ScreenFeed {
        if let f = feeds[host] { return f }
        let f = ScreenFeed(id: host)
        f.interval = model?.settings.screenshotInterval ?? 10
        feeds[host] = f
        return f
    }

    func register(host: UUID, request: ScreenRequest, scope: UUID?) -> UUID {
        let token = UUID()
        observers[token] = Observer(host: host, request: request, scope: scope ?? Self.defaultScope)
        trace(host, "obserwator +\(request.pixels) px (razem \(observers.values.filter { $0.host == host }.count))")
        reconcile(host)
        ensureTimer()
        return token
    }

    func update(_ token: UUID, request: ScreenRequest) {
        guard var o = observers[token], o.request != request else { return }
        o.request = request
        observers[token] = o
        trace(o.host, "obserwator \(request.pixels) px")
        reconcile(o.host)
    }

    func unregister(_ token: UUID) {
        guard let o = observers.removeValue(forKey: token) else { return }
        reconcile(o.host)
    }

    func registerScope(_ id: UUID, pausesWhenInactive: Bool) {
        if tracing { FileHandle.standardError.write(Data("[screens] zakres \(id.uuidString.prefix(8)) pauza w tle: \(pausesWhenInactive)\n".utf8)) }
        var s = scopes[id] ?? Scope()
        s.pausesWhenInactive = pausesWhenInactive
        scopes[id] = s
        reconcileAll()
    }

    func setScope(_ id: UUID, visible: Bool) {
        if tracing { FileHandle.standardError.write(Data("[screens] zakres \(id.uuidString.prefix(8)) widoczny: \(visible)\n".utf8)) }
        var s = scopes[id] ?? Scope()
        guard s.visible != visible || scopes[id] == nil else { return }
        s.visible = visible
        scopes[id] = s
        reconcileAll()
    }

    func removeScope(_ id: UUID) {
        scopes[id] = nil
        reconcileAll()
    }

    /// "Odśwież teraz": a new frame from running streams, an immediate retry for failed ones.
    func refresh(_ hosts: [UUID]? = nil) {
        for host in hosts ?? Array(sessions.keys) {
            guard let s = sessions[host] else { continue }
            if let stream = s.stream, s.helloSeen {
                stream.send(.now)
            } else if s.stream == nil {
                s.retryAt = nil
                s.failures = 0
            }
            reconcile(host)
        }
    }

    func display(for host: UUID) -> ScreenDisplay { displays[host] ?? .main }

    func setDisplay(_ display: ScreenDisplay, for host: UUID) {
        displays[host] = display
        sessions[host]?.displayImages = [:]
        reconcile(host)
    }

    var isAnythingObserved: Bool { !observers.isEmpty }

    // MARK: - Reconciliation

    private func session(_ host: UUID) -> Session {
        if let s = sessions[host] { return s }
        let s = Session(host: host)
        sessions[host] = s
        return s
    }

    private func scopeIsActive(_ id: UUID) -> Bool {
        if paused || appHidden || systemAsleep { return false }
        let s = scopes[id] ?? Scope()
        if !s.visible { return false }
        if s.pausesWhenInactive && !appActive { return false }
        return true
    }

    private func reconcileAll() {
        for host in Set(sessions.keys).union(observers.values.map(\.host)) { reconcile(host) }
    }

    private func reconcile(_ host: UUID, now: Date = Date()) {
        guard let model else { return }
        let s = session(host)
        let feed = feed(for: host)
        let all = observers.values.filter { $0.host == host }

        guard !all.isEmpty, let machine = model.machine(host) else {
            ledger.unobserved(host, at: now)
            if s.idleSince == nil { s.idleSince = now }
            if model.machine(host) == nil {
                stop(s, .removed)
            } else if s.stream != nil, let idle = s.idleSince, now.timeIntervalSince(idle) >= Self.stopGrace {
                stop(s, .unobserved)
            }
            startQueue.removeAll { $0 == host }
            if s.stream == nil { feed.set(\.phase, .idle) }
            return
        }
        s.idleSince = nil

        let settings = model.settings
        let merged = ScreenSchedule.merge(all.map { ($0.request.pixels, $0.request.interval) },
                                          fallbackInterval: settings.screenshotInterval)
            ?? (settings.screenshotMaxSize, settings.screenshotInterval)
        feed.set(\.interval, merged.interval)
        let display = self.display(for: host)

        // A paused observer does not look at the screen: a long pause ends the observation session too.
        guard all.contains(where: { scopeIsActive($0.scope) }) else {
            ledger.unobserved(host, at: now)
            startQueue.removeAll { $0 == host }
            if let stream = s.stream {
                if s.helloSeen && !s.remotePaused {
                    trace(host, "pauza")
                    stream.send(.pause)
                    s.remotePaused = true
                }
                if s.pausedSince == nil { s.pausedSince = now }
                if let since = s.pausedSince, now.timeIntervalSince(since) >= Self.pauseLimit { stop(s, .paused) }
            }
            feed.set(\.phase, .paused)
            return
        }
        s.pausedSince = nil
        ledger.observed(host, at: now)

        if let stream = s.stream {
            guard s.helloSeen else {
                if let started = s.lastMessage,
                   now.timeIntervalSince(started) > TimeInterval(settings.connectTimeout + 40) {
                    s.exitIssue = .connection(.offline, "Komputer nie odpowiada (przekroczono czas łączenia).")
                    stop(s, .watchdog)
                }
                return
            }
            // A paused remote loop sends nothing, and a new interval changes when the next message is due:
            // after any command the watchdog counts from now.
            if s.remotePaused {
                trace(host, "wznowienie")
                stream.send(.resume)
                s.remotePaused = false
                s.lastMessage = now
            }
            if s.sent.pixels != merged.pixels {
                trace(host, "rozmiar \(merged.pixels) px")
                stream.send(.size(merged.pixels))
                s.lastMessage = now
            }
            if s.sent.interval != merged.interval {
                stream.send(.interval(merged.interval))
                s.lastMessage = now
            }
            if s.sent.display != display {
                stream.send(.display(display))
                s.lastMessage = now
            }
            s.sent = (merged.pixels, merged.interval, display)
            if feed.phase == .paused { feed.set(\.phase, .live) }
            if let last = s.lastMessage, now.timeIntervalSince(last) > ScreenSchedule.watchdogLimit(interval: merged.interval) {
                s.exitIssue = .connection(.offline, "Komputer przestał odpowiadać.")
                stop(s, .watchdog)
            }
            return
        }

        if let retry = s.retryAt, retry > now {
            if case .connection(let reach, _)? = feed.issue, reach == .offline || reach == .authFailed {
                feed.set(\.phase, .offline)
            } else {
                feed.set(\.phase, .waiting(until: retry))
            }
            return
        }
        // Known to be offline from the status check: do not hold up a connection slot, try again later.
        let status = model.status(machine)
        if s.failures == 0, status.reachability == .offline || status.reachability == .authFailed,
           let checked = status.updatedAt, now.timeIntervalSince(checked) < 300 {
            trace(host, "pominięto – według stanu \(status.reachability.label)")
            feed.set(\.issue, .connection(status.reachability, status.message.isEmpty ? status.reachability.label : status.message))
            feed.set(\.phase, .offline)
            s.retryAt = now.addingTimeInterval(60)
            startQueue.removeAll { $0 == host }
            return
        }
        if !startQueue.contains(host) && !starting.contains(host) {
            startQueue.append(host)
            if feed.phase != .live { feed.set(\.phase, .connecting) }
        }
        pumpStarts()
    }

    private func pumpStarts() {
        while starting.count < Self.maxConcurrentStarts, !startQueue.isEmpty {
            let host = startQueue.removeFirst()
            starting.insert(host)
            let delay = ScreenSchedule.jitter(maximum: 0.8)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.start(host)
            }
        }
    }

    private func releaseSlot(_ host: UUID) {
        if starting.remove(host) != nil { pumpStarts() }
    }

    private func start(_ host: UUID) {
        guard let model, let machine = model.machine(host), let s = sessions[host], s.stream == nil,
              (s.retryAt.map { $0 <= Date() } ?? true),
              observers.values.contains(where: { $0.host == host && scopeIsActive($0.scope) }) else {
            releaseSlot(host)
            return
        }
        let all = observers.values.filter { $0.host == host }
        let settings = model.settings
        let merged = ScreenSchedule.merge(all.map { ($0.request.pixels, $0.request.interval) },
                                          fallbackInterval: settings.screenshotInterval)
            ?? (settings.screenshotMaxSize, settings.screenshotInterval)
        let display = self.display(for: host)
        let options = ScreenCaptureOptions(settings: settings, maxSize: merged.pixels, interval: merged.interval,
                                           alreadyNotifiedUser: ledger.notifiedUser(host), display: display, frames: 0)
        let stream = ScreenStream(host: machine, options: options)
        trace(host, "start \(merged.pixels) px, co \(merged.interval) s, \(display.scriptValue), powiadomiony: \(options.alreadyNotifiedUser ?? "-")")
        s.generation += 1
        let generation = s.generation
        s.stream = stream
        s.helloSeen = false
        s.lastMessage = Date()
        s.sent = (merged.pixels, merged.interval, display)
        s.remotePaused = false
        s.stopReason = nil
        s.exitIssue = nil
        s.byeReason = nil
        let feed = feed(for: host)
        if feed.phase != .live { feed.set(\.phase, .connecting) }

        stream.start(password: model.password(for: machine), settings: model.sshSettings, onEvent: { [weak self] event in
            let decoded = ScreenCenter.prepare(event)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(decoded, host: host, generation: generation) }
            }
        }, onExit: { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleExit(result, host: host, generation: generation) }
            }
        })
    }

    private func stop(_ s: Session, _ reason: StopReason) {
        startQueue.removeAll { $0 == s.host }
        guard let stream = s.stream, s.stopReason == nil else { return }
        trace(s.host, "stop \(reason)")
        s.stopReason = reason
        if reason == .watchdog { stream.kill() } else { stream.stop() }
    }

    // MARK: - Events

    /// An event with its frame already decoded (runs on the stream's reader thread).
    fileprivate enum Prepared {
        case event(ScreenEvent)
        case frame(display: Int, count: Int, image: CGImage?)
    }

    nonisolated private static let decodeGate = DispatchSemaphore(value: 3)

    nonisolated private static func prepare(_ event: ScreenEvent) -> Prepared {
        guard case .frame(let display, let count, _, let data) = event else { return .event(event) }
        decodeGate.wait()
        defer { decodeGate.signal() }
        return .frame(display: display, count: count, image: ScreenImage.decode(data, maxPixel: 5120))
    }

    private func handle(_ prepared: Prepared, host: UUID, generation: Int) {
        guard let s = sessions[host], s.generation == generation, s.stream != nil else { return }
        let now = Date()
        s.lastMessage = now
        if tracing {
            switch prepared {
            case .frame(let d, let n, let image): trace(host, "klatka \(d)/\(n) \(image.map { "\($0.width)x\($0.height)" } ?? "błąd dekodowania")")
            case .event(let e): trace(host, "\(e)")
            }
        }
        let feed = feed(for: host)
        switch prepared {
        case .frame(let display, let count, let image):
            guard let image else { return }
            s.displayImages[display] = image
            s.displayImages = s.displayImages.filter { $0.key <= max(count, display) }
            let ordered = s.displayImages.keys.sorted().compactMap { s.displayImages[$0] }
            if count <= 1 || ordered.count >= count {
                feed.image = count <= 1 ? image : ScreenImage.sideBySide(ordered)
                feed.set(\.displayCount, max(1, count))
                feed.confirmedAt = now
                feed.set(\.issue, nil)
                feed.set(\.phase, s.remotePaused ? .paused : .live)
                s.failures = 0
                s.retryAt = nil
                s.exitIssue = nil
                if let user = feed.user, let name = model?.machine(host)?.name, ledger.shouldLog(host, user: user) {
                    ConfigStore.log("Podgląd ekranu → \(name) (użytkownik \(user))")
                }
            }
        case .event(let event):
            switch event {
            case .hello(let privileged):
                s.helloSeen = true
                feed.set(\.privileged, privileged)
                releaseSlot(host)
                if feed.phase == .connecting { feed.set(\.phase, .live) }
                reconcile(host)
            case .info(let user, let front):
                if feed.user != user {
                    feed.user = user
                    if feed.image != nil, user != nil { s.displayImages = [:] }
                }
                feed.set(\.frontApp, front)
            case .frame:
                break
            case .unchanged:
                feed.confirmedAt = now
                feed.set(\.issue, nil)
                s.failures = 0
                s.retryAt = nil
                s.exitIssue = nil
                if feed.phase != .paused { feed.set(\.phase, .live) }
            case .state(let issue):
                // The script retries every cycle; the log gets one line per failure, not one per attempt.
                if case .notifyFailed(let user, let detail) = issue, feed.issue != issue,
                   let name = model?.machine(host)?.name {
                    ConfigStore.log("Podgląd ekranu → \(name): nie udało się powiadomić użytkownika \(user) (\(detail)) – obraz nie jest pobierany")
                }
                feed.set(\.issue, issue)
                if issue.hidesImage {
                    feed.image = nil
                    feed.frontApp = nil
                    s.displayImages = [:]
                }
                if !issue.isIdle { s.exitIssue = issue }
                if issue.isIdle { feed.confirmedAt = now }
            case .notified(let user):
                ledger.recordNotified(host, user: user)
                if let name = model?.machine(host)?.name {
                    ConfigStore.log("Podgląd ekranu → \(name): powiadomiono użytkownika \(user)")
                }
            case .bye(let reason):
                s.byeReason = reason
            }
        }
    }

    private func handleExit(_ r: CommandResult, host: UUID, generation: Int) {
        guard let s = sessions[host], s.generation == generation else { return }
        trace(host, "koniec: kod \(r.exitCode), \(String(describing: s.stopReason)), \(r.stderrText.prefix(200))")
        s.stream = nil
        s.helloSeen = false
        s.remotePaused = false
        releaseSlot(host)
        let feed = feed(for: host)
        let reason = s.stopReason
        s.stopReason = nil

        switch reason {
        case .unobserved, .paused, .removed, .restart:
            feed.set(\.phase, reason == .paused ? .paused : .idle)
            reconcile(host)
            return
        case .watchdog, nil:
            break
        }
        if reason == nil, s.byeReason == "maxtime" || s.byeReason == "quit" {
            reconcile(host)
            return
        }
        s.failures += 1
        var issue = s.exitIssue
        if issue == nil || issue?.isIdle == true {
            let (reach, message) = SSH.diagnose(r)
            issue = reach == .online && r.exitCode != 255 ? .other(message) : .connection(reach, message)
        }
        feed.issue = issue
        var delay = ScreenSchedule.backoff(failures: s.failures)
        switch issue {
        case .sudoPasswordMissing?, .sudoPasswordWrong?, .sudoNotPermitted?: delay = max(delay, 60)
        default: break
        }
        let retry = Date().addingTimeInterval(delay)
        s.retryAt = retry
        trace(host, "ponowna próba za \(Int(delay)) s (\(issue?.title ?? "?"))")
        if case .connection(let reach, _)? = issue, reach == .offline || reach == .authFailed {
            feed.set(\.phase, .offline)
        } else {
            feed.set(\.phase, .waiting(until: retry))
        }
        reconcile(host)
    }

    // MARK: - Model changes

    private static func restrictionsKey(_ s: AppSettings) -> String {
        "\(s.screenshotQuality)|\(s.notifyOnObserve)|\(s.observeOnlyStandardAccounts)|\(s.observeAllowedUserList)"
    }

    private func settingsChanged(_ settings: AppSettings) {
        let key = Self.restrictionsKey(settings)
        if key != restrictionsKey {
            restrictionsKey = key
            // Restrictions are enforced by the remote script: restart every stream with the new ones.
            for s in sessions.values where s.stream != nil { stop(s, .restart) }
            for s in sessions.values where s.stream == nil {
                s.retryAt = nil
                s.failures = 0
            }
        }
        reconcileAll()
    }

    private func statusesChanged(_ statuses: [UUID: HostStatus]) {
        for (id, st) in statuses where st.reachability == .online {
            guard let s = sessions[id], s.stream == nil, s.retryAt != nil else { continue }
            if case .connection? = feeds[id]?.issue {
                s.retryAt = nil
                s.failures = 0
                reconcile(id)
            }
        }
    }

    private func machinesChanged(_ machines: [Machine]) {
        let ids = Set(machines.map(\.id))
        for (id, s) in sessions where !ids.contains(id) { stop(s, .removed) }
        reconcileAll()
    }

    /// A new password may fix sudo or login failures right away.
    func retryCredentialFailures() {
        for (id, s) in sessions where s.stream == nil {
            switch feeds[id]?.issue {
            case .sudoPasswordMissing?, .sudoPasswordWrong?, .connection(.authFailed, _)?:
                s.retryAt = nil
                s.failures = 0
            default: break
            }
        }
        reconcileAll()
    }

    // MARK: - Housekeeping

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = Date()
        reconcileAll()
        for host in ledger.expire(at: now) {
            // The observation session ended: drop the last image instead of keeping it in memory, and close
            // a paused stream, whose remote loop would otherwise still remember the notified user.
            if let f = feeds[host] {
                f.image = nil
                f.user = nil
                f.frontApp = nil
                f.issue = nil
                f.confirmedAt = nil
            }
            if let s = sessions[host] {
                s.displayImages = [:]
                stop(s, .paused)
            }
        }
        if observers.isEmpty, sessions.values.allSatisfy({ $0.stream == nil }), !sessions.isEmpty,
           sessions.values.allSatisfy({ s in s.idleSince.map { now.timeIntervalSince($0) > ledger.grace } ?? true }) {
            timer?.invalidate()
            timer = nil
        }
    }
}
