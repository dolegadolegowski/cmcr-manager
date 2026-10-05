import Foundation

/// Quotes a string for safe use as a single POSIX shell word.
public func shQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut = false
    public var cancelled = false
    /// The oldest part of stdout or stderr was dropped because it exceeded the capture limit.
    public var truncated = false

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false,
                cancelled: Bool = false, truncated: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.truncated = truncated
    }

    public static func failure(_ message: String, code: Int32 = -1) -> CommandResult {
        CommandResult(exitCode: code, stderr: Data((message + "\n").utf8))
    }

    public static var cancelledResult: CommandResult {
        CommandResult(exitCode: -1, stderr: Data("Anulowano.\n".utf8), cancelled: true)
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }
}

public enum OutputChannel: Sendable { case stdout, stderr }

/// Cancellation handle shared by every process started for one logical operation.
///
/// Besides terminating the local process, cancelling runs the registered cancel actions once (SSH.run
/// registers one that stops the command on the remote Mac).
public final class ProcessHandle: @unchecked Sendable {
    public typealias CancelAction = @Sendable () async -> Void

    private let lock = NSLock()
    /// Only the running process; cleared on exit so a finished job does not pin its pipes (file descriptors).
    private var process: Process?
    private var cancelledFlag = false
    private var actions: [UUID: CancelAction] = [:]
    private var actionsTask: Task<Void, Never>?

    public init() {}

    func attach(_ p: Process) {
        lock.lock()
        process = p
        let cancelled = cancelledFlag
        lock.unlock()
        if cancelled { Self.terminate(p) }
    }

    func detach(_ p: Process) {
        lock.lock()
        if process === p { process = nil }
        lock.unlock()
    }

    /// Registers work to do when the operation is cancelled. Returns nil (and does not register) when the
    /// handle is already cancelled.
    public func addCancelAction(_ action: @escaping CancelAction) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        if cancelledFlag { return nil }
        let id = UUID()
        actions[id] = action
        return id
    }

    public func removeCancelAction(_ id: UUID) {
        lock.lock()
        actions[id] = nil
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        let first = !cancelledFlag
        cancelledFlag = true
        let p = process
        if first, !actions.isEmpty {
            let pending = Array(actions.values)
            actions = [:]
            actionsTask = Task.detached {
                await withTaskGroup(of: Void.self) { group in
                    for action in pending { group.addTask { await action() } }
                }
            }
        }
        lock.unlock()
        if let p { Self.terminate(p) }
    }

    /// Waits until the cancel actions started by `cancel()` (e.g. stopping the remote command) are done.
    public func cancellationFinished() async {
        let task = lock.withLock { actionsTask }
        await task?.value
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    /// SIGTERM, escalated to SIGKILL when the process ignores it.
    static func terminate(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak p] in
            if let p, p.isRunning, p.processIdentifier == pid { kill(pid, SIGKILL) }
        }
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let maxCapture: Int
    private var out = Data()
    private var err = Data()
    private var finished = false
    private var truncatedFlag = false
    private var timedOutFlag = false
    private var timer: DispatchWorkItem?

    init(maxCapture: Int) { self.maxCapture = max(1, maxCapture) }

    /// Returns false once the result has been delivered (late data is dropped).
    func append(_ d: Data, to channel: OutputChannel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        if channel == .stdout { out.append(d); trim(&out, slack: 2) } else { err.append(d); trim(&err, slack: 2) }
        return true
    }

    /// Keeps the newest bytes; `slack` lets the buffer grow past the limit so trimming stays amortised O(1).
    private func trim(_ buffer: inout Data, slack: Int) {
        guard buffer.count > maxCapture * slack else { return }
        buffer = Data(buffer.suffix(maxCapture))
        truncatedFlag = true
    }

    func setTimer(_ t: DispatchWorkItem) { lock.lock(); timer = t; lock.unlock() }
    func takeTimer() -> DispatchWorkItem? { lock.lock(); defer { timer = nil; lock.unlock() }; return timer }
    func markTimedOut() { lock.lock(); timedOutFlag = true; lock.unlock() }

    /// Returns the collected output exactly once and releases the buffers.
    func finish() -> (out: Data, err: Data, truncated: Bool, timedOut: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        if finished { return nil }
        finished = true
        trim(&out, slack: 1)
        trim(&err, slack: 1)
        let r = (out, err, truncatedFlag, timedOutFlag)
        out = Data()
        err = Data()
        return r
    }
}

