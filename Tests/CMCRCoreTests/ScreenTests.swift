import CoreGraphics
import Foundation
import Testing
@testable import CMCRCore

// MARK: - Layout and scheduling

@Test func fitColumnsShowsFifteenScreensWithoutScrolling() {
    #expect(ScreenLayout.fitColumns(count: 15, width: 1600, height: 1000, spacing: 8) == 4)
    #expect(ScreenLayout.fitColumns(count: 1, width: 1600, height: 1000, spacing: 8) == 1)
    #expect(ScreenLayout.fitColumns(count: 2, width: 1600, height: 500, spacing: 8) == 2)
    #expect(ScreenLayout.fitColumns(count: 4, width: 800, height: 1200, spacing: 8) == 1)
    #expect(ScreenLayout.fitColumns(count: 30, width: 400, height: 300, spacing: 8, maxColumns: 6) <= 6)
}

@Test func fitColumnsAccountsForLabelHeight() {
    let without = ScreenLayout.fitColumns(count: 6, width: 1200, height: 520, spacing: 8)
    let with = ScreenLayout.fitColumns(count: 6, width: 1200, height: 520, spacing: 8, chrome: 120)
    #expect(with >= without)
}

@Test func adaptiveColumnsAndTileWidth() {
    #expect(ScreenLayout.adaptiveColumns(width: 1000, minTileWidth: 320, spacing: 12) == 3)
    #expect(ScreenLayout.adaptiveColumns(width: 200, minTileWidth: 320, spacing: 12) == 1)
    #expect(ScreenLayout.tileWidth(columns: 4, width: 1624, spacing: 8) == 400)
}

@Test func captureSizeIsQuantizedAndCapped() {
    #expect(ScreenLayout.captureSize(points: 300, scale: 2, cap: 1280) == 640)
    #expect(ScreenLayout.captureSize(points: 301, scale: 2, cap: 1280) == 640)
    #expect(ScreenLayout.captureSize(points: 321, scale: 2, cap: 1280) == 800)
    #expect(ScreenLayout.captureSize(points: 2000, scale: 2, cap: 1280) == 1280)
    #expect(ScreenLayout.captureSize(points: 0, scale: 2, cap: 1280) == 320)
    #expect(ScreenLayout.captureSize(points: 100, scale: 1, cap: 200) == 320)
    // Dragging a slider by a few points does not change the request.
    let sizes = Set(stride(from: 330.0, to: 400.0, by: 1).map { ScreenLayout.captureSize(points: $0, scale: 2, cap: 1600) })
    #expect(sizes.count <= 2)
}

@Test func backoffGrowsAndIsCapped() {
    #expect(ScreenSchedule.backoff(failures: 0) == 0)
    #expect(ScreenSchedule.backoff(failures: 1) == 10)
    #expect(ScreenSchedule.backoff(failures: 2) == 20)
    #expect(ScreenSchedule.backoff(failures: 3) == 40)
    #expect(ScreenSchedule.backoff(failures: 5) == 120)
    #expect(ScreenSchedule.backoff(failures: 500) == 120)
}

