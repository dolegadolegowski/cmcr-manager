import CMCRCore
import Foundation

/// `cmcrctl screen-watch nr katalog [--frames N] [--interval S] [--size PX] [--display main|all|N]
/// [--notified-user U]` – the app's live preview session on the terminal: one ssh connection (one sudo)
/// streaming frames into a folder.
func screenWatchCommand(_ arguments: [String]) async -> Int32 {
    var positional: [String] = []
    var frames = 3
    var interval = settings.screenshotInterval
    var size = settings.screenshotMaxSize
    var display = ScreenDisplay.main
    var notified: String?
    var i = 0
    func value() -> String? {
        i += 1
        return i < arguments.count ? arguments[i] : nil
    }
    while i < arguments.count {
        let a = arguments[i]
        switch a {
        case "--frames": frames = value().flatMap(Int.init) ?? frames
        case "--interval": interval = value().flatMap(Int.init) ?? interval
        case "--size": size = value().flatMap(Int.init) ?? size
        case "--display": display = value().flatMap(ScreenDisplay.init(scriptValue:)) ?? display
        case "--notified-user": notified = value()
        default: positional.append(a)
        }
        i += 1
    }
    guard positional.count == 2, let host = selectHosts(positional[0]).first else {
        fail("Użycie: cmcrctl screen-watch nr katalog [--frames N] [--interval S] [--size PX] [--display main|all|N] [--notified-user konto]")
    }
    let dir = URL(fileURLWithPath: expandTilde(positional[1]), isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        fail("Nie można utworzyć \(dir.path): \(error.localizedDescription)")
    }

    let options = ScreenCaptureOptions(settings: settings, maxSize: size, interval: interval,
                                       alreadyNotifiedUser: notified, display: display, frames: 0)
    let stream = ScreenStream(host: host, options: options)
    let watch = WatchState(limit: max(1, frames))
    print("Podgląd \(host.name): co \(ScreenCaptureOptions.clampedInterval(interval)) s, ≤ \(ScreenCaptureOptions.clampedSize(size)) px, \(display.label.lowercased())")

    let result: CommandResult = await withCheckedContinuation { cont in
        stream.start(password: Keychain.password(for: host), settings: sshSettings, onEvent: { event in
            if let line = watch.handle(event, dir: dir) { print(line) }
            if watch.done { stream.stop() }
        }, onExit: { r in
            cont.resume(returning: r)
        })
        let limit = Double(max(1, frames)) * Double(ScreenCaptureOptions.clampedInterval(interval) + 30) + 30
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) { stream.kill() }
    }
    let summary = watch.summary
    if summary.frames > 0 || (summary.cycles > 0 && summary.issue == nil) {
        print("Zakończono: \(summary.cycles) cykli, \(summary.frames) nowych obrazów.")
        return 0
    }
    if let issue = summary.issue {
        FileHandle.standardError.write(Data("✘ \(issue.message)\n".utf8))
        return issue.exitCode
    }
    return report(result) == 0 ? 1 : report(result)
}

private final class WatchState: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var cycles = 0
    private var frames = 0
    private var issue: ScreenIssue?

    init(limit: Int) { self.limit = limit }

    var done: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cycles >= limit
    }

    var summary: (cycles: Int, frames: Int, issue: ScreenIssue?) {
        lock.lock()
        defer { lock.unlock() }
        return (cycles, frames, issue)
    }

    func handle(_ event: ScreenEvent, dir: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .hello(let privileged):
            return privileged ? "● Połączono (root: jedno sudo na całą sesję)" : "● Połączono (bez sudo – konto zalogowane przy ekranie)"
        case .info(let user, let front):
            return "Użytkownik: \(user ?? "—") · na pierwszym planie: \(front ?? "—")"
        case .frame(let d, let n, _, let data):
            frames += 1
            let url = dir.appendingPathComponent(String(format: "klatka-%03d-ekran%d.jpg", cycles + 1, d))
            try? data.write(to: url)
            if d >= n { cycles += 1 }
            return "Klatka \(d >= n ? cycles : cycles + 1): nowy obraz (ekran \(d)/\(n), \(data.count) B) → \(url.path)"
        case .unchanged(let d, let n, _):
            if d >= n { cycles += 1 }
            return "Klatka \(d >= n ? cycles : cycles + 1): bez zmian (ekran \(d)/\(n))"
        case .state(let i):
            if !i.isIdle || issue == nil { issue = i }
            switch i {
            case .captureFailed, .notifyFailed: cycles += 1
            default: if i.isIdle { cycles += 1 }
            }
            return "⚠︎ \(i.message)"
        case .notified(let user):
            return "Powiadomiono użytkownika \(user) o podglądzie."
        case .bye(let reason):
            return "Koniec sesji (\(reason))."
        }
    }
}
