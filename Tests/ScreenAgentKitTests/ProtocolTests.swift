import CMCRCore
import Darwin
import Foundation
import Testing
@testable import ScreenAgentKit

// MARK: - The agent's copy of the constants

@Test func agentConstantsMatchCMCRCore() {
    #expect(AgentInfo.version == ScreenAgentInfo.version)
    #expect(AgentInfo.label == ScreenAgentInfo.label)
    #expect(AgentInfo.bundleID == ScreenAgentInfo.bundleID)
    #expect(AgentInfo.displayName == ScreenAgentInfo.displayName)
    #expect(AgentInfo.appName == ScreenAgentInfo.appName)
    #expect(AgentInfo.executableName == ScreenAgentInfo.executableName)
    #expect(AgentInfo.protocolVersion == ScreenAgentInfo.protocolVersion)
    #expect(AgentInfo.installDir == ScreenAgentInfo.installDir)
    #expect(AgentInfo.appPath == ScreenAgentInfo.appPath)
    #expect(AgentInfo.executablePath == ScreenAgentInfo.executablePath)
    #expect(AgentInfo.runDir == ScreenAgentInfo.runDir)
    #expect(AgentInfo.shotsDir == ScreenAgentInfo.shotsDir)
    #expect(AgentInfo.plistPath == ScreenAgentInfo.plistPath)
    typealias A = AgentInfo.ClientCode
    typealias C = ScreenAgentInfo.ClientCode
    #expect(A.ok == C.ok)
    #expect(A.usage == C.usage)
    #expect(A.unreachable == C.unreachable)
    #expect(A.untrusted == C.untrusted)
    #expect(A.noPermission == C.noPermission)
    #expect(A.locked == C.locked)
    #expect(A.noImage == C.noImage)
    #expect(A.captureFailed == C.captureFailed)
    #expect(A.protocolError == C.protocolError)
    // The LaunchAgent starts exactly this executable in serve mode.
    #expect(ScreenAgentInfo.launchAgentPlist().contains("<string>\(AgentInfo.executablePath)</string>"))
}

@Test func agentPathsApplyThePrefix() {
    let plain = AgentPaths()
    #expect(plain.socketPath(uid: 501) == "/Library/Application Support/CMCR/ScreenAgent/run/501.sock")
    #expect(plain.shotsDir(uid: 502) == "/Library/Application Support/CMCR/ScreenAgent/shots/502")
    #expect(plain.executablePath == ScreenAgentInfo.executablePath)
    let test = AgentPaths(prefix: "/tmp/x/setup-root//")
    #expect(test.prefix == "/tmp/x/setup-root")
    #expect(test.runDir == "/tmp/x/setup-root/Library/Application Support/CMCR/ScreenAgent/run")
    #expect(test.executablePath == "/tmp/x/setup-root" + ScreenAgentInfo.executablePath)
    // Unit tests are DEBUG builds: the variable counts.
    #expect(AgentPaths.current(environment: ["CMCR_SETUP_ROOT_PREFIX": "/p"]).prefix == "/p")
    #expect(AgentPaths.current(environment: [:]).prefix == "")
}

// MARK: - Requests

@Test func requestsRoundTrip() throws {
    let requests: [AgentRequest] = [
        .ping, .front, .requestPermission,
        .capture(maxSide: 1280, quality: 70, display: .main),
        .capture(maxSide: 16, quality: 10, display: .all),
        .capture(maxSide: 16384, quality: 100, display: .number(9)),
        .notice(title: "Podgląd ekranu", text: "Administrator rozpoczął podgląd Twojego ekranu."),
        .notice(title: "", text: "zażółć gęślą jaźń\nnowy wiersz \t tab"),
    ]
    for r in requests {
        #expect(!r.line.contains("\n"))
        #expect(try AgentRequest.parse(r.line) == r)
    }
    #expect(AgentRequest.ping.line == "CMCRA1 PING")
    #expect(AgentRequest.capture(maxSide: 640, quality: 60, display: .number(2)).line == "CMCRA1 CAPTURE 640 60 2")
    #expect(AgentRequest.requestPermission.line == "CMCRA1 REQUEST-PERMISSION")
    #expect(AgentRequest.notice(title: "a", text: "").line == "CMCRA1 NOTICE YQ== -")
}

