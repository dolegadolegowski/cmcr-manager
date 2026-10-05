import Foundation
import Testing
@testable import CMCRCore

// MARK: - Energy schedule

@Test func defaultScheduleBuildsPmsetRepeatArguments() {
    let s = EnergySchedule()
    #expect(s.pmsetArguments == ["repeat", "wakeorpoweron", "MTWRF", "07:45:00", "sleep", "MTWRF", "16:30:00"])
}

@Test func scheduleWithOnlyShutdownAndCustomDays() {
    var s = EnergySchedule()
    s.powerOnEnabled = false
    s.offType = .shutdown
    s.offDays = [.sunday, .monday, .friday]
    s.offTime = ClockTime(18, 5)
    #expect(s.pmsetArguments == ["repeat", "shutdown", "MFU", "18:05:00"])
    #expect(s.summary == "Wyłącz o 18:05 – Pn, Pt, Nd")
}

@Test func invalidSchedulesAreRejected() {
    var s = EnergySchedule()
    s.powerOnEnabled = false
    s.powerOffEnabled = false
    #expect(s.pmsetArguments == nil)
    #expect(s.validationError != nil)
    s.powerOnEnabled = true
    s.onDays = []
    #expect(s.pmsetArguments == nil)
}

@Test func weekdaysUsePmsetLettersInCalendarOrder() {
    #expect(Weekday.pmsetString([.sunday, .thursday, .monday]) == "MRU")
    #expect(Weekday.describe(Weekday.workdays) == "dni robocze (Pn–Pt)")
    #expect(Weekday.describe(Set(Weekday.allCases)) == "codziennie")
    #expect(Weekday.describe([.saturday, .sunday]) == "weekendy")
}

@Test func clockTimeParsesPmsetAndPickerFormats() {
    #expect(ClockTime.parse("7:45AM") == ClockTime(7, 45))
    #expect(ClockTime.parse("6:00PM") == ClockTime(18, 0))
    #expect(ClockTime.parse("12:05AM") == ClockTime(0, 5))
    #expect(ClockTime.parse("12:30PM") == ClockTime(12, 30))
    #expect(ClockTime.parse("07:45:00") == ClockTime(7, 45))
    #expect(ClockTime.parse("25:00") == nil)
    #expect(ClockTime(7, 5).pmsetString == "07:05:00")
}

@Test func repeatingEventsAreParsedFromPmsetSched() {
    let text = """
    Repeating power events:
      wakepoweron at 7:45AM weekdays only
      shutdown at 6:00PM every day
      sleep at 4:30PM MWF
    Scheduled power events:
     [0]  wake at 10/06/2026 07:45:00 by 'com.apple.alarm'
    CMCR:POLICY
    autorestart=1
    womp=0
    """
    let events = PowerScheduleParser.repeating(text)
    #expect(events.count == 3)
    #expect(events[0].text == "Obudź lub włącz o 7:45 – dni robocze (Pn–Pt)")
    #expect(events[0].isPowerOn)
    #expect(events[1].text == "Wyłącz o 18:00 – codziennie")
    #expect(events[2].text == "Uśpij o 16:30 – Pn, Śr, Pt")
    #expect(PowerScheduleParser.policy(text) == ["autorestart": "1", "womp": "0"])
    #expect(PowerScheduleParser.repeating("Scheduled power events:\n [0] wake at …").isEmpty)
}

// MARK: - Wake-on-LAN

@Test func macAddressesInAllCommonFormats() {
    let expected: [UInt8] = [0x00, 0x1b, 0x63, 0x84, 0x45, 0xe6]
    #expect(WakeOnLAN.parseMAC("00:1b:63:84:45:e6") == expected)
    #expect(WakeOnLAN.parseMAC("0:1b:63:84:45:e6") == expected)
    #expect(WakeOnLAN.parseMAC("00-1B-63-84-45-E6") == expected)
    #expect(WakeOnLAN.parseMAC("001b.6384.45e6") == expected)
    #expect(WakeOnLAN.parseMAC("001b638445e6") == expected)
    #expect(WakeOnLAN.parseMAC(" 00:1b:63:84:45:e6\n") == expected)
    #expect(WakeOnLAN.parseMAC("00:1b:63:84:45") == nil)
    #expect(WakeOnLAN.parseMAC("00:1b:63:84:45:zz") == nil)
    #expect(WakeOnLAN.parseMAC("000:1b:63:84:45:e6") == nil)
    #expect(WakeOnLAN.normalizeMAC("0:1B:63:84:45:E6") == "00:1b:63:84:45:e6")
}

