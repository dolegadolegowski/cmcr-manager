import Foundation
import Testing
@testable import CMCRCore

/// Collects streamed bytes from any thread.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Open pipe descriptors of this process (what leaked before: pipes pinned by finished processes).
private func openPipeCount() -> Int {
    let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
    return fds.compactMap(Int32.init).filter { fd in
        var st = stat()
        return fstat(fd, &st) == 0 && st.st_mode & S_IFMT == S_IFIFO
    }.count
}

private func elapsed(since start: Date) -> TimeInterval { Date().timeIntervalSince(start) }

@Suite(.serialized)
struct ProcessRunnerTests {
    @Test func fastProcessesNeverLoseOutput() async {
        let bad = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<300 {
                group.addTask {
                    let r = await ProcessRunner.run("/bin/echo", ["linia-\(i)"])
                    return r.exitCode == 0 && r.stdoutText == "linia-\(i)\n"
                }
            }
            var failures = 0
            for await ok in group where !ok { failures += 1 }
            return failures
        }
        #expect(bad == 0)
    }

    @Test func standardInputIsDelivered() async {
        let r = await ProcessRunner.run("/bin/cat", [], stdin: Data("zażółć\n".utf8))
        #expect(r.stdoutText == "zażółć\n")
    }

    @Test func standardErrorAndExitCodeAreReported() async {
        let r = await ProcessRunner.run("/bin/sh", ["-c", "echo blad >&2; exit 7"])
        #expect(r.exitCode == 7)
        #expect(r.stderrText == "blad\n")
        #expect(!r.succeeded)
    }

    @Test func timeoutStopsTheProcess() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sleep", ["10"], timeout: 0.3)
        #expect(r.timedOut)
        #expect(!r.succeeded)
        #expect(elapsed(since: start) < 3)
    }

    @Test func childIgnoringSIGTERMIsKilled() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 6"], timeout: 0.2)
        #expect(r.timedOut)
        // SIGKILL after 3 s, then at most 1 s of draining while the orphaned sleep holds the pipes.
        #expect(elapsed(since: start) < 5.5)
    }

    @Test func handleCancelsTheProcess() async {
        let handle = ProcessHandle()
        let start = Date()
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            handle.cancel()
        }
        let r = await ProcessRunner.run("/bin/sleep", ["10"], handle: handle)
        #expect(r.cancelled)
        #expect(elapsed(since: start) < 3)
        let again = await ProcessRunner.run("/bin/echo", ["x"], handle: handle)
        #expect(again.cancelled)
    }

    @Test func taskCancellationStopsTheProcess() async {
        let start = Date()
        let task = Task { await ProcessRunner.run("/bin/sleep", ["10"]) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let r = await task.value
        #expect(r.cancelled)
        #expect(elapsed(since: start) < 3)
    }

    @Test func cancelActionsRunOnceAndCanBeAwaited() async {
        let handle = ProcessHandle()
        let counter = ByteCounter()
        let token = handle.addCancelAction { counter.add(1) }
        #expect(token != nil)
        let removed = handle.addCancelAction { counter.add(100) }
        if let removed { handle.removeCancelAction(removed) }
        handle.cancel()
        handle.cancel()
        await handle.cancellationFinished()
        #expect(counter.value == 1)
        #expect(handle.addCancelAction { counter.add(1) } == nil)
    }

    @Test func backgroundGrandchildDoesNotDelayTheResult() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sh", ["-c", "sleep 4 & echo gotowe"])
        #expect(r.stdoutText == "gotowe\n")
        #expect(elapsed(since: start) < 3)
    }

    @Test func capturedOutputKeepsTheNewestBytes() async {
        let streamed = ByteCounter()
        let r = await ProcessRunner.run("/bin/sh", ["-c", "yes 0123456789 | head -c 3000000; printf KONIEC"],
                                        maxCapture: 1 << 20, onOutput: { _, d in streamed.add(d.count) })
        #expect(r.exitCode == 0)
        #expect(r.truncated)
        #expect(r.stdout.count == 1 << 20)
        #expect(r.stdoutText.hasSuffix("KONIEC"))
        #expect(streamed.value == 3_000_006)
    }

    @Test func stdoutCanGoToAFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await ProcessRunner.run("/bin/echo", ["do pliku"], stdoutFile: url)
        #expect(r.exitCode == 0)
        #expect(r.stdout.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "do pliku\n")
    }

    @Test func missingExecutableIsAReportedFailure() async {
        let r = await ProcessRunner.run("/nonexistent/cmcr-tool", [])
        #expect(r.exitCode == -1)
        #expect(r.stderrText.contains("Nie można uruchomić"))
    }

    @Test func runsDoNotLeakFileDescriptors() async {
        let before = openPipeCount()
        for round in 0..<15 {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<20 {
                    group.addTask {
                        if i == 0 {
                            // Some runs end by timeout or cancellation too.
                            _ = await ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.05)
                        } else {
                            _ = await ProcessRunner.run("/bin/echo", ["\(round)-\(i)"], timeout: 30)
                        }
                    }
                }
            }
        }
        var after = openPipeCount()
        for _ in 0..<20 where after > before + 20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            after = openPipeCount()
        }
        #expect(after <= before + 20, "otwarte potoki: \(before) → \(after)")
    }
}