@Test func malformedRequestsAreRefused() {
    let bad = [
        "", "PING", "CMCRA2 PING", "cmcra1 PING", "CMCRA1", "CMCRA1 ", "CMCRA1 PING ", "CMCRA1  PING", "CMCRA1 PING x",
        "CMCRA1 SHUTDOWN", "CMCRA1 CAPTURE", "CMCRA1 CAPTURE 640 70", "CMCRA1 CAPTURE 640 70 main x",
        "CMCRA1 CAPTURE 15 70 main", "CMCRA1 CAPTURE 16385 70 main", "CMCRA1 CAPTURE -640 70 main",
        "CMCRA1 CAPTURE +640 70 main", "CMCRA1 CAPTURE 640 9 main", "CMCRA1 CAPTURE 640 101 main",
        "CMCRA1 CAPTURE 640 70 0", "CMCRA1 CAPTURE 640 70 10", "CMCRA1 CAPTURE 640 70 Main",
        "CMCRA1 CAPTURE 64O 70 main", "CMCRA1 NOTICE YQ==", "CMCRA1 NOTICE YQ== %%%", "CMCRA1 NOTICE /w== YQ==",
    ]
    for line in bad {
        #expect(throws: ProtocolError.self, "\(line)") { try AgentRequest.parse(line) }
    }
}

// MARK: - Replies

@Test func repliesRoundTrip() throws {
    let replies: [AgentReply] = [
        .ping(AgentStatus(permissionGranted: true, locked: false, onConsole: true, asleep: false, user: "uczen")),
        .ping(AgentStatus(version: "2.0.0", permissionGranted: false, locked: true, onConsole: false, asleep: true, user: "")),
        .capture(count: 1, frontApp: "Safari"),
        .capture(count: 9, frontApp: ""),
        .notice(.shown), .notice(.hidden), .notice(.locked),
        .front("Microsoft Word"), .front(""),
        .permission(granted: true), .permission(granted: false),
        .error(.noperm, "brak uprawnienia"), .error(.protocol, ""), .error(code: "future", message: "x y"),
    ]
    for r in replies {
        #expect(!r.line.contains("\n"))
        #expect(try AgentReply.parse(r.line) == r)
    }
    let ping = AgentReply.ping(AgentStatus(permissionGranted: true, locked: false, onConsole: true, asleep: false, user: "jan"))
    #expect(ping.line == "OK PING \(AgentInfo.version) perm=granted locked=0 console=1 asleep=0 user=amFu")
    #expect(AgentReply.capture(count: 2, frontApp: "Finder").line == "OK CAPTURE 2 RmluZGVy")
    #expect(AgentReply.error(.locked, "").line == "ERR locked -")
}

@Test func replyParsingIsTolerantWhereANewerAgentMayDiffer() throws {
    // Extra and reordered PING fields, unpadded base64.
    let r = try AgentReply.parse("OK PING 1.1.0 asleep=0 user=amFu perm=denied locked=1 console=1 extra=7")
    #expect(r == .ping(AgentStatus(version: "1.1.0", permissionGranted: false, locked: true, onConsole: true,
                                   asleep: false, user: "jan")))
    #expect(try AgentReply.parse("ERR newcode") == .error(code: "newcode", message: ""))
    #expect(try AgentReply.parse("ERR failed zwykły tekst!") == .error(code: "failed", message: "zwykły tekst!"))
    #expect(try AgentReply.parse("OK FRONT RmluZGVy") == .front("Finder"))
    for bad in ["", "OK", "OK PING", "OK PING 1.0.0 locked=0", "OK PING 1.0.0 perm=maybe", "OK CAPTURE 0 -",
                "OK CAPTURE 10 -", "OK CAPTURE 1", "OK NOTICE maybe", "OK FRONT %%%", "OK PERMISSION yes",
                "ERR", "ERR ", "HELLO", "OK UNKNOWN x"] {
        #expect(throws: ProtocolError.self, "\(bad)") { try AgentReply.parse(bad) }
    }
}