@Test func magicPacketIsSixFFsAndSixteenMACs() {
    let mac: [UInt8] = [1, 2, 3, 4, 5, 6]
    let p = WakeOnLAN.magicPacket(mac)
    #expect(p.count == 102)
    #expect(Array(p.prefix(6)) == [UInt8](repeating: 0xFF, count: 6))
    for i in 0..<16 { #expect(Array(p[(6 + i * 6)..<(12 + i * 6)]) == mac) }
}

@Test func broadcastListStartsWithLimitedBroadcastAndHasNoDuplicates() {
    let list = WakeOnLAN.broadcastAddresses()
    #expect(list.first == "255.255.255.255")
    #expect(Set(list).count == list.count)
    for a in list {
        var addr = in_addr()
        #expect(inet_pton(AF_INET, a, &addr) == 1, "\(a) is not IPv4")
    }
    #expect(!list.contains("127.255.255.255"))
}

@Test func subnetBroadcastAndInvalidAddresses() {
    #expect(WakeOnLAN.subnetBroadcast(forIPv4: "10.0.5.23") == "10.0.5.255")
    #expect(WakeOnLAN.subnetBroadcast(forIPv4: "imac01.local") == nil)
    #expect(throws: WakeOnLAN.WOLError.self) { try WakeOnLAN.send(mac: "00:1b:63:84:45:e6", to: "999.1.1.1", port: 9) }
    #expect(throws: WakeOnLAN.WOLError.self) { try WakeOnLAN.wake(mac: "nie-mac") }
}

// MARK: - CSV

@Test func csvEscaping() {
    #expect(CSV.escape("imac01") == "imac01")
    #expect(CSV.escape("a;b") == "\"a;b\"")
    #expect(CSV.escape("powiedział \"tak\"") == "\"powiedział \"\"tak\"\"\"")
    #expect(CSV.escape("dwie\nlinie") == "\"dwie\nlinie\"")
    #expect(CSV.escape(" spacja") == "\" spacja\"")
    #expect(CSV.escape("a,b") == "a,b")
    #expect(CSV.escape("a,b", separator: ",") == "\"a,b\"")
}

@Test func csvRenderingUsesBOMAndCRLF() {
    let text = CSV.render([["Nazwa", "Uwagi"], ["imac01", "zażółć; gęślą"]])
    #expect(text == "\u{FEFF}Nazwa;Uwagi\r\nimac01;\"zażółć; gęślą\"\r\n")
    #expect(CSV.render([["a", "b"]], separator: ",", bom: false) == "a,b\r\n")
}

@Test func inventoryReportRows() {
    let m = Machine(name: "imac01", address: "imac01.local", user: "imac01", macAddress: "aa:bb:cc:dd:ee:ff", notes: "przy oknie")
    var st = HostStatus()
    st.reachability = .online
    st.info = ["os": "26.1", "build": "25B1", "disk": "500000000 10485760", "mac_ethernet": "00:11:22:33:44:55", "console": "student"]
    let rows = InventoryReport.rows(machines: [m], status: { _ in st }, lastSeen: { _ in nil })
    #expect(rows.count == 2)
    let header = rows[0], row = rows[1]
    func value(_ title: String) -> String { row[header.firstIndex(of: title)!] }
    #expect(value("Nazwa") == "imac01")
    #expect(value("Stan") == "online")
    #expect(value("macOS") == "26.1 25B1")
    #expect(value("MAC") == "00:11:22:33:44:55")
    #expect(value("Wolne miejsce (GB)") == "10")
    #expect(value("Zalogowany użytkownik") == "student")
    #expect(value("Uwagi") == "przy oknie")
}

// MARK: - Names, answers, versions

@Test func localHostNameFromDisplayName() {
    #expect(ComputerNames.localHostName(from: "Pracownia ą 01") == "Pracownia-a-01")
    #expect(ComputerNames.localHostName(from: "iMac 04/Łódź") == "iMac-04-Lodz")
    #expect(ComputerNames.localHostName(from: "--imac__05--") == "imac-05")
    #expect(ComputerNames.localHostName(from: String(repeating: "a", count: 80)).count == 63)
    #expect(ComputerNames.isValidLocalHostName("imac04"))
    #expect(!ComputerNames.isValidLocalHostName("imac 04"))
    #expect(!ComputerNames.isValidLocalHostName("-imac"))
    #expect(!ComputerNames.isValidLocalHostName(""))
    #expect(ComputerNames.addressAfterRename("imac04.local", localHostName: "imac14") == "imac14.local")
    #expect(ComputerNames.addressAfterRename("192.168.1.4", localHostName: "imac14") == nil)
}

@Test func studentAnswersAreParsed() {
    let text = StudentAnswer.parse("CMCR:USER:student\nCMCR:ANSWER:Wyślij\tskończyłem\tna pewno\n")
    #expect(text == StudentAnswer(kind: .answered, button: "Wyślij", text: "skończyłem\tna pewno", user: "student"))
    #expect(text?.displayText == "skończyłem\tna pewno")
    let button = StudentAnswer.parse("CMCR:USER:ola\nCMCR:ANSWER:Tak")
    #expect(button?.displayText == "Tak")
    #expect(StudentAnswer.parse("CMCR:USER:ola\nCMCR:TIMEOUT")?.kind == .timedOut)
    #expect(StudentAnswer.parse("CMCR:NO_USER\nNikt nie jest zalogowany.")?.kind == .noUser)
    #expect(StudentAnswer.parse("coś innego") == nil)
}

@Test func appVersionLinesAreParsed() {
    let list = AppVersionInfo.parse("CMCR:APP:/Applications/Unity Hub.app\t3.12.0\t3.12.0\nBrak\nCMCR:APP:/Applications/X.app\t\t\n")
    #expect(list.count == 2)
    #expect(list[0] == AppVersionInfo(path: "/Applications/Unity Hub.app", version: "3.12.0", build: "3.12.0"))
    #expect(list[1].version.isEmpty)
}

@Test func polishPluralForms() {
    #expect("1 \(Plural.computers(1))" == "1 komputer")
    #expect("3 \(Plural.computers(3))" == "3 komputery")
    #expect("5 \(Plural.computers(5))" == "5 komputerów")
    #expect("12 \(Plural.computers(12))" == "12 komputerów")
    #expect("22 \(Plural.computers(22))" == "22 komputery")
    #expect(Plural.computersLocative(1) == "komputerze")
    #expect(Plural.computersLocative(15) == "komputerach")
}

// MARK: - Lesson routines and configuration

@Test func lessonPlansFollowTheConfiguration() {
    var start = LessonStartConfig()
    start.sendMaterials = true
    start.openApps = true
    start.apps = "Unity Hub,\n Safari ,"
    #expect(start.appList == ["Unity Hub", "Safari"])
    let s = LessonPlan.start(start, settings: AppSettings())
    #expect(s.steps == [.wake, .materials, .openApps, .greet])
    #expect(s.materialsDestination == "/Users/student/Public/cmcr")
    start.destination = .studentDesktop
    #expect(LessonPlan.start(start, settings: AppSettings()).materialsDestination == "/Users/student/Desktop")

    var end = LessonEndConfig()
    end.warn = true
    end.cleanShared = true
    end.logout = true
    end.power = .shutdown
    let e = LessonPlan.end(end, settings: AppSettings())
    #expect(e.steps == [.warn, .collect, .cleanShared, .logout, .shutdown])
    #expect(e.collectFolder != nil)
    #expect(end.isDisruptive)
    #expect(!LessonEndConfig().isDisruptive)

    // Apps are closed before the work is collected.
    end.quitApps = true
    end.quitAllApps = true
    #expect(LessonPlan.end(end, settings: AppSettings()).steps == [.warn, .quitApps, .collect, .cleanShared, .logout, .shutdown])
}

@Test func studentFolderIsNeverCleanedWithoutCollecting() {
    var end = LessonEndConfig()
    end.collect = false
    end.cleanShared = true
    end.cleanDownloads = true
    let plan = LessonPlan.end(end, settings: AppSettings())
    #expect(plan.steps == [.cleanDownloads])
    #expect(plan.collectFolder == nil)
    end.cleanDownloads = false
    #expect(!end.isDisruptive)
}

@Test func cleaningStepWithoutCollectIsSkippedAtRunTime() async {
    // A hand-made plan (not from LessonPlan.end) must still never empty the folder without collecting.
    var plan = LessonPlan.end(LessonEndConfig(), settings: AppSettings())
    plan.steps = [.cleanShared]
    let host = LessonRunner.Host(machine: Machine(name: "x", address: "192.0.2.1", user: "admin"), password: nil, macs: [])
    let states = StepRecorder()
    let r = await LessonRunner.run(plan, on: host, ssh: SSHSettings(askpassPath: "/usr/bin/false"), materials: nil,
                                   onStep: { i, st in states.add(i, st) })
    #expect(r.succeeded)
    #expect(states.all == [StepRecord(index: 0, state: .skipped("nie zebrano prac – folder pozostawiono"))])
}

private struct StepRecord: Equatable {
    var index: Int
    var state: StepState
}

private final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [StepRecord] = []
    func add(_ i: Int, _ s: StepState) { lock.lock(); records.append(StepRecord(index: i, state: s)); lock.unlock() }
    var all: [StepRecord] { lock.lock(); defer { lock.unlock() }; return records }
}

