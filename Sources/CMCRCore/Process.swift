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

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false, cancelled: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
    }

    public static func failure(_ message: String, code: Int32 = -1) -> CommandResult {
        CommandResult(exitCode: code, stderr: Data((message + "\n").utf8))
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }
}

public enum OutputChannel: Sendable { case stdout, stderr }

/// Cancellation handle shared by every process started for one logical operation.
public final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelledFlag = false

    public init() {}

    func attach(_ p: Process) {
        lock.lock()
        process = p
        let cancelled = cancelledFlag
        lock.unlock()
        if cancelled, p.isRunning { p.terminate() }
    }

    public func cancel() {
        lock.lock()
        cancelledFlag = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var finished = false
    var timedOut = false
    var timer: DispatchWorkItem?

    func append(_ d: Data, to channel: OutputChannel) {
        lock.lock()
        if channel == .stdout { out.append(d) } else { err.append(d) }
        lock.unlock()
    }

    /// Returns the collected output exactly once.
    func finish() -> (Data, Data)? {
        lock.lock()
        defer { lock.unlock() }
        if finished { return nil }
        finished = true
        return (out, err)
    }
}

public enum ProcessRunner {
    /// Runs a local executable, streaming its output and returning everything it printed.
    /// - Parameters:
    ///   - stdin: data written to the child's standard input (which is then closed).
    ///   - stdoutFile: when set, standard output is written there instead of being collected.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        stdin: Data? = nil,
        stdoutFile: URL? = nil,
        timeout: TimeInterval? = nil,
        handle: ProcessHandle? = nil,
        onOutput: (@Sendable (OutputChannel, Data) -> Void)? = nil
    ) async -> CommandResult {
        if handle?.isCancelled == true {
            return CommandResult(exitCode: -1, stderr: Data("Anulowano.\n".utf8), cancelled: true)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env

            let state = RunState()
            let eof = DispatchGroup()
            let errPipe = Pipe()
            let inPipe = Pipe()
            var outPipe: Pipe?
            var outFile: FileHandle?
            process.standardError = errPipe
            process.standardInput = inPipe
            if let stdoutFile {
                FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
                outFile = try? FileHandle(forWritingTo: stdoutFile)
                process.standardOutput = outFile ?? FileHandle.nullDevice
            } else {
                let p = Pipe()
                outPipe = p
                process.standardOutput = p
            }

            func watch(_ pipe: Pipe, _ channel: OutputChannel) {
                eof.enter()
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty {
                        h.readabilityHandler = nil
                        eof.leave()
                    } else {
                        state.append(d, to: channel)
                        onOutput?(channel, d)
                    }
                }
            }

            process.terminationHandler = { p in
                state.timer?.cancel()
                // Give the pipes a moment to drain; a grandchild could keep them open forever.
                DispatchQueue.global().async {
                    _ = eof.wait(timeout: .now() + 5)
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outPipe?.fileHandleForReading.readabilityHandler = nil
                    try? outFile?.close()
                    guard let (out, err) = state.finish() else { return }
                    cont.resume(returning: CommandResult(
                        exitCode: p.terminationStatus,
                        stdout: out,
                        stderr: err,
                        timedOut: state.timedOut,
                        cancelled: handle?.isCancelled ?? false
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                try? outFile?.close()
                _ = state.finish()
                cont.resume(returning: .failure("Nie można uruchomić \(executable): \(error.localizedDescription)"))
                return
            }
            handle?.attach(process)
            if let outPipe { watch(outPipe, .stdout) }
            watch(errPipe, .stderr)

            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global().async {
                if let stdin, !stdin.isEmpty { try? writer.write(contentsOf: stdin) }
                try? writer.close()
            }

            if let timeout {
                let t = DispatchWorkItem {
                    state.timedOut = true
                    if process.isRunning { process.terminate() }
                }
                state.timer = t
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
