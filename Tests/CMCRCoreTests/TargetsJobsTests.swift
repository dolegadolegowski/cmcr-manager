import Foundation
import Testing
@testable import CMCRCore

// MARK: - Polish plurals

@Test(arguments: [
    (1, "1 komputer"), (2, "2 komputery"), (4, "4 komputery"), (5, "5 komputerów"), (11, "11 komputerów"),
    (12, "12 komputerów"), (14, "14 komputerów"), (21, "21 komputerów"), (22, "22 komputery"),
    (104, "104 komputery"), (112, "112 komputerów"), (0, "0 komputerów"),
])
func polishComputerPlurals(n: Int, expected: String) {
    #expect(Polish.computers(n) == expected)
}

@Test func polishCasesAndOtherNouns() {
    #expect(Polish.onComputers(1) == "na 1 komputerze")
    #expect(Polish.onComputers(3) == "na 3 komputerach")
    #expect(Polish.ofComputers(1) == "1 komputera")
    #expect(Polish.ofComputers(15) == "15 komputerów")
    #expect(Polish.jobs(1) == "1 zadanie")
    #expect(Polish.jobs(3) == "3 zadania")
    #expect(Polish.jobs(5) == "5 zadań")
    #expect(Polish.files(23) == "23 pliki")
    #expect(Polish.plural(-2, "a", "b", "c") == "b")
}

// MARK: - Output coalescing

@Test func coalescerSchedulesOnlyOncePerDrain() {
    let c = OutputCoalescer()
    #expect(c.add("a") == true)
    #expect(c.add("b") == false)
    #expect(c.add("") == false)
    #expect(c.drain() == "ab")
    #expect(c.isEmpty)
    #expect(c.add("c") == true)
    #expect(c.drain() == "c")
    #expect(c.drain() == "")
}

@Test func coalescerKeepsOrderAcrossThreads() async {
    let c = OutputCoalescer()
    await withTaskGroup(of: Void.self) { group in
        for t in 0..<8 {
            group.addTask { for i in 0..<500 { c.add("\(t):\(i)\n") } }
        }
    }
    let lines = c.drain().split(separator: "\n")
    #expect(lines.count == 4000)
    // Per producer, lines arrive in order.
    for t in 0..<8 {
        let mine = lines.filter { $0.hasPrefix("\(t):") }.map { Int($0.split(separator: ":")[1])! }
        #expect(mine == Array(0..<500))
    }
}

@Test func lastLineTrackerFollowsChunksAndProgress() {
    var t = LastLineTracker()
    t.consume("first line\nsec")
    #expect(t.lastLine == "sec")
    t.consume("ond line\n\n   \n")
    #expect(t.lastLine == "second line")
    t.consume("  10%\r 50%\r")
    #expect(t.lastLine == "50%")
    t.consume("done  ")
    #expect(t.lastLine == "done")
    t.consume("\r\n")
    #expect(t.lastLine == "done")
    t.reset()
    #expect(t.lastLine == "")
}

@Test func lastLineTrackerMatchesFullRescan() {
    let text = (0..<300).map { i in i % 7 == 0 ? "   " : "line \(i) zażółć" }.joined(separator: "\n") + "\n"
    var t = LastLineTracker()
    var rest = Substring(text)
    while !rest.isEmpty {
        let n = min(rest.count, 37)
        t.consume(String(rest.prefix(n)))
        rest = rest.dropFirst(n)
    }
    let expected = text.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) }
        .map { $0.trimmingCharacters(in: .whitespaces) }
    #expect(t.lastLine == expected)
}