@Test func imageHeadersAreStrict() throws {
    let h = ImageHeader(display: 2, width: 1280, height: 800, byteCount: 123_456)
    #expect(h.line == "IMG 2 1280 800 123456")
    #expect(try ImageHeader.parse(h.line) == h)
    for bad in ["IMG 0 10 10 10", "IMG 10 10 10 10", "IMG 1 0 10 10", "IMG 1 10 10 0", "IMG 1 10 10",
                "IMG 1 10 10 10 10", "IMG 1 10 10 \(AgentInfo.maxImageBytes + 1)", "IMG 1 10 10 -5", "img 1 10 10 10"] {
        #expect(throws: ProtocolError.self, "\(bad)") { try ImageHeader.parse(bad) }
    }
}

@Test func errorCodesMapToClientExitCodes() {
    #expect(AgentErrorCode.noperm.clientExitCode == 12)
    #expect(AgentErrorCode.locked.clientExitCode == 13)
    #expect(AgentErrorCode.notconsole.clientExitCode == 14)
    #expect(AgentErrorCode.asleep.clientExitCode == 14)
    #expect(AgentErrorCode.nodisplay.clientExitCode == 14)
    #expect(AgentErrorCode.failed.clientExitCode == 15)
    #expect(AgentErrorCode.protocol.clientExitCode == 16)
    #expect(AgentErrorCode.clientExitCode(for: "something-new") == 1)
}

@Test func clientOutputLines() {
    let s = AgentStatus(permissionGranted: false, locked: true, onConsole: true, asleep: false, user: "uczeń 1")
    #expect(ClientOutput.agent(s) == "AGENT \(AgentInfo.version) perm=denied locked=1 console=1 asleep=0 user=uczeń 1")
    #expect(ClientOutput.front("Safari") == "FRONT Safari")
    #expect(ClientOutput.front("") == "FRONT ")
    let h = ImageHeader(display: 1, width: 640, height: 400, byteCount: 999)
    #expect(ClientOutput.shot(h, path: "/Library/Application Support/x/screen-1.jpg")
        == "SHOT 1 640 400 999 /Library/Application Support/x/screen-1.jpg")
    #expect(ClientOutput.notice(.locked) == "NOTICE locked")
    #expect(ClientOutput.permission(granted: true) == "PERMISSION granted")
    #expect(ClientOutput.error("noperm", "brak\nuprawnienia") == "ERR noperm brak uprawnienia")
    #expect(ClientOutput.error("protocol", "") == "ERR protocol")
    // An app name cannot start a line of its own.
    #expect(!ClientOutput.front("Evil\nSHOT 1 1 1 1 /etc/passwd").contains("\n"))
    #expect(!ClientOutput.front("A\r\u{2028}B\u{85}C").contains(where: { $0.isNewline }))
}

// MARK: - Base64 and text

@Test func base64Fields() {
    for s in ["", "a", "ab", "abc", "Podgląd ekranu", "zażółć gęślą jaźń 🎓", "a b\nc"] {
        let f = Base64Field.encode(s)
        #expect(!f.isEmpty && !f.contains(" ") && !f.contains("\n"))
        #expect(Base64Field.decode(f) == s)
    }
    #expect(Base64Field.encode("") == "-")
    #expect(Base64Field.decode("") == "")
    #expect(Base64Field.decode("-") == "")
    #expect(Base64Field.decode("YQ") == "a")          // without padding (base64 tools differ)
    #expect(Base64Field.decode("YWI") == "ab")
    #expect(Base64Field.decode("Y") == nil)
    #expect(Base64Field.decode("YQ==\n") == nil)
    #expect(Base64Field.decode("Y Q==") == nil)
    #expect(Base64Field.decode("/w==") == nil)        // 0xFF is not UTF-8
    #expect(Base64Field.decode("@@@@") == nil)
}

