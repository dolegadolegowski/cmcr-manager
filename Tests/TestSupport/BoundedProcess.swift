import Darwin
import Foundation

// Local processes for tests that can never wait forever.
//
// Why this exists: `Process.waitUntilExit()` run on a thread other than the one that launched the process can miss
// the exit (the wake-up of its run loop is lost when the child exits between the `isRunning` check and the sleep)
// and then waits for ever with no child left to wait for. On a slow, busy runner (GitHub's 3–4 core macOS VMs) this
// is not rare: the whole `swift test` stood still until the job's 30-minute timeout. Nothing here uses
// `waitUntilExit()`, run loops, `readDataToEndOfFile()` or the dispatch global queue (whose thread supply is limited
// to a few per core and can run dry while many tests block): everything is polled with a hard deadline, on the
// calling thread.

public enum BoundedProcess {
    public struct Result: Sendable {
        /// `terminationStatus`; -1 when the process did not end (see `exited`).
        public var status: Int32
        public var out: Data
        public var err: Data
        /// The process was killed because `timeout` passed.
        public var timedOut: Bool
        /// False only when the process was still there some seconds after SIGKILL.
        public var exited: Bool
        public var outText: String { String(decoding: out, as: UTF8.self) }
        public var errText: String { String(decoding: err, as: UTF8.self) }
    }

    /// Runs `executable` and collects stdout and stderr. At `timeout` the process gets SIGCONT and SIGKILL (a stopped
    /// process does not act on SIGTERM), so the call returns at the latest a few seconds after that. Once the child
    /// is gone, output still held open by a grandchild is waited for `drainGrace` seconds only.
    /// - Parameters:
    ///   - stdin: written to the child's input at once (at most a pipe buffer, ~16 KB).
    ///   - keepStdinOpen: leave the input open until the process ends (end of input is a signal for some scripts);
    ///     without it the input is closed after `stdin` (or is /dev/null).
    public static func run(
        _ executable: String, _ arguments: [String], environment: [String: String]? = nil,
        stdin: Data? = nil, keepStdinOpen: Bool = false, timeout: TimeInterval = 30, drainGrace: TimeInterval = 1
    ) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = err
        let wantsInput = keepStdinOpen || stdin != nil
        p.standardInput = wantsInput ? input : FileHandle.nullDevice
        try p.run()

        let inFD = input.fileHandleForWriting.fileDescriptor
        if wantsInput {
            _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
            _ = fcntl(inFD, F_SETFL, fcntl(inFD, F_GETFL) | O_NONBLOCK)
            if let stdin, !stdin.isEmpty {
                stdin.withUnsafeBytes { raw in _ = Darwin.write(inFD, raw.baseAddress, min(raw.count, 16 * 1024)) }
            }
            if !keepStdinOpen { try? input.fileHandleForWriting.close() }
        }

        let outFD = out.fileHandleForReading.fileDescriptor, errFD = err.fileHandleForReading.fileDescriptor
        for fd in [outFD, errFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var open = [outFD, errFD]
        var outData = Data(), errData = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        let deadline = Date().addingTimeInterval(timeout)
        var killedAt: Date?, exitedAt: Date?
        var timedOut = false
        while !open.isEmpty {
            var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            _ = poll(&fds, nfds_t(fds.count), 20)
            for f in fds where f.revents != 0 {
                while true {
                    let n = chunk.withUnsafeMutableBytes { read(f.fd, $0.baseAddress, $0.count) }
                    if n > 0 {
                        if f.fd == outFD { outData.append(contentsOf: chunk[0..<n]) } else { errData.append(contentsOf: chunk[0..<n]) }
                    } else if n == 0 {
                        open.removeAll { $0 == f.fd }
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        if errno != EAGAIN { open.removeAll { $0 == f.fd } }
                        break
                    }
                }
            }
            let now = Date()
            if !p.isRunning, exitedAt == nil { exitedAt = now }
            if let e = exitedAt, now.timeIntervalSince(e) > drainGrace { break }
            if now > deadline, killedAt == nil {
                timedOut = true
                kill(p.processIdentifier, SIGCONT)
                kill(p.processIdentifier, SIGKILL)
                killedAt = now
            }
            if let k = killedAt, now.timeIntervalSince(k) > 3 { break }
        }
        // Pipes closed (or given up on): the process itself still has to end – by itself until the deadline.
        var exited = p.waitForExit(timeout: max(0, deadline.timeIntervalSinceNow))
        if !exited {
            timedOut = true
            p.forceStop()
            exited = p.waitForExit(timeout: 5)
        }
        if keepStdinOpen { try? input.fileHandleForWriting.close() }
        return Result(status: exited && !p.isRunning ? p.terminationStatus : -1, out: outData, err: errData,
                      timedOut: timedOut, exited: exited)
    }
}

extension Process {
    /// Waits until the process has ended, at most `timeout` seconds; false when it is still there. Polls `isRunning`
    /// (and, should that flag never flip, the process table) instead of `waitUntilExit()`.
    @discardableResult
    public func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var goneSince: Date?
        while isRunning {
            if kill(processIdentifier, 0) != 0 && errno == ESRCH {
                // Reaped, yet Foundation still says "running": believe the process table after a moment.
                let since = goneSince ?? Date()
                goneSince = since
                if Date().timeIntervalSince(since) > 0.5 { return true }
            }
            if Date() >= deadline { return false }
            usleep(2_000)
        }
        return true
    }

    /// SIGCONT first (a stopped process does not act on SIGTERM or hold still for a debugger), then SIGKILL.
    public func forceStop() {
        guard processIdentifier > 0 else { return }
        kill(processIdentifier, SIGCONT)
        kill(processIdentifier, SIGKILL)
    }

    /// Ends a process the polite way and, when that does not work within `grace` seconds, the hard way; never waits
    /// for more than `grace` + 5 seconds. Safe on a process that was never started, has ended or is stopped.
    public func stopAndWait(grace: TimeInterval = 2) {
        guard processIdentifier > 0, isRunning else { return }
        kill(processIdentifier, SIGCONT)
        terminate()
        if !waitForExit(timeout: grace) {
            forceStop()
            waitForExit(timeout: 5)
        }
    }
}