@Test func concurrencyLimiterNeverExceedsItsLimit() async {
    let limiter = ConcurrencyLimiter(limit: 3)
    let counter = PeakCounter()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
            group.addTask {
                await limiter.acquire()
                await counter.enter()
                try? await Task.sleep(nanoseconds: 5_000_000)
                await counter.leave()
                await limiter.release()
            }
        }
    }
    #expect(await counter.peak == 3)
    #expect(await counter.done == 12)

    let one = ConcurrencyLimiter(limit: 1)
    #expect(await one.tryAcquire())
    #expect(await !one.tryAcquire())
    await one.release()
    #expect(await one.tryAcquire())
}

private actor PeakCounter {
    var current = 0, peak = 0, done = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1; done += 1 }
}

@Test func collectFolderIsTimestampedAndLabelled() {
    var c = DateComponents()
    c.year = 2026; c.month = 10; c.day = 5; c.hour = 14; c.minute = 30
    let date = Calendar.current.date(from: c)!
    let url = LessonPlan.collectFolder(base: "/tmp/cmcr", label: " 3A/Unity ", date: date)
    #expect(url.path == "/tmp/cmcr/zebrane/2026-10-05_14-30 3A-Unity")
    #expect(LessonPlan.collectFolder(base: "/tmp/cmcr", label: "", date: date).lastPathComponent == "2026-10-05_14-30")
}