@Test func boundedTextKeepsTailOnCharacterBoundary() {
    var b = BoundedText(limit: 100)
    b.append(String(repeating: "ż", count: 40))   // 80 bytes
    #expect(b.generation == 0)
    b.append(String(repeating: "ą", count: 20))   // 120 bytes → keep last 50
    #expect(b.generation == 1)
    #expect(b.text.hasPrefix(BoundedText.marker))
    let kept = b.text.dropFirst(BoundedText.marker.count)
    #expect(!kept.contains("\u{FFFD}"))
    #expect(kept == String(repeating: "ż", count: 5) + String(repeating: "ą", count: 20))
    #expect(kept.utf8.count <= 50)

    b.keepLast(10, marker: "[koniec]\n")
    #expect(b.text == "[koniec]\n" + String(repeating: "ą", count: 5))
    #expect(b.generation == 2)
}

// MARK: - Groups and filtering

private func lab() -> [Machine] {
    var hosts = Machine.generate(count: 6)
    hosts[0].groups = ["Rząd 1"]
    hosts[1].groups = ["Rząd 1", "Matura"]
    hosts[2].groups = ["rząd 1"]
    hosts[3].groups = ["Rząd 10"]
    hosts[4].groups = ["Rząd 2"]
    return hosts
}

@Test func groupNamesAreUniqueAndNaturallySorted() {
    #expect(HostGroups.all(in: lab()) == ["Matura", "Rząd 1", "Rząd 2", "Rząd 10"])
    #expect(HostGroups.members(of: "RZĄD 1", in: lab()).map(\.name) == ["imac01", "imac02", "imac03"])
    #expect(HostGroups.parse(" Rząd 1, ,Matura;rząd 1\nB ") == ["Rząd 1", "Matura", "B"])
}

@Test func groupEditing() {
    var hosts = lab()
    let ids = Set(hosts.prefix(2).map(\.id))
    HostGroups.add("Pracownia", to: ids, in: &hosts)
    HostGroups.add("pracownia", to: ids, in: &hosts)
    #expect(hosts[0].groups == ["Rząd 1", "Pracownia"])
    HostGroups.rename("rząd 1", to: "Rząd A", in: &hosts)
    #expect(hosts[2].groups == ["Rząd A"])
    HostGroups.remove("Pracownia", from: [hosts[0].id], in: &hosts)
    #expect(hosts[0].groups == ["Rząd A"])
    #expect(hosts[1].groups.contains("Pracownia"))
}

@Test func hostQueryFiltersByTextStatusAndGroup() {
    let hosts = lab()
    var statuses: [UUID: HostStatus] = [:]
    var online = HostStatus()
    online.reachability = .online
    online.info = ["console": "student"]
    statuses[hosts[0].id] = online
    var offline = HostStatus()
    offline.reachability = .offline
    statuses[hosts[1].id] = offline
    var auth = HostStatus()
    auth.reachability = .authFailed
    statuses[hosts[2].id] = auth
    let status: (Machine) -> HostStatus = { statuses[$0.id] ?? HostStatus() }

    #expect(HostQuery().apply(to: hosts, status: status).count == 6)
    #expect(!HostQuery().isActive)
    #expect(HostQuery(group: "rząd 1").apply(to: hosts, status: status).count == 3)
    #expect(HostQuery(status: .online).apply(to: hosts, status: status).map(\.name) == ["imac01"])
    #expect(HostQuery(status: .withUser).apply(to: hosts, status: status).map(\.name) == ["imac01"])
    #expect(HostQuery(status: .attention).apply(to: hosts, status: status).map(\.name) == ["imac03"])
    // Unknown counts as not reachable for the "Niedostępne" filter.
    #expect(HostQuery(status: .offline).apply(to: hosts, status: status).count == 4)
    #expect(HostQuery(text: "STUDENT").apply(to: hosts, status: status).map(\.name) == ["imac01"])
    #expect(HostQuery(text: "matura").apply(to: hosts, status: status).map(\.name) == ["imac02"])
    #expect(HostQuery(text: "imac05.local").apply(to: hosts, status: status).map(\.name) == ["imac05"])
    #expect(HostQuery(text: "rzad 2").apply(to: hosts, status: status).map(\.name) == ["imac05"])
    #expect(HostQuery(text: "imac0", status: .offline, group: "Rząd 1").apply(to: hosts, status: status).map(\.name) == ["imac02"])
    #expect(Reachability.offline.isUnreachable)
    #expect(!Reachability.authFailed.isUnreachable && !Reachability.unknown.isUnreachable && !Reachability.error.isUnreachable)
}