@Test func lineTextReplacesControlCharacters() {
    #expect(LineText.clean("a\tb\nc\rd\u{0}e\u{7F}f\u{2029}g") == "a b c d e f g")
    #expect(LineText.clean("Zażółć – „cudzysłów”") == "Zażółć – „cudzysłów”")
}

// MARK: - Displays and scaling

@Test func displaySelectionTokensAndNumbers() {
    #expect(DisplaySelection(token: "main") == .main)
    #expect(DisplaySelection(token: "all") == .all)
    #expect(DisplaySelection(token: "3") == .number(3))
    for bad in ["", "0", "10", "01", "-1", "ALL", " 1", "1 "] { #expect(DisplaySelection(token: bad) == nil) }
    for t in ["main", "all", "1", "9"] { #expect(DisplaySelection(token: t)?.token == t) }

    #expect(DisplaySelection.main.numbers(displayCount: 3) == [1])
    #expect(DisplaySelection.all.numbers(displayCount: 3) == [1, 2, 3])
    #expect(DisplaySelection.all.numbers(displayCount: 12) == Array(1...9))
    #expect(DisplaySelection.number(2).numbers(displayCount: 3) == [2])
    #expect(DisplaySelection.number(4).numbers(displayCount: 3) == nil)
    #expect(DisplaySelection.main.numbers(displayCount: 0) == nil)
    #expect(DisplaySelection.all.numbers(displayCount: 0) == nil)
}

@Test func displaysAreNumberedLikeScreencapture() {
    #expect(ImageMath.orderedDisplays(main: 5, active: [3, 5, 7]) == [5, 3, 7])
    #expect(ImageMath.orderedDisplays(main: 5, active: [5]) == [5])
    #expect(ImageMath.orderedDisplays(main: 9, active: [3, 4]) == [3, 4])
    #expect(ImageMath.orderedDisplays(main: 1, active: [2, 1, 2]) == [1, 2])
    #expect(ImageMath.orderedDisplays(main: 1, active: []) == [])
}

private func size(_ t: (width: Int, height: Int)) -> [Int] { [t.width, t.height] }

@Test func scalingKeepsTheLongerSideWithinTheLimitWithoutUpscaling() {
    #expect(size(ImageMath.fit(width: 2880, height: 1800, maxSide: 1280)) == [1280, 800])
    #expect(size(ImageMath.fit(width: 1800, height: 2880, maxSide: 1280)) == [800, 1280])
    #expect(size(ImageMath.fit(width: 1440, height: 900, maxSide: 640)) == [640, 400])
    #expect(size(ImageMath.fit(width: 1920, height: 1080, maxSide: 1000)) == [1000, 563])
    #expect(size(ImageMath.fit(width: 1440, height: 900, maxSide: 1440)) == [1440, 900])
    #expect(size(ImageMath.fit(width: 1440, height: 900, maxSide: 5120)) == [1440, 900])   // never upscaled
    #expect(size(ImageMath.fit(width: 5000, height: 10, maxSide: 100)) == [100, 1])        // at least one pixel
    #expect(size(ImageMath.fit(width: 0, height: 900, maxSide: 640)) == [0, 900])
    for (w, h, m) in [(3024, 1964, 1280), (2560, 1440, 333), (1366, 768, 1000), (4480, 2520, 5120)] {
        let r = ImageMath.fit(width: w, height: h, maxSide: m)
        #expect(max(r.width, r.height) <= m)
        #expect(r.width <= w && r.height <= h)
        #expect(abs(Double(r.width) / Double(r.height) - Double(w) / Double(h)) < 0.01)
    }
}

@Test func restartPolicyAfterMissingPermission() {
    #expect(!RestartPolicy.shouldExitAfterDenied(processAge: 5, sincePermissionRequest: nil))
    #expect(!RestartPolicy.shouldExitAfterDenied(processAge: 30, sincePermissionRequest: nil))
    #expect(RestartPolicy.shouldExitAfterDenied(processAge: 31, sincePermissionRequest: nil))
    // The dialog the admin asked for may still be on screen.
    #expect(!RestartPolicy.shouldExitAfterDenied(processAge: 600, sincePermissionRequest: 10))
    #expect(RestartPolicy.shouldExitAfterDenied(processAge: 600, sincePermissionRequest: 121))
}

// MARK: - JPEG

@Test func jpegEncodingHonoursQualityAndSize() throws {
    let image = try #require(TestPattern.make(width: 800, height: 500, display: 1, variant: false))
    let high = try #require(JPEGCodec.encode(image, quality: 95))
    let low = try #require(JPEGCodec.encode(image, quality: 10))
    #expect(JPEGCodec.looksLikeJPEG(high) && JPEGCodec.looksLikeJPEG(low))
    #expect(low.count < high.count)
    #expect(JPEGCodec.pixelSize(of: high).map(size) == [800, 500])
    let small = try #require(JPEGCodec.downscaled(image, maxSide: 200))
    #expect(small.width == 200 && small.height == 125)
    #expect(JPEGCodec.downscaled(image, maxSide: 2000) === image)
    #expect(!JPEGCodec.looksLikeJPEG(Data("GIF89a".utf8)))
    #expect(!JPEGCodec.looksLikeJPEG(Data([0xFF, 0xD8])))
}

@Test func testPatternChangesWithVariantAndDisplay() throws {
    func jpeg(_ display: Int, _ variant: Bool) throws -> Data {
        let image = try #require(TestPattern.make(width: 320, height: 200, display: display, variant: variant))
        return try #require(JPEGCodec.encode(image, quality: 80))
    }
    let a = try jpeg(1, false)
    #expect(try jpeg(1, false) == a)
    #expect(try jpeg(1, true) != a)
    #expect(try jpeg(2, false) != a)
    #expect(TestPattern.make(width: 0, height: 10, display: 1, variant: false) == nil)
}

// MARK: - Sockets

@Test func socketPathsMustFitSockaddr() throws {
    #expect(UnixSocket.maxPathLength == 103)
    _ = try UnixSocket.address("/tmp/" + String(repeating: "a", count: 98))
    #expect(throws: IOFailure.self) { try UnixSocket.address("/tmp/" + String(repeating: "a", count: 99)) }
    #expect(throws: IOFailure.self) { try UnixSocket.address("") }
    // The real path leaves room for long uids.
    #expect(AgentPaths().socketPath(uid: 4_294_967_294).utf8.count <= UnixSocket.maxPathLength)
}

private func socketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw IOFailure.system("socketpair") }
    return (fds[0], fds[1])
}