@Test func classroomConfigToleratesMissingAndUnknownValues() throws {
    let json = #"{"lockMode":"cos-nowego","start":{"greet":false},"schedule":{"offType":"shutdown"},"autoUnlockMinutes":10}"#
    let c = try JSONDecoder().decode(ClassroomConfig.self, from: Data(json.utf8))
    #expect(c.lockMode == .automatic)
    #expect(c.start.greet == false)
    #expect(c.start.wake == true)
    #expect(c.schedule.offType == .shutdown)
    #expect(c.schedule.onTime == ClockTime(7, 45))
    #expect(c.autoUnlockMinutes == 10)
    let again = try JSONDecoder().decode(ClassroomConfig.self, from: JSONEncoder().encode(c))
    #expect(again == c)
}

@Test func questionButtonsSurviveTextMode() throws {
    // Configs saved before questionWithButtons existed: saved buttons meant "answer with buttons".
    let old = try JSONDecoder().decode(ClassroomConfig.self, from: Data(#"{"questionButtons":"Tak, Nie ,,Pomocy"}"#.utf8))
    #expect(old.questionWithButtons)
    #expect(old.questionButtonList == ["Tak", "Nie", "Pomocy"])
    var c = old
    c.questionWithButtons = false
    let back = try JSONDecoder().decode(ClassroomConfig.self, from: JSONEncoder().encode(c))
    #expect(!back.questionWithButtons)
    #expect(back.questionButtons == "Tak, Nie ,,Pomocy")
    #expect(!ClassroomConfig().questionWithButtons)
}

@Test func hostSnapshotRestoresInfoButNotReachability() throws {
    var st = HostStatus()
    st.reachability = .online
    st.info = ["os": "26.1", "fv": "on", "console": "student"]
    st.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let snap = HostSnapshot(st, lastSeen: st.updatedAt)
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let back = try dec.decode(HostSnapshot.self, from: enc.encode(snap))
    #expect(back == snap)
    let restored = back.restored
    #expect(restored.reachability == .unknown)
    #expect(restored.osVersion == "26.1")
    #expect(restored.fileVaultOn == true)
    #expect(restored.consoleUser == nil)
}

@Test func uptimeIsShownOnlyWhileTheMacAnswers() throws {
    var st = HostStatus()
    st.info = ["boot": String(Int(Date().timeIntervalSince1970) - 3 * 86_400 - 2 * 3600)]
    st.reachability = .online
    #expect(st.liveUptimeText == "3 d 2 h")
    #expect((st.liveUptime ?? 0) > 3 * 86_400)
    st.reachability = .offline
    #expect(st.liveUptimeText == nil)
    #expect(st.liveUptime == nil)
    st.reachability = .online
    let restored = HostSnapshot(st, lastSeen: Date()).restored
    #expect(restored.bootDate == nil)
}

// MARK: - Generated scripts

private func bashSyntaxError(_ script: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-n"]
    let input = Pipe(), err = Pipe()
    p.standardInput = input
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    try? p.run()
    input.fileHandleForWriting.write(Data(script.utf8))
    try? input.fileHandleForWriting.close()
    p.waitUntilExit()
    let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return p.terminationStatus == 0 ? nil : msg
}

@Test func classroomScriptsAreValidBash() {
    let nasty = "Tytuł \"cudzysłów\" 'apostrof' $HOME `id` \\ ąę\nnowa linia"
    var schedule = EnergySchedule()
    schedule.offType = .shutdown
    let scripts: [(String, RemoteScript)] = [
        ("lock", Scripts.lockScreen(message: nasty, mode: .automatic, autoUnlockMinutes: 30)),
        ("lock-overlay", Scripts.lockScreen(message: "", mode: .overlay, autoUnlockMinutes: 0)),
        ("unlock", Scripts.unlockScreen()),
        ("ask", Scripts.ask(title: nasty, prompt: nasty, buttons: [], timeoutSeconds: 60)),
        ("ask-buttons", Scripts.ask(title: "t", prompt: "p", buttons: ["Tak", nasty, "Nie", "Czwarty"], timeoutSeconds: 5)),
        ("delayed", Scripts.delayedPower(.shutdown, minutes: 5, warning: nasty)),
        ("delayed-now", Scripts.delayedPower(.sleep, minutes: 0, warning: nil)),
        ("cancel-delayed", Scripts.cancelDelayedPower()),
        ("filevault", Scripts.fileVaultStatus()),
        ("schedule", Scripts.applyEnergySchedule(schedule, autoRestart: true, wakeOnLAN: false)),
        ("schedule-invalid", Scripts.applyEnergySchedule({ var s = EnergySchedule(); s.onDays = []; return s }(),
                                                         autoRestart: false, wakeOnLAN: false)),
        ("schedule-cancel", Scripts.cancelEnergySchedule()),
        ("schedule-status", Scripts.energyScheduleStatus()),
        ("names", Scripts.computerNames()),
        ("rename", Scripts.renameComputer(computerName: nasty, localHostName: "imac-01")),
        ("app-version", Scripts.appVersion(nasty)),
        ("quit-all", Scripts.quitAllApps()),
        ("ping", Scripts.ping()),
    ]
    for (name, script) in scripts {
        #expect(bashSyntaxError(script.body) == nil, "\(name): \(bashSyntaxError(script.body) ?? "")")
        #expect(bashSyntaxError(script.render()) == nil, "\(name) (render)")
    }
}

@Test func killPatternsNeverAppearLiterallyInScripts() {
    // pkill -f would otherwise match the remote wrapper, whose argv carries the whole script.
    for script in [Scripts.lockScreen(message: "x", mode: .automatic, autoUnlockMinutes: 5), Scripts.unlockScreen(),
                   Scripts.delayedPower(.restart, minutes: 1, warning: "x"), Scripts.cancelDelayedPower()] {
        let text = script.render()
        #expect(!text.contains("CMCR_ATTENTION"))
        #expect(!text.contains("cmcr-delayed-power"))
    }
}

private func osacompile(_ source: String, language: String) -> String? {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-test-\(UUID().uuidString).scpt")
    defer { try? FileManager.default.removeItem(at: out) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
    p.arguments = ["-l", language, "-o", out.path, "-e", source]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    do { try p.run() } catch { return "osacompile: \(error)" }
    p.waitUntilExit()
    let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return p.terminationStatus == 0 ? nil : msg
}

@Test func attentionOverlayAndQuestionDialogCompile() {
    let tricky = "Patrz \"tu\" \\ 'tam'\nlinia\u{2028}separator ąę"
    let jxa = Scripts.attentionOverlayJXA(message: tricky)
    #expect(osacompile(jxa, language: "JavaScript") == nil)
    #expect(jxa.contains("\\u2028"))
    #expect(!jxa.contains("\u{2028}"))
    for buttons in [[], ["Tak", "Nie \"może\""]] {
        let apple = Scripts.askAppleScript(title: tricky, prompt: tricky, buttons: buttons, timeoutSeconds: 30)
        #expect(osacompile(apple, language: "AppleScript") == nil, "\(buttons)")
    }
}