@Test func machineGroupsDecodeBackwardCompatibly() throws {
    let old = #"[{"name":"imac01","address":"imac01.local","user":"imac01"}]"#
    let hosts = try JSONDecoder().decode([Machine].self, from: Data(old.utf8))
    #expect(hosts[0].groups.isEmpty)
    var m = hosts[0]
    m.groups = ["Rząd 1"]
    let round = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(m))
    #expect(round.groups == ["Rząd 1"])
    #expect(round == m)
}

// MARK: - Job history

private func record(_ host: String, batch: UUID, start: Date, state: String = "succeeded", minutes: Double = 0) -> JobRecord {
    JobRecord(id: UUID(), batchID: batch, title: "Test „zażółć”\nnowa linia", section: "commands",
              operatorName: "nauczyciel@Mac", hostID: UUID(), host: host, address: "\(host).local", state: state,
              exitCode: state == "succeeded" ? 0 : 1, batchStartedAt: start, startedAt: start,
              finishedAt: start.addingTimeInterval(minutes * 60 + 1.5), summary: "ok",
              outputFile: JobHistory.outputPath(batchID: batch, batchStartedAt: start, host: host, jobID: UUID()),
              outputBytes: 3)
}

@Test func jobRecordEncodesAsSingleLine() throws {
    let r = record("imac01", batch: UUID(), start: Date(timeIntervalSince1970: 1_760_000_000))
    let line = try JobHistory.encodeLine(r)
    #expect(line.last == 0x0A)
    #expect(line.dropLast().contains(0x0A) == false)
    let decoded = JobHistory.decodeLines(line + Data("{broken\n\n".utf8) + line)
    #expect(decoded.count == 2)
    #expect(decoded[0].title == r.title)
    #expect(decoded[0].durationMs == 1500)
    #expect(decoded[0].exitCode == 0)
    #expect(abs(decoded[0].finishedAt.timeIntervalSince(r.finishedAt)) < 0.01)
    #expect(r.outputFile?.hasPrefix("output/") == true)
    #expect(JobHistory.outputPath(batchID: r.batchID, batchStartedAt: r.batchStartedAt, host: "a/b c", jobID: r.id)
        .contains("a_b_c-"))
}

@Test func jobHistoryWritesLoadsGroupsAndPurges() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    let b1 = UUID(), b2 = UUID()
    let old = Calendar.current.date(byAdding: .day, value: -200, to: now)!
    try JobHistory.write(record("imac02", batch: b1, start: now), output: "wynik 2\n", in: dir)
    try JobHistory.write(record("imac01", batch: b1, start: now, state: "failed"), output: "wynik 1\n", in: dir)
    try JobHistory.write(record("imac03", batch: b2, start: now.addingTimeInterval(-60)), output: nil, in: dir)
    try JobHistory.write(record("imac04", batch: UUID(), start: old), output: "stare\n", in: dir)

    let all = JobHistory.load(in: dir)
    #expect(all.count == 4)
    #expect(all.first!.finishedAt >= all.last!.finishedAt)
    #expect(JobHistory.load(limit: 2, in: dir).count == 2)

    let batches = JobHistory.batches(all)
    #expect(batches.count == 3)
    #expect(batches[0].id == b1)
    #expect(batches[0].records.map(\.host) == ["imac01", "imac02"])
    #expect(batches[0].succeeded == 1 && batches[0].failed == 1)

    let out = try #require(JobHistory.outputURL(for: batches[0].records[1], in: dir))
    #expect(try String(contentsOf: out, encoding: .utf8) == "wynik 2\n")
    // No output written for imac03 → file does not exist, record still listed.
    #expect(!FileManager.default.fileExists(atPath: JobHistory.outputURL(for: batches[1].records[0], in: dir)!.path))

    JobHistory.purge(olderThan: 90, now: now, in: dir)
    let left = JobHistory.load(in: dir)
    #expect(left.count == 3)
    #expect(!left.contains { $0.host == "imac04" })
}