/// pipe(2) with close-on-exec ends. Unlike `Pipe()`, which hands back a nil object when the process is out
/// of file descriptors (and crashes on first use), this reports the failure.
private func makePipe() -> (read: Int32, write: Int32)? {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { return nil }
    _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
    return (fds[0], fds[1])
}

/// Reads one pipe on a dispatch source; the descriptor is closed and `onClose` called exactly once, at EOF
/// or after `cancel()`.
private final class PipeReader: @unchecked Sendable {
    private let source: DispatchSourceRead

    init(fd: Int32, queue: DispatchQueue, onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let size = 65_536
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        source.setEventHandler {
            while true {
                let n = read(fd, buffer, size)
                if n > 0 {
                    onData(Data(bytes: buffer, count: n))
                    if n < size { return }
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && errno == EAGAIN {
                    return
                } else {
                    source.cancel()
                    return
                }
            }
        }
        source.setCancelHandler {
            close(fd)
            buffer.deallocate()
            onClose()
        }
        self.source = source
        source.resume()
    }

    func cancel() { source.cancel() }
}

public enum ProcessRunner {
    /// Default limit of captured bytes per stream (stdout and stderr each); older bytes are dropped.
    public static let defaultMaxCapture = 32 << 20
    /// How long to keep reading after the process exited while a grandchild still holds its output pipes.
    static let drainGrace: TimeInterval = 1

    /// Finder-launched apps get a soft limit of 256 descriptors; every running ssh needs a few.
    private static let fileLimitRaised: Void = {
        var rl = rlimit()
        if getrlimit(RLIMIT_NOFILE, &rl) == 0 {
            let wanted = min(rl.rlim_max, rlim_t(8192))
            if rl.rlim_cur < wanted {
                rl.rlim_cur = wanted
                setrlimit(RLIMIT_NOFILE, &rl)
            }
        }
    }()

    /// Runs a local executable, streaming its output and returning everything it printed.
    /// - Parameters:
    ///   - stdin: data written to the child's standard input (which is then closed).
    ///   - stdoutFile: when set, standard output is written there instead of being collected.
    ///   - maxCapture: bytes kept per stream; when exceeded the oldest output is dropped (`truncated`).
    ///   - handle: cancels the process; cancelling the calling Task does the same.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        stdin: Data? = nil,
        stdoutFile: URL? = nil,
        timeout: TimeInterval? = nil,
        maxCapture: Int = defaultMaxCapture,
        handle: ProcessHandle? = nil,
        onOutput: (@Sendable (OutputChannel, Data) -> Void)? = nil
    ) async -> CommandResult {
        _ = fileLimitRaised
        let handle = handle ?? ProcessHandle()
        if handle.isCancelled || Task.isCancelled { return .cancelledResult }
        return await withTaskCancellationHandler {
            await launch(executable, arguments, environment: environment, stdin: stdin, stdoutFile: stdoutFile,
                         timeout: timeout, maxCapture: maxCapture, handle: handle, onOutput: onOutput)
        } onCancel: {
            handle.cancel()
        }
    }

