import CMCRCore
import Foundation

let screenWatchSpec = ModuleSpec(values: ["--frames", "--interval", "--size", "--display", "--notified-user"],
                                 maxPositional: 2)

/// `cmcrctl screen-watch nr katalog [--frames N] [--interval S] [--size PX] [--display main|all|N]` – the app's
/// live preview session on the terminal: one ssh connection (one sudo) streaming frames into a folder.
/// `--notified-user U` (U was told about the preview already, so the notice is not shown again) is a test hook:
/// outside the e2e harness it would let anyone watch a student's screen without the student being told.
func screenWatchCommand(_ arguments: [String]) async -> Int32 {
    let a = ModuleArguments.parse("screen-watch", arguments, screenWatchSpec)
    let use = "Użycie: cmcrctl screen-watch nr katalog [--frames N] [--interval S] [--size PX] [--display main|all|N]"
    if a.value("--notified-user") != nil, !inTestHarness {
        moduleUsageError(a.command, "Opcja --notified-user działa tylko w testach (Tests/e2e) – uczeń zawsze dostaje "
                         + "powiadomienie o podglądzie.")
    }
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
    let watch = WatchState(limit: max(1, frames), host: host.name)
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
    if let failure = summary.writeError {
        // The preview stops at the first frame that cannot be saved (read-only or full disk): it is not reported
        // as saved, and the command does not end with 0 while the folder has no image.
        Console.err("✘ \(failure) – podgląd przerwany.")
        return ExitCode.failure
    }
    if summary.frames > 0 || (summary.cycles > 0 && summary.issue == nil) {
        Console.out("Zakończono: \(Polish.count(summary.cycles, "cykl", "cykle", "cykli")), "
                    + "\(Polish.count(summary.frames, "nowy obraz", "nowe obrazy", "nowych obrazów")).")
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
    /// Why a frame could not be saved; the session ends there.
    private var writeError: String?
    /// The actions log gets what the app's preview logs (ScreenCenter): the first image of each user, the
    /// notification of the user and a notification that failed.
    private let host: String
    private var user: String?
    private var loggedUsers: Set<String> = []
    private var loggedFailure: ScreenIssue?

    init(limit: Int, host: String) {
        self.limit = limit
        self.host = host
    }

    private func log(_ text: String) { ConfigStore.log("Podgląd ekranu (cmcrctl screen-watch) → \(host)\(text)") }

    var done: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cycles >= limit || writeError != nil
    }

    var summary: (cycles: Int, frames: Int, issue: ScreenIssue?, writeError: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (cycles, frames, issue, writeError)
    }

    func handle(_ event: ScreenEvent, dir: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .hello(let privileged):
            return privileged ? "● Połączono (root: jedno sudo na całą sesję)" : "● Połączono (bez sudo – konto zalogowane przy ekranie)"
        case .info(let user, let front):
            self.user = user
            // Both come from the iMac (an app's name is chosen by whoever built it).
            return "Użytkownik: \(user.map { TerminalText.escape($0) } ?? "—") · na pierwszym planie: "
                + (front.map { TerminalText.escape($0, keepBackslash: true) } ?? "—")
        case .frame(let d, let n, _, let data):
            let url = dir.appendingPathComponent(String(format: "klatka-%03d-ekran%d.jpg", cycles + 1, d))
            do {
                try data.write(to: url)
            } catch {
                if writeError == nil { writeError = "Nie można zapisać \(url.path): \(error.localizedDescription)" }
                return nil
            }
            frames += 1
            if let user, loggedUsers.insert(user).inserted { log(" (użytkownik \(user))") }
            if d >= n { cycles += 1 }
            return "Klatka \(d >= n ? cycles : cycles + 1): nowy obraz (ekran \(d)/\(n), \(data.count) B) → \(url.path)"
        case .unchanged(let d, let n, _):
            if d >= n { cycles += 1 }
            return "Klatka \(d >= n ? cycles : cycles + 1): bez zmian (ekran \(d)/\(n))"
        case .state(let i):
            if case .notifyFailed(let user, let detail) = i, loggedFailure != i {
                loggedFailure = i
                log(": nie udało się powiadomić użytkownika \(user) (\(detail)) – obraz nie jest pobierany")
            }
            if !i.isIdle || issue == nil { issue = i }
            switch i {
            case .captureFailed, .notifyFailed: cycles += 1
            default: if i.isIdle { cycles += 1 }
            }
            return "⚠︎ \(i.message)"
        case .notified(let user, _):
            log(": powiadomiono użytkownika \(user)")
            return "Powiadomiono użytkownika \(user) o podglądzie."
        case .bye(let reason):
            return "Koniec sesji (\(reason))."
        }
    }
}