@Test func jitterStaysWithinRange() {
    #expect(ScreenSchedule.jitter(maximum: 2, random: 0) == 0)
    #expect(ScreenSchedule.jitter(maximum: 2, random: 0.5) == 1)
    #expect(ScreenSchedule.jitter(maximum: 2, random: 7) == 2)
    for _ in 0..<50 { #expect((0...2).contains(ScreenSchedule.jitter(maximum: 2))) }
}

@Test func watchdogAndFreshnessFollowTheInterval() {
    #expect(ScreenSchedule.watchdogLimit(interval: 3) == 45)
    #expect(ScreenSchedule.watchdogLimit(interval: 30) == 110)
    #expect(ScreenFreshness.of(age: 12, interval: 10) == .fresh)
    #expect(ScreenFreshness.of(age: 40, interval: 10) == .stale)
    #expect(ScreenFreshness.of(age: 600, interval: 10) == .old)
}

@Test func observersAreMergedIntoOneRequest() {
    #expect(ScreenSchedule.merge([], fallbackInterval: 10) == nil)
    let m = ScreenSchedule.merge([(640, 10), (1600, 5), (960, 0)], fallbackInterval: 10)
    #expect(m?.pixels == 1600)
    #expect(m?.interval == 5)
    #expect(ScreenSchedule.merge([(640, 1)], fallbackInterval: 10)?.interval == 2)
}

// MARK: - Notification sessions

@Test func ledgerKeepsNotificationWithinGraceAndForgetsAfter() {
    var ledger = ObservationLedger(grace: 120)
    let host = UUID()
    let t0 = Date(timeIntervalSince1970: 1000)
    ledger.observed(host, at: t0)
    ledger.recordNotified(host, user: "student")
    // A tile scrolled away and back (or a paused window) keeps the session.
    ledger.unobserved(host, at: t0.addingTimeInterval(10))
    ledger.observed(host, at: t0.addingTimeInterval(60))
    #expect(ledger.notifiedUser(host) == "student")
    // Not observed for longer than the grace period: the next preview notifies again.
    ledger.unobserved(host, at: t0.addingTimeInterval(100))
    let early = ledger.expire(at: t0.addingTimeInterval(150))
    let late = ledger.expire(at: t0.addingTimeInterval(230))
    #expect(early.isEmpty)
    #expect(late == [host])
    #expect(ledger.notifiedUser(host) == nil)
}

@Test func ledgerEndsSessionWhenObservationResumesLate() {
    var ledger = ObservationLedger(grace: 60)
    let host = UUID()
    let t0 = Date(timeIntervalSince1970: 0)
    ledger.recordNotified(host, user: "a")
    let first = ledger.shouldLog(host, user: "a")
    let again = ledger.shouldLog(host, user: "a")
    let other = ledger.shouldLog(host, user: "b")
    #expect(first && !again && other)
    ledger.unobserved(host, at: t0)
    ledger.observed(host, at: t0.addingTimeInterval(61))
    #expect(ledger.notifiedUser(host) == nil)
    let afterSession = ledger.shouldLog(host, user: "b")
    #expect(afterSession)
}

// MARK: - Protocol

private func frameBytes(display: Int, count: Int, payload: Data, hash: String = "h") -> Data {
    Data("CMCR1\tFRAME\t\(display)\t\(count)\t\(payload.count)\t\(hash)\n".utf8) + payload
}

@Test func parserHandlesFramesSplitAcrossChunks() {
    let payload = Data((0..<5000).map { UInt8($0 % 251) })
    var stream = Data("noise from a tool\nCMCR1\tHELLO\troot\t0\nCMCR1\tINFO\tstudent\tSafari\n".utf8)
    stream += frameBytes(display: 1, count: 1, payload: payload, hash: "abc")
    stream += Data("CMCR1\tSAME\t1\t1\tabc\nCMCR1\tNOTIFIED\tstudent\nCMCR1\tBYE\tmaxtime\n".utf8)
    var parser = ScreenStreamParser()
    var events: [ScreenEvent] = []
    for i in stride(from: 0, to: stream.count, by: 7) {
        events += parser.feed(stream.subdata(in: i..<min(stream.count, i + 7)))
    }
    #expect(events == [
        .hello(privileged: true),
        .info(user: "student", frontApp: "Safari"),
        .frame(display: 1, count: 1, hash: "abc", data: payload),
        .unchanged(display: 1, count: 1, hash: "abc"),
        .notified(user: "student"),
        .bye(reason: "maxtime"),
    ])
}

@Test func parserMapsStates() {
    var parser = ScreenStreamParser()
    let events = parser.feed(Data("""
    CMCR1\tSTATE\tnouser
    CMCR1\tSTATE\tdenied\tjan
    CMCR1\tSTATE\tadmin\timac01
    CMCR1\tSTATE\tsudo-missing\tstudent
    CMCR1\tSTATE\tsudo-wrong\tstudent
    CMCR1\tSTATE\tsudo-denied\tstudent
    CMCR1\tSTATE\tcapture\tstudent\tcould not create image from display
    CMCR1\tINFO\t\t
    CMCR1\tSTATE\tbogus

    """.utf8))
    #expect(events == [
        .state(.noUser), .state(.userNotAllowed("jan")), .state(.adminAccount("imac01")),
        .state(.sudoPasswordMissing), .state(.sudoPasswordWrong), .state(.sudoNotPermitted),
        .state(.captureFailed("could not create image from display")),
        .info(user: nil, frontApp: nil),
    ])
}

@Test func sudoProblemsAreNotReportedAsScreenRecordingPermission() {
    for issue in [ScreenIssue.sudoPasswordMissing, .sudoPasswordWrong, .sudoNotPermitted] {
        #expect(!issue.message.contains("Nagrywanie"))
        #expect(issue.exitCode == ScriptCode.captureSudoFailed)
        #expect(!issue.isIdle)
    }
    #expect(ScreenIssue.captureFailed("").message.contains("Nagrywanie ekranu"))
    #expect(ScreenIssue.noUser.isIdle && ScreenIssue.adminAccount("x").hidesImage)
}

