import Foundation
import Testing
@testable import CMCRCore

// Tests for the review findings of group G1 (REV-xx in AUDIT.md): SSH.diagnose, classroom.json, hosts.json.
// Each test reproduces the reported problem.

private func g1Result(_ code: Int32, _ stderr: String, started: Bool = false) -> CommandResult {
    CommandResult(exitCode: code, stderr: Data(stderr.utf8), started: started)
}

// MARK: - REV-02: a started session that breaks off

struct RevG1DiagnoseTests {
    /// AUDIT REV-02: OpenSSH reports a reset of an established session as "Read from remote host …: Connection reset
    /// by peer" (or "client_loop: send disconnect: …", "Connection reset by <ip> port 22"), and with connection
    /// sharing (the default) a session whose shared connection died ends with 255 and nothing at all on stderr. All of
    /// these were reported as the command's own exit code 255 on an online Mac, although the job keeps running there.
    @Test func aStartedSessionThatBrokeOffIsAConnectionProblem() {
        let broken = [
            "Read from remote host imac05.local: Connection reset by peer\r\n",
            "Read from remote host 10.0.0.5: Operation timed out\r\n",
            "client_loop: send disconnect: Connection reset by peer\n",
            "Connection reset by 10.0.0.5 port 22\r\n",
            "Connection closed by 10.0.0.5 port 22\n",
            "",
            " \n",
        ]
        for stderr in broken {
            let (reach, message) = SSH.diagnose(g1Result(255, stderr, started: true))
            #expect(reach == .error, "\(stderr.debugDescription)")
            #expect(message == SSH.sessionClosed, "\(stderr.debugDescription): \(message)")
        }
        // Output of the command itself before the break does not hide ssh's message.
        let afterOutput = g1Result(255, "installer: Package name is Unity\nRead from remote host imac05.local: "
                                   + "Connection reset by peer\r\n", started: true)
        #expect(SSH.diagnose(afterOutput) == (.error, SSH.sessionClosed))
    }

    /// The command's own failures stay its own (AUDIT ZAD-07): the Mac answered.
    @Test func theCommandsOwnCode255StaysOnline() {
        let nested = g1Result(255, "ssh: connect to host inny.local port 22: Operation timed out\n", started: true)
        #expect(SSH.diagnose(nested) == (.online, "Polecenie zakończone kodem 255."))
        let key = g1Result(255, "git@github.com: Permission denied (publickey).\n", started: true)
        #expect(SSH.diagnose(key).0 == .online)
        // Other codes with nothing on stderr are the command's result as before.
        #expect(SSH.diagnose(g1Result(1, "", started: true)) == (.online, "Polecenie zakończone kodem 1."))
        // Before the start an empty 255 is still a plain connection error.
        #expect(SSH.diagnose(g1Result(255, "")) == (.error, "Błąd połączenia SSH (kod 255)."))
    }
}

// MARK: - REV-03: one bad value inside the lesson routines or the power schedule

private func g1TemporaryDirectory(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-rev-g1-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func g1Backups(in dir: URL, of name: String) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix(name + ".") && $0.pathExtension == "bak" }
}

struct RevG1ClassroomConfigTests {
    /// AUDIT REV-03: a value of a wrong type inside `start`, `end` or `schedule` reset that whole object to the
    /// defaults (the valid folder and apps of the start routine with it) and the file loaded as if it were fine: no
    /// copy, no warning, and the next change in the app wrote the defaults over the teacher's routine.
    @Test func aBadValueInsideARoutineKeepsItsOtherFieldsTheOriginalAndAWarning() throws {
        let dir = try g1TemporaryDirectory("classroom")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("classroom.json")
        let original = Data(#"""
        {"start": {"wakeWaitMinutes": 3.5, "materialsFolder": "/Users/n/Lekcja", "apps": "Unity Hub", "greet": false},
         "end": {"warnMinutes": "dwie", "collectLabel": "3A", "logout": true},
         "schedule": {"onDays": ["M", "X"], "offType": "shutdown", "offTime": {"hour": 18, "minute": 0}},
         "autoUnlockMinutes": 10}
        """#.utf8)
        try original.write(to: url)
        let r = ClassroomStore.loadConfig(from: url)
        #expect(r.value.start.materialsFolder == "/Users/n/Lekcja")
        #expect(r.value.start.apps == "Unity Hub")
        #expect(!r.value.start.greet)
        #expect(r.value.start.wakeWaitMinutes == LessonStartConfig().wakeWaitMinutes)
        #expect(r.value.end.collectLabel == "3A")
        #expect(r.value.end.logout)
        #expect(r.value.end.warnMinutes == LessonEndConfig().warnMinutes)
        #expect(r.value.schedule.offType == .shutdown)
        #expect(r.value.schedule.offTime == ClockTime(18, 0))
        #expect(r.value.schedule.onDays == Weekday.workdays)
        #expect(r.value.autoUnlockMinutes == 10)
        for path in ["start.wakeWaitMinutes", "end.warnMinutes", "schedule.onDays"] {
            #expect(r.issue?.contains(path) == true, "\(path): \(r.issue ?? "-")")
        }
        #expect(r.issue?.contains("materialsFolder") == false)
        #expect(!r.protect)
        let saved = g1Backups(in: dir, of: "classroom.json")
        #expect(saved.count == 1)
        #expect(try Data(contentsOf: #require(saved.first)) == original)
        // What the app saves next keeps the routine as recovered.
        ClassroomStore.saveConfig(r.value, to: url)
        #expect(ClassroomStore.loadConfig(from: url).value == r.value)
        #expect(ClassroomStore.loadConfig(from: url).issue == nil)
    }

    /// An unknown choice (another app version: a new attention mode or power choice) still falls back to the default,
    /// but no longer silently: the file is kept as .bak and the warning names the value.
    @Test func anUnknownChoiceIsReportedAndKept() throws {
        let dir = try g1TemporaryDirectory("classroom")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("classroom.json")
        let original = Data(#"{"lockMode": "cos-nowego", "end": {"power": "hibernate", "collectLabel": "3A"}, "lockMessage": "Tablica"}"#.utf8)
        try original.write(to: url)
        let r = ClassroomStore.loadConfig(from: url)
        #expect(r.value.lockMode == .automatic)
        #expect(r.value.end.power == LessonEndConfig.PowerChoice.none)
        #expect(r.value.end.collectLabel == "3A")
        #expect(r.value.lockMessage == "Tablica")
        #expect(r.issue?.contains("lockMode") == true, "\(r.issue ?? "-")")
        #expect(r.issue?.contains("end.power") == true, "\(r.issue ?? "-")")
        #expect(g1Backups(in: dir, of: "classroom.json").count == 1)
    }
}
