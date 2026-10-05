import CMCRCore
import Foundation

let screenWatchSpec = ModuleSpec(values: ["--frames", "--interval", "--size", "--display", "--notified-user"],
                                 maxPositional: 2)

/// `cmcrctl screen-watch nr katalog [--frames N] [--interval S] [--size PX] [--display main|all|N]
/// [--notified-user U]` – the app's live preview session on the terminal: one ssh connection (one sudo)
/// streaming frames into a folder.
func screenWatchCommand(_ arguments: [String]) async -> Int32 {
    let a = ModuleArguments.parse("screen-watch", arguments, screenWatchSpec)
    let use = "Użycie: cmcrctl screen-watch nr katalog [--frames N] [--interval S] [--size PX] [--display main|all|N] [--notified-user konto]"
    guard a.positional.count == 2 else { moduleUsageError(a.command, use) }
    let frames = a.int("--frames", in: 0...100_000) ?? 3
    let interval = a.int("--interval", in: 1...86_400) ?? settings.screenshotInterval
    let size = a.int("--size", in: 1...100_000) ?? settings.screenshotMaxSize
    var display = ScreenDisplay.main
    if let raw = a.value("--display") {
        guard let d = ScreenDisplay(scriptValue: raw) else {
            moduleUsageError(a.command, "--display: main, all lub numer ekranu (podano „\(raw)”).")
        }
        display = d
    }
    let notified = a.value("--notified-user")
    let host = ModuleHosts.one(a[0], a.command, usage: use)
    let positional = a.positional
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
    Console.out("Podgląd \(host.name): co \(ScreenCaptureOptions.clampedInterval(interval)) s, ≤ \(ScreenCaptureOptions.clampedSize(size)) px, \(display.label.lowercased())")

    let result: CommandResult = await withCheckedContinuation { cont in
        stream.start(password: Keychain.password(for: host), settings: sshSettings, onEvent: { event in
            if let line = watch.handle(event, dir: dir) { Console.out(line) }
            if watch.done { stream.stop() }
        }, onExit: { r in
            cont.resume(returning: r)
        })
        let limit = Double(max(1, frames)) * Double(ScreenCaptureOptions.clampedInterval(interval) + 30) + 30
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) { stream.kill() }
    }
    let summary = watch.summary
    if summary.frames > 0 || (summary.cycles > 0 && summary.issue == nil) {
        Console.out("Zakończono: \(summary.cycles) cykli, \(summary.frames) nowych obrazów.")
        return ExitCode.success
    }
    if let issue = summary.issue {
        // Documented in the usage text: 3 – nobody logged in, 4 – preview not allowed, 5 – no Screen Recording
        // permission, 6 – sudo; any other problem is 1.
        Console.err("✘ \(issue.message)")
        return issue.exitCode
    }
    _ = report(result)
    return ExitCode.failure
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
            // Both come from the iMac (an app's name is chosen by whoever built it).
            return "Użytkownik: \(user.map { TerminalText.escape($0) } ?? "—") · na pierwszym planie: "
                + (front.map { TerminalText.escape($0, keepBackslash: true) } ?? "—")
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
