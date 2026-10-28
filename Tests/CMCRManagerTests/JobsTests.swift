import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Jobs that do not need a model: packing that can be interrupted (AUDIT WSP-04), notification texts (ZAD-08).
@MainActor
@Suite struct JobsTests {
    @Test func interruptedPackingDoesNotWaitForTar() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("plik.txt"))
        let stopped = ProcessHandle()
        stopped.cancel()
        guard case .failure(let error) = await Payload.make([dir], handle: stopped) else {
            Issue.record("przerwane pakowanie dało archiwum")
            return
        }
        #expect(error.localizedDescription.contains("Przerwano"))
        let shared = SharedPayload([dir])
        let r = await shared.use(handle: stopped) { _ in CommandResult(exitCode: 0) }
        #expect(r.cancelled)
        // A job that was not interrupted still gets the archive.
        let ok = await shared.use(handle: ProcessHandle()) { url in
            CommandResult(exitCode: FileManager.default.fileExists(atPath: url.path) ? 0 : 1)
        }
        #expect(ok.succeeded)
        shared.discard()
    }

    @Test func aNotificationNeverSaysDoneOnNoMacs() {
        let m = Machine(name: "imac01", address: "imac01.local", user: "imac01")
        let jobs = [Job(machine: m), Job(machine: m)]
        jobs.forEach { $0.state = .failed }
        let batch = Batch(title: "Test", jobs: jobs)
        #expect(JobNotifier.body(for: batch) == "Błąd na 2 komputerach")
        jobs[0].state = .succeeded
        #expect(JobNotifier.body(for: batch) == "Gotowe na 1 komputerze · błąd na 1 komputerze")
    }
}
