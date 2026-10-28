import Foundation
import Testing
@testable import CMCRCore

// Tests for the P2 audit items of the CMCRCore package (AUDIT.md). Each test reproduces the reported problem.

private func p2TemporaryDirectory(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-p2-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func p2Record(_ host: String, batch: UUID, start: Date, finished: Date? = nil) -> JobRecord {
    JobRecord(id: UUID(), batchID: batch, title: "Polecenie", section: "commands", operatorName: "nauczyciel@Mac",
              hostID: UUID(), host: host, address: "\(host).local", state: "succeeded", exitCode: 0,
              batchStartedAt: start, startedAt: start, finishedAt: finished ?? start.addingTimeInterval(2),
              summary: "ok", outputFile: nil, outputBytes: 0)
}

// MARK: - ZAD-04: a history write never replaces the month file

struct P2JobHistoryWriteTests {
    /// AUDIT ZAD-04: when the month file exists but cannot be opened for writing, the old code fell back to an
    /// atomic write (temporary file + rename, which only needs the folder to be writable) and replaced the whole
    /// month of history with the one new line.
    @Test func aMonthFileThatCannotBeOpenedIsNotReplaced() throws {
        let dir = try p2TemporaryDirectory("history")
        let now = Date()
        let file = JobHistory.monthFile(for: now, in: dir)
        defer {
            chmod(file.path, 0o644)
            try? FileManager.default.removeItem(at: dir)
        }
        let earlier = p2Record("imac01", batch: UUID(), start: now.addingTimeInterval(-60))
        try JobHistory.write(earlier, output: nil, in: dir)
        let before = try Data(contentsOf: file)
        #expect(JobHistory.decodeLines(before).count == 1)

        chmod(file.path, 0o444)
        #expect(throws: (any Error).self) {
            try JobHistory.write(p2Record("imac02", batch: UUID(), start: now), output: nil, in: dir)
        }
        #expect(try Data(contentsOf: file) == before, "plik miesiąca został zastąpiony")
    }

    @Test func aMissingMonthFileIsCreatedAndLaterLinesAreAppended() throws {
        let dir = try p2TemporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        try JobHistory.write(p2Record("imac01", batch: UUID(), start: now), output: "wynik\n", in: dir)
        try JobHistory.write(p2Record("imac02", batch: UUID(), start: now), output: nil, in: dir)
        let lines = JobHistory.decodeLines(try Data(contentsOf: JobHistory.monthFile(for: now.addingTimeInterval(2), in: dir)))
        #expect(lines.map(\.host) == ["imac01", "imac02"])
    }
}