@Test func socketStreamReadsLinesAndExactBytes() throws {
    let (a, b) = try socketPair()
    defer { close(a); close(b) }
    let writer = SocketStream(fd: a, inactivity: 2, total: 5)
    let reader = SocketStream(fd: b, inactivity: 2, total: 5)
    let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    DispatchQueue.global().async {
        try? writer.writeLine("OK CAPTURE 1 -")
        try? writer.writeLine("IMG 1 2 3 \(payload.count)\r")
        try? writer.write(payload)
        try? writer.writeLine("tail")
    }
    #expect(try reader.readLine() == "OK CAPTURE 1 -")
    #expect(try reader.readLine() == "IMG 1 2 3 \(payload.count)")
    #expect(try reader.readBytes(payload.count) == payload)
    #expect(try reader.readLine() == "tail")
}

@Test func socketStreamTimesOutAndDetectsClosing() throws {
    let (a, b) = try socketPair()
    defer { close(b) }
    let reader = SocketStream(fd: b, inactivity: 0.2, total: 5)
    let started = Date()
    #expect((#expect(throws: IOFailure.self) { try reader.readLine() })?.kind == .timeout)
    #expect(Date().timeIntervalSince(started) < 2)
    _ = "partial".withCString { Darwin.write(a, $0, 7) }
    close(a)
    #expect((#expect(throws: IOFailure.self) { try reader.readLine() })?.kind == .closed)
    // A line without an end is not accepted forever.
    let (c, d) = try socketPair()
    defer { close(c); close(d) }
    let long = SocketStream(fd: d, inactivity: 1, total: 2)
    _ = String(repeating: "x", count: 5000).withCString { Darwin.write(c, $0, 5000) }
    #expect((#expect(throws: IOFailure.self) { try long.readLine(maxLength: 4096) })?.kind == .tooLong)
}

