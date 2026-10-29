import AppKit
import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Fixes from the third review round in the app (AUDIT REV-51, UI-31) that need an AppModel.
@MainActor
@Suite(.serialized, .enabled(if: AppTestEnvironment.isIsolated, "uruchamiaj przez scripts/test.sh (izolowana konfiguracja)"))
struct RevR3appTests {
    /// Runs one job on `host` that ends with `result` and returns it with its record in the history.
    func finishedJob(on host: Machine, in model: AppModel, title: String,
                     result: CommandResult) async throws -> (job: Job, batch: Batch, record: JobRecord) {
        let batch = try #require(model.runBatch(title, on: [host]) { _, _ in result })
        #expect(await AppTestEnvironment.wait(5) { batch.finished })
        await JobHistory.waitForPendingWrites()
        let job = try #require(batch.jobs.first)
        let record = try #require(JobHistory.load().first { $0.id == job.id })
        return (job, batch, record)
    }
}

extension RevR3appTests {
    // connection-not-an-exit-code (AUDIT REV-51, ZAD-16): when the ssh session breaks off under a running command
    // (a shared connection that died says nothing: 255 with an empty stderr) or the connection fails, 255 is ssh's
    // own status, not the command's. The history and both exports show the connection error, not „kod 255”.
    @Test(arguments: [
        CommandResult(exitCode: 255, started: true),
        CommandResult(exitCode: 255, stderr: Data("Connection to imac04 closed by remote host.\n".utf8), started: true),
        CommandResult(exitCode: 255, stderr: Data("Timeout, server imac04 not responding.\n".utf8), started: true),
        CommandResult(exitCode: 255, stderr: Data("ssh: connect to host imac04 port 22: Connection refused\n".utf8)),
    ])
    func aBrokenConnectionIsNoExitCodeOfTheCommand(result: CommandResult) async throws {
        let a = AppTestEnvironment.closedHost("imac04")
        let model = AppTestEnvironment.makeModel([a])
        let (job, batch, record) = try await finishedJob(on: a, in: model, title: "Długie zadanie", result: result)
        #expect(job.state == .failed)
        #expect(job.summary == SSH.diagnose(result).1, "\(job.summary)")
        #expect(job.exitCode == nil, "zerwane połączenie zapisane jako kod wyjścia polecenia \(String(describing: job.exitCode))")
        #expect(record.exitCode == nil, "historia: kod \(String(describing: record.exitCode))")
        #expect(record.summary == job.summary)
        let live = BatchExport.text(batch)
        #expect(live.contains("=== imac04 – Błąd ===\n"), "\(live)")
        #expect(!live.contains("kod 255"), "\(live)")
        let saved = try #require(JobHistory.batches([record]).first)
        let exported = BatchExport.text(saved)
        #expect(exported.contains("=== imac04 – Błąd ===\n"), "\(exported)")
        #expect(!exported.contains("kod 255"), "\(exported)")
    }

    // The command's own exit code – also 255, from an ssh or git the command ran, which says why – stays in the
    // history and the exports.
    @Test(arguments: [
        (CommandResult(exitCode: 255, stderr: Data("git@github.com: Permission denied (publickey).\n".utf8), started: true),
         Int32(255)),
        (CommandResult(exitCode: 1, stderr: Data("ls: /Users/Shared/Prace: No such file or directory\n".utf8), started: true),
         Int32(1)),
    ])
    func theCommandsOwnExitCodeIsKept(result: CommandResult, code: Int32) async throws {
        let a = AppTestEnvironment.closedHost("imac04")
        let model = AppTestEnvironment.makeModel([a])
        let (job, batch, record) = try await finishedJob(on: a, in: model, title: "Polecenie", result: result)
        #expect(job.state == .failed)
        #expect(SSH.diagnose(result).0 == .online)
        #expect(job.exitCode == code)
        #expect(record.exitCode == code)
        #expect(BatchExport.text(batch).contains("=== imac04 – Błąd, kod \(code) ===\n"), "\(BatchExport.text(batch))")
    }
}