@Test func batchOutcomeTreatsSkippedAndCancelledAsNotSuccessful() {
    #expect(BatchOutcome(succeeded: 5, failed: 0, cancelled: 0, skipped: 0) == .succeeded)
    #expect(BatchOutcome(succeeded: 5, failed: 1, cancelled: 2, skipped: 2) == .failed)
    #expect(BatchOutcome(succeeded: 0, failed: 0, cancelled: 0, skipped: 4) == .nothingRan)
    #expect(BatchOutcome(succeeded: 0, failed: 0, cancelled: 3, skipped: 0) == .nothingRan)
    #expect(BatchOutcome(succeeded: 3, failed: 0, cancelled: 0, skipped: 1) == .partial)

    let b = UUID(), now = Date()
    let skippedOnly = HistoryBatch(id: b, title: "Restart", section: nil, startedAt: now,
                                   records: [record("imac01", batch: b, start: now, state: "skipped"),
                                             record("imac02", batch: b, start: now, state: "cancelled")])
    #expect(skippedOnly.outcome == .nothingRan)
    #expect(skippedOnly.skipped == 1 && skippedOnly.cancelled == 1)
}

// MARK: - Host list validation

@Test func hostValidationFindsDuplicatesPortsAndMACs() {
    var hosts = Machine.generate(count: 4)
    hosts[1].name = "IMAC01"
    hosts[2].address = "imac01.local"
    hosts[3].port = 70_000
    hosts[3].macAddress = "zz:00:11:22:33:44"
    hosts[0].macAddress = "a4:83:e7:1:2:3"
    let issues = HostValidation.issues(in: hosts)
    #expect(issues[hosts[0].id] == [.duplicateName, .duplicateAddress])
    #expect(issues[hosts[1].id] == [.duplicateName])
    #expect(issues[hosts[2].id] == [.duplicateAddress])
    #expect(issues[hosts[3].id] == [.invalidPort, .invalidMAC])
    let blank = Machine(name: " ", address: "", user: "")
    #expect(HostValidation.issues(in: [blank])[blank.id] == [.emptyName, .emptyAddress, .emptyUser])
    #expect(HostValidation.isValidMAC("A4-83-E7-12-34-56"))
    #expect(!HostValidation.isValidMAC("a4:83:e7:12:34"))
}

@Test func nextMachineFillsTheFirstGap() {
    var hosts = Machine.generate(count: 15)
    hosts.removeAll { $0.name == "imac03" }
    let next = HostValidation.nextMachine(after: hosts)
    #expect(next.name == "imac03")
    #expect(next.destination == "imac03@imac03.local")
    #expect(HostValidation.nextMachine(after: Machine.generate(count: 15)).name == "imac16")
    #expect(HostValidation.nextMachine(after: []).name == "imac01")
}

// MARK: - Risky root commands

@Test func commandRiskRecognisesDestructiveCommands() {
    #expect(CommandRisk.risks(in: "rm -rf /Users/student/Desktop/*").count == 1)
    #expect(!CommandRisk.risks(in: "asroot diskutil list").isEmpty)
    #expect(!CommandRisk.risks(in: "dscl . -delete /Users/gosc").isEmpty)
    #expect(!CommandRisk.risks(in: "shutdown -r now").isEmpty)
    #expect(!CommandRisk.risks(in: "pmset -a womp 1").isEmpty)
    #expect(CommandRisk.risks(in: "ls -la ~/; rm plik.txt; df -h; echo reboots").isEmpty)
    #expect(CommandRisk.usesRoot("asroot ls", asRoot: false))
    #expect(CommandRisk.usesRoot("ls", asRoot: true))
    #expect(!CommandRisk.usesRoot("ls ~/sudoku", asRoot: false))
}
