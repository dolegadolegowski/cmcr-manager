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

// MARK: - KON-07: MAC addresses accepted by Wake-on-LAN and cmcrctl are not flagged

struct P2MACValidationTests {
    /// AUDIT KON-07: "a483e7123456" or "a483.e712.3456" in the MAC column got „Adres MAC ma zły format”, although
    /// Wake-on-LAN and `cmcrctl hosts set --mac` accept (and normalise) them.
    @Test func everySpellingWakeOnLANAcceptsIsValid() {
        for mac in ["a4:83:e7:12:34:56", "A4-83-E7-12-34-56", "a483e7123456", "a483.e712.3456", "0:1b:63:84:45:e6"] {
            #expect(HostValidation.isValidMAC(mac), "\(mac)")
            #expect(WakeOnLAN.parseMAC(mac) != nil, "\(mac)")
        }
        for mac in ["a4:83:e7:12:34", "a483e712345", "a4:83:e7:12:34:56:78", "zz:83:e7:12:34:56", "a4::83:e7:12:34"] {
            #expect(!HostValidation.isValidMAC(mac), "\(mac)")
        }
        var m = Machine(name: "imac01", address: "imac01.local", user: "imac01")
        m.macAddress = "a483e7123456"
        #expect(HostValidation.issues(in: [m])[m.id] == nil)
    }
}

// MARK: - KON-08: an empty CMCR_CONFIG_DIR changes neither the configuration nor the log

struct P2ConfigLocationTests {
    /// AUDIT KON-08: `CMCR_CONFIG_DIR=` (e.g. an unset variable in a script) kept the default configuration, but the
    /// log of actions went to ~/Library/Application Support/CMCRManager/actions.log instead of the one the app shows.
    @Test func anEmptyConfigDirVariableKeepsTheDefaultLog() {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let defaultLog = lib.appendingPathComponent("Logs/CMCRManager/actions.log")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let defaultDir = support.appendingPathComponent("CMCRManager", isDirectory: true)
        #expect(ConfigStore.logURL(environment: ["CMCR_CONFIG_DIR": ""]) == defaultLog)
        #expect(ConfigStore.logURL(environment: [:]) == defaultLog)
        #expect(ConfigStore.directory(environment: ["CMCR_CONFIG_DIR": ""]) == defaultDir)
        #expect(ConfigStore.logURL(environment: ["CMCR_CONFIG_DIR": "/tmp/cmcr-x"]).path == "/tmp/cmcr-x/actions.log")
        #expect(ConfigStore.directory(environment: ["CMCR_CONFIG_DIR": "/tmp/cmcr-x"]).path == "/tmp/cmcr-x")
    }
}

// MARK: - KOM-02: a damaged classroom.json is kept and reported, like hosts.json and settings.json

private func p2Backups(in dir: URL, of name: String) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix(name + ".") && $0.pathExtension == "bak" }
}