@Test func singleCaptureResultIsInterpreted() {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    var out = Data("CMCR1\tHELLO\tuser\t501\nCMCR1\tNOTIFIED\tjan\nCMCR1\tINFO\tjan\tKeynote\n".utf8)
    out += frameBytes(display: 1, count: 1, payload: jpeg)
    let ok = Operations.screenshot(from: CommandResult(exitCode: 0, stdout: out))
    #expect(ok.imageData == jpeg)
    #expect(ok.user == "jan" && ok.frontApp == "Keynote" && ok.notifiedUser == "jan")
    #expect(ok.issue == nil && ok.message == nil)

    let wrong = Operations.screenshot(from: CommandResult(
        exitCode: ScriptCode.captureSudoFailed,
        stdout: Data("CMCR1\tSTATE\tsudo-wrong\tjan\n".utf8),
        stderr: Data("Sorry, try again.\n".utf8)))
    #expect(wrong.imageData == nil)
    #expect(wrong.issue == .sudoPasswordWrong)
    #expect(wrong.message?.contains("Błędne hasło") == true)

    let offline = Operations.screenshot(from: CommandResult(
        exitCode: 255, stderr: Data("ssh: Could not resolve hostname imac99.local: nodename nor servname provided\n".utf8)))
    if case .connection(let reach, _)? = offline.issue { #expect(reach == .offline) } else { Issue.record("brak błędu połączenia") }
}

// MARK: - Remote script

private func bashSyntaxCheck(_ text: String) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-n"]
    let inPipe = Pipe(), errPipe = Pipe()
    p.standardInput = inPipe
    p.standardError = errPipe
    try? p.run()
    inPipe.fileHandleForWriting.write(Data(text.utf8))
    try? inPipe.fileHandleForWriting.close()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

@Test func captureScriptIsValidBashAndQuotesUserValues() {
    let o = ScreenCaptureOptions(maxSize: 999_999, quality: 500, interval: 0, notify: true,
                                 alreadyNotifiedUser: "o'brien $(reboot)", onlyStandardAccounts: true,
                                 allowedUsers: ["student", "a'b"], display: .all, frames: 0)
    let script = Scripts.screenCapture(o)
    #expect(!script.asRoot)
    let (code, err) = bashSyntaxCheck(script.body)
    #expect(code == 0, "\(err)")
    #expect(bashSyntaxCheck(script.render()).0 == 0)
    #expect(script.body.contains("CMCR_LAST='o'\\''brien $(reboot)'"))
    #expect(script.body.contains("CMCR_ALLOWED='student,a'\\''b'"))
    #expect(script.body.contains("CMCR_MAXSIZE=5120"))
    #expect(script.body.contains("CMCR_QUALITY=100"))
    #expect(script.body.contains("CMCR_INTERVAL=2"))
    #expect(script.body.contains("CMCR_DISPLAY='all'"))
    // Captures JPEG directly; no PNG round trip.
    #expect(script.body.contains("-t jpg") && !script.body.contains("-t png"))
}

@Test func legacyScreenshotBuilderStillWorks() {
    let s = Scripts.screenshot(maxSize: 640, quality: 60, notify: false, onlyStandard: false, allowedUsers: [])
    #expect(s.body.contains("CMCR_FRAMES=1") && s.body.contains("CMCR_NOTIFY=0") && s.body.contains("CMCR_ONLYSTD=0"))
    #expect(bashSyntaxCheck(s.body).0 == 0)
}

@Test func displaysAndCommandsRoundTrip() {
    for d in [ScreenDisplay.main, .all, .number(2)] { #expect(ScreenDisplay(scriptValue: d.scriptValue) == d) }
    #expect(ScreenDisplay(scriptValue: "0") == nil)
    #expect(ScreenStreamCommand.size(10).line == "size 320")
    #expect(ScreenStreamCommand.interval(0).line == "interval 2")
    #expect(ScreenStreamCommand.display(.number(3)).line == "display 3")
}

// MARK: - Images

private func solidImage(width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

@Test func imagesAreDecodedWithinTheRequestedSize() throws {
    let big = try #require(solidImage(width: 2000, height: 1250))
    let jpeg = try #require(ScreenImage.encode(big))
    let decoded = try #require(ScreenImage.decode(jpeg, maxPixel: 640))
    #expect(max(decoded.width, decoded.height) <= 640)
    #expect(ScreenImage.decode(Data("not an image".utf8), maxPixel: 640) == nil)
}

@Test func displaysAreComposedSideBySide() throws {
    let a = try #require(solidImage(width: 160, height: 100))
    let b = try #require(solidImage(width: 80, height: 50))
    let both = try #require(ScreenImage.sideBySide([a, b], gap: 10))
    #expect(both.height == 100)
    #expect(both.width == 160 + 10 + 160)
    #expect(ScreenImage.sideBySide([a]) === a)
    #expect(ScreenImage.sideBySide([]) == nil)
}
