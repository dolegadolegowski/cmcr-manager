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

    // The command's own exit code – also 255, from an ssh or git the command ran (the wrapper reported the script's
    // end, AUDIT REV-53) – stays in the history and the exports.
    @Test(arguments: [
        (CommandResult(exitCode: 255, stderr: Data("git@github.com: Permission denied (publickey).\n".utf8), started: true,
                       endCode: 255),
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

extension RevR3appTests {
    // upload-into-names-the-mac (AUDIT UI-31, UI-04): the question before uploading into a subfolder in Przeglądarka
    // plików names the browsed computer, as the questions before replacing and deleting there do.
    @Test func theUploadIntoASubfolderQuestionNamesTheComputer() throws {
        let a = AppTestEnvironment.closedHost("imac04")
        let model = AppTestEnvironment.makeModel([a])
        let browser = model.files.browser
        browser.open("/Users/uczen/Desktop", on: a.id)
        defer { browser.cancel() }
        let folder = RemoteEntry(name: "Prace", kind: .directory)
        let request = browser.uploadConfirmation([URL(fileURLWithPath: "/tmp/zadanie.txt")], into: folder)
        #expect(request.title == "Wysłać do folderu „Prace”?")
        #expect(request.message.hasPrefix("Pliki o tych samych nazwach w folderze „Prace” na komputerze imac04 zostaną zastąpione"),
                "\(request.message)")
        #expect(request.targets?.isEmpty == true, "pytanie dotyczy przeglądanego komputera, nie zaznaczonych na liście")
    }

    // The name comes from the host list (an imported or hand-edited hosts.json): a direction override in it is shown,
    // not applied to the rest of the question, as in the names read from the iMac (AUDIT REV-19, DOD-13).
    @Test func theComputerInTheBrowsersQuestionsShowsDirectionOverrides() throws {
        let a = AppTestEnvironment.closedHost("imac\u{202E}40")
        let model = AppTestEnvironment.makeModel([a])
        let browser = model.files.browser
        browser.open("/Users/uczen/Desktop", on: a.id)
        defer { browser.cancel() }
        let upload = browser.uploadConfirmation([URL(fileURLWithPath: "/tmp/zadanie.txt")],
                                                into: RemoteEntry(name: "Prace", kind: .directory))
        let delete = try #require(browser.deleteConfirmation([RemoteEntry(name: "zadanie.txt", kind: .file)]))
        for message in [upload.message, delete.message] {
            #expect(message.contains("imac\\u{202E}40"), "\(message)")
            #expect(!message.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) },
                    "\(message.debugDescription)")
        }
    }
}