struct P2ClassroomConfigRecoveryTests {
    /// AUDIT KOM-02: one value of a wrong type (hand edit, another app version) replaced the whole classroom
    /// configuration – lesson routines, power schedule, attention message, table layout – with the defaults, with no
    /// copy and no warning, and the first change overwrote the file.
    @Test func oneBadValueKeepsTheRestTheOriginalAndAWarning() throws {
        let dir = try p2TemporaryDirectory("classroom")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("classroom.json")
        let original = Data(#"{"lockMessage": 5, "autoUnlockMinutes": 10, "wakeOnLAN": false, "lastQuestion": "Ile?"}"#.utf8)
        try original.write(to: url)
        let r = ClassroomStore.loadConfig(from: url)
        #expect(r.value.autoUnlockMinutes == 10)
        #expect(!r.value.wakeOnLAN)
        #expect(r.value.lastQuestion == "Ile?")
        #expect(r.value.lockMessage == ClassroomConfig().lockMessage)
        #expect(r.issue?.contains("lockMessage") == true, "\(r.issue ?? "-")")
        #expect(r.issue?.contains("classroom.json") == true)
        #expect(!r.protect)
        let saved = p2Backups(in: dir, of: "classroom.json")
        #expect(saved.count == 1)
        #expect(try Data(contentsOf: #require(saved.first)) == original)
    }

    @Test func aFileThatIsNotJSONGivesDefaultsWithABackup() throws {
        let dir = try p2TemporaryDirectory("classroom")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("classroom.json")
        try Data("{ uszkodzony".utf8).write(to: url)
        let r = ClassroomStore.loadConfig(from: url)
        #expect(r.value == ClassroomConfig())
        #expect(r.issue?.contains("uszkodzony") == true)
        #expect(p2Backups(in: dir, of: "classroom.json").count == 1)
    }

    @Test func aMissingOrValidFileLoadsSilently() throws {
        let dir = try p2TemporaryDirectory("classroom")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("classroom.json")
        #expect(ClassroomStore.loadConfig(from: url).issue == nil)
        var c = ClassroomConfig()
        c.autoUnlockMinutes = 12
        ClassroomStore.saveConfig(c, to: url)
        let r = ClassroomStore.loadConfig(from: url)
        #expect(r.value == c)
        #expect(r.issue == nil)
        #expect(p2Backups(in: dir, of: "classroom.json").isEmpty)
    }

    /// Without a copy of the damaged original the file must not be overwritten by the next change.
    @Test func withoutABackupTheDamagedFileIsNotOverwritten() throws {
        let dir = try p2TemporaryDirectory("classroom")
        defer {
            chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("classroom.json")
        let original = Data(#"{"autoUnlockMinutes": "dziesięć"}"#.utf8)
        try original.write(to: url)
        chmod(dir.path, 0o500)
        let r = ClassroomStore.loadConfig(from: url)
        #expect(r.protect)
        #expect(r.issue?.contains("nie będą zapisywane") == true, "\(r.issue ?? "-")")
        let config = ConfigStore.record(r, for: url)
        chmod(dir.path, 0o700)
        ClassroomStore.saveConfig(config, to: url)
        #expect(try Data(contentsOf: url) == original)
    }
}

// MARK: - SSH.diagnose

private func p2Result(_ code: Int32, _ stderr: String, started: Bool = false) -> CommandResult {
    CommandResult(exitCode: code, stderr: Data(stderr.utf8), started: started)
}

struct P2DiagnoseTests {
    /// AUDIT ZAD-07: exit code 255 or "ssh:" in the output of a command that already ran on the Mac (git or another
    /// ssh without network) was taken for a failed connection: the working iMac became „wyłączony” and was skipped.
    @Test func sshMessagesFromACommandThatRanAreItsOwnError() {
        let git = p2Result(128, "ssh: Could not resolve hostname github.com: nodename nor servname provided, or not known\n"
                           + "fatal: Could not read from remote repository.\n", started: true)
        #expect(SSH.diagnose(git).0 == .online)
        #expect(SSH.diagnose(git).1 == "Polecenie zakończone kodem 128.")
        let nested = p2Result(255, "ssh: connect to host inny.local port 22: Operation timed out\n", started: true)
        #expect(SSH.diagnose(nested).0 == .online)
        #expect(SSH.diagnose(nested).1 == "Polecenie zakończone kodem 255.")
        let key = p2Result(255, "git@github.com: Permission denied (publickey).\n", started: true)
        #expect(SSH.diagnose(key).0 == .online)
        // The session itself breaking off is still a connection problem.
        #expect(SSH.diagnose(p2Result(255, "Timeout, server 10.0.0.5 not responding.\n", started: true)).0 == .offline)
        let closed = SSH.diagnose(p2Result(255, "Connection to 10.0.0.5 closed by remote host.\n", started: true))
        #expect(closed.0 == .error && closed.1.contains("przerwane"))
        let pipe = SSH.diagnose(p2Result(255, "client_loop: send disconnect: Broken pipe\n", started: true))
        #expect(pipe.0 == .error && pipe.1.contains("przerwane"))
        // Before the start nothing changes.
        #expect(SSH.diagnose(p2Result(255, "ssh: Could not resolve hostname imac01.local: nodename nor servname provided\n")).0 == .offline)
        #expect(SSH.diagnose(p2Result(255, "imac01@10.0.0.5: Permission denied (publickey,password).\n")).0 == .authFailed)
    }

    /// AUDIT TXT-05: macOS (and the rest of the app) calls the service „Zdalne logowanie”, and „ten Mac” in the app
    /// means the teacher's Mac – the message must send the teacher to the iMac.
    @Test func aRefusedConnectionPointsToRemoteLoginOnTheIMac() {
        let (reach, message) = SSH.diagnose(p2Result(255, "ssh: connect to host 10.0.5.23 port 22: Connection refused\n"))
        #expect(reach == .error)
        #expect(message.contains("„Zdalne logowanie”") && message.contains("na tym iMacu"), "\(message)")
        #expect(!message.contains("Logowanie zdalne") && !message.contains("tym Macu"))
    }

    /// AUDIT DOD-06: with the teacher's Mac off the network every iMac showed ssh's raw English error.
    @Test func noNetworkOnThisMacIsSaidInPolish() {
        let r = p2Result(255, "ssh: connect to host 10.0.5.23 port 22: Network is unreachable\n")
        let (reach, message) = SSH.diagnose(r)
        #expect(reach == .error, "nie .offline: iMac nie jest wyłączony, to ten Mac nie ma sieci")
        #expect(message == "Ten Mac nie jest połączony z siecią – sprawdź Wi‑Fi lub kabel.")
    }
}