    private static func launch(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        stdin: Data?,
        stdoutFile: URL?,
        timeout: TimeInterval?,
        maxCapture: Int,
        handle: ProcessHandle,
        onOutput: (@Sendable (OutputChannel, Data) -> Void)?
    ) async -> CommandResult {
        func launchFailure(_ reason: String) -> CommandResult {
            .failure("Nie można uruchomić \(executable): \(reason)")
        }
        var outFile: FileHandle?
        if let stdoutFile {
            guard FileManager.default.createFile(atPath: stdoutFile.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: stdoutFile) else {
                return .failure("Nie można utworzyć pliku \(stdoutFile.path).")
            }
            outFile = h
        }
        var opened: [Int32] = []
        func closeAll() { opened.forEach { close($0) }; try? outFile?.close() }
        guard let errP = makePipe() else {
            closeAll()
            return launchFailure("\(String(cString: strerror(errno))) (za dużo otwartych plików?)")
        }
        opened += [errP.read, errP.write]
        guard let inP = makePipe() else {
            closeAll()
            return launchFailure("\(String(cString: strerror(errno))) (za dużo otwartych plików?)")
        }
        opened += [inP.read, inP.write]
        var outP: (read: Int32, write: Int32)?
        if outFile == nil {
            guard let p = makePipe() else {
                closeAll()
                return launchFailure("\(String(cString: strerror(errno))) (za dużo otwartych plików?)")
            }
            outP = p
            opened += [p.read, p.write]
        }
        // A child that exits without reading its input must not kill us with SIGPIPE.
        _ = fcntl(inP.write, F_SETNOSIGPIPE, 1)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env
        process.standardError = FileHandle(fileDescriptor: errP.write, closeOnDealloc: false)
        process.standardInput = FileHandle(fileDescriptor: inP.read, closeOnDealloc: false)
        if let outP {
            process.standardOutput = FileHandle(fileDescriptor: outP.write, closeOnDealloc: false)
        } else {
            process.standardOutput = outFile
        }
        let outFileHandle = outFile
        let outRead = outP?.read
        let childEnds = [errP.write, inP.read] + (outP.map { [$0.write] } ?? [])

        return await withCheckedContinuation { (cont: CheckedContinuation<CommandResult, Never>) in
            let state = RunState(maxCapture: maxCapture)
            let eof = DispatchGroup()
            let queue = DispatchQueue(label: "cmcr.process.io")

            // Readers are installed before launching: a fast child may exit before run() returns.
            func reader(_ fd: Int32, _ channel: OutputChannel) -> PipeReader {
                eof.enter()
                return PipeReader(fd: fd, queue: queue, onData: { d in
                    if state.append(d, to: channel) { onOutput?(channel, d) }
                }, onClose: { eof.leave() })
            }
            let outReader = outRead.map { reader($0, .stdout) }
            let errReader = reader(errP.read, .stderr)

            process.terminationHandler = { p in
                state.takeTimer()?.cancel()
                handle.detach(p)
                let status = p.terminationStatus
                let deliver: @Sendable () -> Void = {
                    guard let r = state.finish() else { return }
                    outReader?.cancel()
                    errReader.cancel()
                    try? outFileHandle?.close()
                    cont.resume(returning: CommandResult(
                        exitCode: status, stdout: r.out, stderr: r.err, timedOut: r.timedOut,
                        cancelled: handle.isCancelled, truncated: r.truncated))
                }
                eof.notify(queue: .global(), execute: deliver)
                // A grandchild (e.g. a background process) may keep the pipes open for much longer.
                DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace, execute: deliver)
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                childEnds.forEach { close($0) }
                close(inP.write)
                outReader?.cancel()
                errReader.cancel()
                try? outFileHandle?.close()
                _ = state.finish()
                cont.resume(returning: launchFailure(error.localizedDescription))
                return
            }
            // The child has its own copies; ours must go, or EOF never arrives.
            childEnds.forEach { close($0) }
            handle.attach(process)

            let writer = inP.write
            DispatchQueue.global().async {
                if let stdin, !stdin.isEmpty {
                    stdin.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                        var offset = 0
                        while offset < buf.count {
                            let n = write(writer, buf.baseAddress! + offset, buf.count - offset)
                            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
                        }
                    }
                }
                close(writer)
            }

            if let timeout {
                let t = DispatchWorkItem { [weak process, weak state] in
                    state?.markTimedOut()
                    if let process { ProcessHandle.terminate(process) }
                }
                state.setTimer(t)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: t)
            }
        }
    }
}

/// Decodes a byte stream into text without breaking multi-byte UTF-8 characters split across chunks.
public final class UTF8StreamDecoder: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    public init() {}

    public func decode(_ chunk: Data) -> String {
        lock.lock()
        defer { lock.unlock() }
        var data = pending + chunk
        pending = Data()
        let cut = Self.completePrefixLength(data)
        if cut < data.count {
            pending = data.subdata(in: cut..<data.count)
            data = data.subdata(in: 0..<cut)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func completePrefixLength(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        let base = data.count - bytes.count
        var i = bytes.count - 1
        while i >= 0 {
            let b = bytes[i]
            if b & 0x80 == 0 { return data.count }           // ASCII – complete
            if b & 0xC0 == 0xC0 {                              // lead byte
                let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
                let have = bytes.count - i
                return have >= need ? data.count : base + i
            }
            i -= 1                                             // continuation byte
        }
        return data.count
    }
}