@Test func peerIdentityOfASocketPair() throws {
    let (a, b) = try socketPair()
    defer { close(a); close(b) }
    #expect(PeerIdentity.uid(of: a) == geteuid())
    let pid = try #require(PeerIdentity.pid(of: a))
    #expect(pid == getpid())
    let exe = try #require(PeerIdentity.executablePath(of: pid))
    #expect(PeerIdentity.sameFile(exe, Bundle.main.executablePath ?? CommandLine.arguments[0]))
    #expect(!PeerIdentity.sameFile(exe, "/bin/sh"))
    #expect(!PeerIdentity.sameFile("/nonexistent/a", "/nonexistent/a"))
}

// MARK: - Saved screenshots

private func makeTempDir() throws -> String {
    var template = Array((FileManager.default.temporaryDirectory.path + "/cmcr-shots.XXXXXX").utf8CString)
    guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) != nil else { throw IOFailure.system("mkdtemp") }
    return String(cString: template)
}

private func mode(_ path: String) -> mode_t {
    var st = stat()
    lstat(path, &st)
    return st.st_mode & 0o777
}

@Test func shotStoreWritesAtomicallyAndRemovesStaleDisplays() throws {
    let tmp = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let store = ShotStore(root: "\(tmp)/shots", uid: 4242)
    try store.prepare()
    #expect(store.directory == "\(tmp)/shots/4242")
    #expect(mode("\(tmp)/shots") == 0o700 && mode(store.directory) == 0o700)

    let p1 = try store.write(display: 1, data: Data("one".utf8))
    try store.write(display: 2, data: Data("two".utf8))
    #expect(p1 == "\(tmp)/shots/4242/screen-1.jpg")
    #expect(mode(p1) == 0o600)
    try store.write(display: 1, data: Data("one again".utf8))
    #expect(try Data(contentsOf: URL(fileURLWithPath: p1)) == Data("one again".utf8))

    // A temporary file of a killed client: removed once old, a fresh one (another client writing) is kept.
    let oldTemp = "\(store.directory)/.screen-1.abcdef", freshTemp = "\(store.directory)/.screen-2.ghijkl"
    FileManager.default.createFile(atPath: oldTemp, contents: Data())
    FileManager.default.createFile(atPath: freshTemp, contents: Data())
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: oldTemp)
    FileManager.default.createFile(atPath: "\(store.directory)/notes.txt", contents: Data())
    try store.removeOthers(keeping: [1])
    let left = Set(try FileManager.default.contentsOfDirectory(atPath: store.directory))
    #expect(left == ["screen-1.jpg", ".screen-2.ghijkl", "notes.txt"])

    // A wider existing folder is narrowed again.
    chmod(store.directory, 0o755)
    try store.prepare()
    #expect(mode(store.directory) == 0o700)
}

@Test func shotStoreRefusesSymlinkedFolders() throws {
    let tmp = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try FileManager.default.createDirectory(atPath: "\(tmp)/elsewhere", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: "\(tmp)/shots", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: "\(tmp)/shots/4242", withDestinationPath: "\(tmp)/elsewhere")
    #expect(throws: IOFailure.self) { try ShotStore(root: "\(tmp)/shots", uid: 4242).prepare() }
    try FileManager.default.createSymbolicLink(atPath: "\(tmp)/linked", withDestinationPath: "\(tmp)/elsewhere")
    #expect(throws: IOFailure.self) { try ShotStore(root: "\(tmp)/linked", uid: 1).prepare() }
    FileManager.default.createFile(atPath: "\(tmp)/file", contents: Data())
    #expect(throws: IOFailure.self) { try ShotStore(root: "\(tmp)/file", uid: 1).prepare() }
    #expect(try FileManager.default.contentsOfDirectory(atPath: "\(tmp)/elsewhere").isEmpty)
}
