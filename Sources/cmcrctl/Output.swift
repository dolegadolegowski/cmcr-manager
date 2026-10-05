import CMCRCore
import Foundation

/// Terminal output. SIGPIPE is ignored, so writing to a closed pipe (`cmcrctl … | head`) fails with EPIPE;
/// the non-throwing `FileHandle.write(_:)` would turn that into an uncaught exception (SIGABRT).
enum Console {
    static func write(_ channel: OutputChannel, _ data: Data) {
        guard !data.isEmpty else { return }
        let handle = channel == .stdout ? FileHandle.standardOutput : FileHandle.standardError
        do {
            try handle.write(contentsOf: data)
        } catch {
            // The reader is gone: stop quietly, with the status of a process killed by SIGPIPE.
            if channel == .stdout { exit(128 + SIGPIPE) }
        }
    }

    static func out(_ text: String, terminator: String = "\n") { write(.stdout, Data((text + terminator).utf8)) }
    static func err(_ text: String, terminator: String = "\n") { write(.stderr, Data((text + terminator).utf8)) }
}

enum ExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
}

func fail(_ message: String, code: Int32 = ExitCode.failure) -> Never {
    Console.err(message)
    exit(code)
}

func usageError(_ message: String) -> Never {
    Console.err(message)
    Console.err("Pomoc: cmcrctl --help")
    exit(ExitCode.usage)
}

/// Output of hosts processed in parallel, printed in list order: the first unfinished host streams live,
/// the others are buffered until their turn, so the result reads exactly like a sequential run.
final class OrderedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [[(OutputChannel, Data)]]
    private var finished: [Bool]
    private var head = 0

    init(count: Int) {
        pending = Array(repeating: [], count: count)
        finished = Array(repeating: false, count: count)
    }

    func write(_ index: Int, _ channel: OutputChannel, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if index == head { Console.write(channel, data) } else { pending[index].append((channel, data)) }
    }

    func finish(_ index: Int) {
        lock.lock()
        defer { lock.unlock() }
        finished[index] = true
        while head < finished.count, finished[head] {
            head += 1
            guard head < finished.count else { break }
            for (channel, data) in pending[head] { Console.write(channel, data) }
            pending[head] = []
        }
    }
}

/// Where one host writes during a multi-host run; optionally prefixes every line with `[name] `.
final class HostIO: @unchecked Sendable {
    let host: Machine
    let index: Int
    private let sink: OrderedOutput
    private let prefix: Data?
    private let lock = NSLock()
    private var atLineStart: [OutputChannel: Bool] = [.stdout: true, .stderr: true]

    init(host: Machine, index: Int, sink: OrderedOutput, prefixLines: Bool) {
        self.host = host
        self.index = index
        self.sink = sink
        prefix = prefixLines ? Data("[\(host.name)] ".utf8) : nil
    }

    var stream: Operations.Output { { [self] channel, data in write(channel, data) } }

    func write(_ channel: OutputChannel, _ data: Data) {
        guard let prefix else {
            sink.write(index, channel, data)
            return
        }
        lock.lock()
        var out = Data(capacity: data.count + prefix.count)
        var start = atLineStart[channel] ?? true
        for byte in data {
            if start {
                out.append(prefix)
                start = false
            }
            out.append(byte)
            if byte == 0x0A { start = true }
        }
        atLineStart[channel] = start
        lock.unlock()
        sink.write(index, channel, out)
    }

    func out(_ text: String) { write(.stdout, Data((text + "\n").utf8)) }
    func err(_ text: String) { write(.stderr, Data((text + "\n").utf8)) }

    /// Prints the failure explanation (if any) and returns the code to report for this host.
    @discardableResult
    func report(_ r: CommandResult, passThrough: Bool = false) -> Int32 {
        if r.succeeded { return ExitCode.success }
        err("✘ \(host.name): \(SSH.diagnose(r).1)")
        if !r.started, HostTrust.refusal(r) != nil {
            err("  W terminalu: cmcrctl trust \(host.name) – pokaże odcisk klucza i zapyta o zaufanie.")
        }
        if passThrough, r.exitCode > 0 { return r.exitCode }
        return ExitCode.failure
    }

    /// Ends unterminated prefixed lines so the next host starts on a fresh line.
    func close() {
        guard prefix != nil else { return }
        lock.lock()
        let open = atLineStart.filter { !$0.value }.map(\.key)
        lock.unlock()
        for channel in open { sink.write(index, channel, Data("\n".utf8)) }
    }
}

/// Runs `body` for every host with at most `jobs` hosts at a time; returns the per-host codes in host order.
func runHosts(_ targets: [Machine], jobs: Int, prefixLines: Bool,
              _ body: @escaping @Sendable (HostIO) async -> Int32) async -> [Int32] {
    let sink = OrderedOutput(count: targets.count)
    let limit = max(1, jobs)
    return await withTaskGroup(of: (Int, Int32).self) { group in
        var codes = Array(repeating: ExitCode.success, count: targets.count)
        for (i, host) in targets.enumerated() {
            if i >= limit, let (done, code) = await group.next() { codes[done] = code }
            let io = HostIO(host: host, index: i, sink: sink, prefixLines: prefixLines)
            group.addTask {
                let code = await body(io)
                io.close()
                sink.finish(i)
                return (i, code)
            }
        }
        for await (done, code) in group { codes[done] = code }
        return codes
    }
}

/// Pads to a column width counted in characters (`%-12@` ignores the width for objects).
func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, width - text.count))
    return right ? fill + text : text + fill
}

/// Polish plural: 1 komputer, 2–4 komputery, 5+ komputerów (12–14 komputerów).
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    if n == 1 { return "\(n) \(one)" }
    let last = n % 10, lastTwo = n % 100
    return "\(n) \((2...4).contains(last) && !(12...14).contains(lastTwo) ? few : many)"
}
