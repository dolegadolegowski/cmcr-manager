import Darwin
import Foundation
import Testing
@testable import ScreenAgentKit
import CMCRTestSupport

// The real cmcr-screen-agent binary (the DEBUG build `swift test` made next to this test bundle) in serve and client
// mode. Serve runs with the DEBUG test seams only: headless, files instead of the screen, every path under a
// temporary CMCR_SETUP_ROOT_PREFIX – nothing touches AppKit, ScreenCaptureKit, TCC, launchd or /Library.

private final class BundleAnchor {}

private enum AgentBinary {
    /// The debug agent next to the test bundle (or CMCR_SCREEN_AGENT_BIN), only when it has the DEBUG test seams.
    static let url: URL? = {
        var candidates: [URL] = []
        if let p = ProcessInfo.processInfo.environment["CMCR_SCREEN_AGENT_BIN"], !p.isEmpty {
            candidates.append(URL(fileURLWithPath: p))
        }
        let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
        candidates.append(products.appendingPathComponent(AgentInfo.executableName))
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            // A release build has no test seams: it would ignore the test folder and must never be started here.
            if let r = try? run(c.path, ["--test-seams"], env: [:]), r.code == 0, r.out == "debug" { return c }
        }
        return nil
    }()

    static var missingReason: Comment {
        "brak debugowego \(AgentInfo.executableName) obok pakietu testów (swift build) – test pominięty"
    }
}

private struct RunResult {
    var code: Int32
    var out: String
    var err: String
    var lines: [String] { out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
}

/// Runs a command to completion (killed after `timeout`; never waits longer, see BoundedProcess), with only `env`
/// plus PATH/HOME/TMPDIR as environment.
private func run(_ path: String, _ args: [String], env: [String: String], timeout: TimeInterval = 30) throws -> RunResult {
    let r = try BoundedProcess.run(path, args, environment: baseEnvironment().merging(env) { _, new in new },
                                   timeout: timeout)
    var text = r.outText
    if text.hasSuffix("\n") { text.removeLast() }
    var err = r.errText
    if r.timedOut { err += "\n[przekroczony limit \(Int(timeout)) s – proces zabity]" }
    return RunResult(code: r.timedOut ? -1 : r.status, out: text, err: err)
}

private func baseEnvironment() -> [String: String] {
    let env = ProcessInfo.processInfo.environment
    var base: [String: String] = [:]
    for key in ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME"] { base[key] = env[key] }
    return base
}

/// A temporary iMac: the prefix with the agent "installed", a test folder, and the serve processes started in it.
private final class FakeIMac {
    let root: String
    let paths: AgentPaths
    let testDir: String
    let binary: URL
    private(set) var servers: [Process] = []

    init(binary: URL) throws {
        // /tmp, not $TMPDIR: the socket path must fit into sockaddr_un (103 bytes).
        var template = Array("/tmp/cmcr-sa.XXXXXX".utf8CString)
        guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) != nil else {
            throw IOFailure.system("mkdtemp")
        }
        root = String(cString: template)
        self.binary = binary
        paths = AgentPaths(prefix: "\(root)/r")
        testDir = "\(root)/t"
        let fm = FileManager.default
        try fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: paths.runDir, withIntermediateDirectories: true)
        chmod(paths.runDir, 0o755)
        try fm.createDirectory(atPath: (paths.executablePath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try fm.copyItem(atPath: binary.path, toPath: paths.executablePath)
    }

    var env: [String: String] { ["CMCR_SETUP_ROOT_PREFIX": paths.prefix, "CMCR_SCREEN_AGENT_TEST_DIR": testDir] }

    /// Creates `run/<uid>` (0700) the way root does before it starts that user's agent.
    func prepareSocketDir(uid: uid_t) throws {
        let dir = paths.socketDir(uid: uid)
        var st = stat()
        if lstat(dir, &st) != 0 { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false) }
        chmod(dir, 0o700)
    }

    /// Starts `serve` from `executable` (default: the installed copy) and waits for its socket; `run/<uid>` is
    /// created first unless `prepare` is false.
    @discardableResult
    func serve(uid: uid_t?, executable: String? = nil, testDir dir: String? = nil, prepare: Bool = true) throws -> Process {
        if prepare { try prepareSocketDir(uid: uid ?? getuid()) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable ?? paths.executablePath)
        p.arguments = ["serve"]
        var e = baseEnvironment().merging(env) { _, new in new }
        if let dir { e["CMCR_SCREEN_AGENT_TEST_DIR"] = dir }
        if let uid { e["CMCR_SCREEN_AGENT_TEST_UID"] = String(uid) }
        p.environment = e
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        // A file, not a pipe nobody reads: an agent that logs a lot would block on a full pipe.
        let errPath = "\(root)/serve-\(servers.count).err"
        FileManager.default.createFile(atPath: errPath, contents: nil)
        let errHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: errPath))
        p.standardError = errHandle
        defer { try? errHandle.close() }
        try p.run()
        servers.append(p)
        // Ready once it accepts a connection (a stale socket file may be there before the agent replaces it).
        let socket = paths.socketPath(uid: uid ?? getuid())
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !p.isRunning {
                let message = (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
                throw IOFailure(.closed, "serve zakończył się kodem \(p.terminationStatus): \(message)")
            }
            if let fd = try? UnixSocket.connect(to: socket, timeout: 1) {
                close(fd)
                return p
            }
            usleep(20_000)
        }
        throw IOFailure(.timeout, "brak gniazda \(socket)")
    }

    func client(_ args: [String], strict: Bool = false) throws -> RunResult {
        var e = env
        if strict { e["CMCR_SCREEN_AGENT_TEST_DIR"] = nil }
        return try run(binary.path, ["client"] + args, env: e)
    }

    func set(_ name: String, _ value: String? = "") {
        let path = "\(testDir)/\(name)"
        if let value { FileManager.default.createFile(atPath: path, contents: Data(value.utf8)) } else { unlink(path) }
    }

    /// Ends every serve process (also a stopped one) and removes the folder; never waits for ever.
    func cleanUp() {
        for p in servers { p.stopAndWait() }
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// A uid nobody on this Mac has (the harness runs everything as the developer).
private let studentUID: uid_t = getuid() == 4242 ? 4243 : 4242

/// One at a time: every test starts several processes of its own, and on a 3–4 core runner a crowd of them makes
/// every timing in them (and in the rest of the suite) uncertain. Each call has a hard limit anyway (BoundedProcess).
@Suite(.serialized, .timeLimit(.minutes(3)))
struct AgentProcessTests {
    @Test(.enabled(if: AgentBinary.url != nil, AgentBinary.missingReason), .timeLimit(.minutes(3)))
    func agentServesPingCaptureNoticeAndFront() throws {
        let mac = try FakeIMac(binary: try #require(AgentBinary.url))
        defer { mac.cleanUp() }
        try mac.serve(uid: studentUID)
        let uid = String(studentUID)
        // The socket was created 0600 by the agent.
        var st = stat()
        #expect(lstat(mac.paths.socketPath(uid: studentUID), &st) == 0 && st.st_mode & 0o777 == 0o600)

        let ping = try mac.client([uid, "ping"])
        #expect(ping.code == 0)
        #expect(ping.out == "AGENT \(AgentInfo.version) perm=granted locked=0 console=1 asleep=0 user=\(NSUserName())")

        // Capture: saved under shots/<uid>, scaled to the longer side, never upscaled.
        var r = try mac.client([uid, "capture", "640", "70", "main"])
        #expect(r.code == 0, "\(r.out) \(r.err)")
        let shot1 = mac.paths.shotsDir(uid: studentUID) + "/screen-1.jpg"
        let first = try Data(contentsOf: URL(fileURLWithPath: shot1))
        #expect(r.lines == ["FRONT Finder", "SHOT 1 640 400 \(first.count) \(shot1)"])
        #expect(JPEGCodec.looksLikeJPEG(first))
        #expect(JPEGCodec.pixelSize(of: first).map { [$0.width, $0.height] } == [640, 400])
        #expect(lstat(shot1, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(lstat(mac.paths.shotsDir, &st) == 0 && st.st_mode & 0o777 == 0o700)
        #expect(lstat(mac.paths.shotsDir(uid: studentUID), &st) == 0 && st.st_mode & 0o777 == 0o700)

        // The same screen again is the same file; a changed screen replaces it.
        r = try mac.client([uid, "capture", "640", "70", "main"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: shot1)) == first)
        mac.set("variant")
        r = try mac.client([uid, "capture", "640", "70", "main"])
        #expect(r.code == 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: shot1)) != first)

        // Two displays, then only the main one: the second display's file goes away.
        mac.set("displays", "2")
        mac.set("size", "1920x1080")
        mac.set("front", "Safari\nSHOT 9 1 1 1 /etc/passwd")
        r = try mac.client([uid, "capture", "5000", "90", "all"])
        #expect(r.code == 0, "\(r.out)")
        #expect(r.lines.count == 3)
        #expect(r.lines.first == "FRONT Safari SHOT 9 1 1 1 /etc/passwd")
        #expect(r.lines.dropFirst().map { $0.split(separator: " ").prefix(4).joined(separator: " ") }
            == ["SHOT 1 1920 1080", "SHOT 2 1920 1080"])
        let shot2 = mac.paths.shotsDir(uid: studentUID) + "/screen-2.jpg"
        #expect(FileManager.default.fileExists(atPath: shot2))
        // A capture of the main display leaves the second display's image alone (another preview of this account may
        // be sending it right now); only a capture of all displays removes the images of displays that are gone.
        r = try mac.client([uid, "capture", "1000", "50", "main"])
        #expect(r.code == 0)
        #expect(r.lines.last?.hasPrefix("SHOT 1 1000 563 ") == true)
        #expect(FileManager.default.fileExists(atPath: shot2))
        mac.set("displays", "1")
        r = try mac.client([uid, "capture", "1000", "50", "all"])
        #expect(r.code == 0)
        #expect(!FileManager.default.fileExists(atPath: shot2))
        #expect(try FileManager.default.contentsOfDirectory(atPath: mac.paths.shotsDir(uid: studentUID)) == ["screen-1.jpg"])
        mac.set("displays", "2")

        // A display that is not there.
        r = try mac.client([uid, "capture", "640", "70", "3"])
        #expect(r.code == AgentInfo.ClientCode.noImage)
        #expect(r.out.hasPrefix("ERR nodisplay "))

        // Notice, front app, permission request.
        let title = Base64Field.encode("Podgląd ekranu"), text = Base64Field.encode("Administrator rozpoczął podgląd.")
        r = try mac.client([uid, "notice", title, text])
        #expect(r.code == 0 && r.out == "NOTICE shown")
        let log = try String(contentsOfFile: mac.testDir + "/requests.log", encoding: .utf8)
        #expect(log.contains("NOTICE-TEXT Podgląd ekranu | Administrator rozpoczął podgląd."))
        #expect(log.contains("CMCRA1 CAPTURE 640 70 main"))
        mac.set("notice", "hidden")
        #expect(try mac.client([uid, "notice", title, text]).out == "NOTICE hidden")
        mac.set("front", "Keynote")
        r = try mac.client([uid, "front"])
        #expect(r.code == 0 && r.out == "FRONT Keynote")
        r = try mac.client([uid, "request-permission"])
        #expect(r.code == 0 && r.out == "PERMISSION granted")
        #expect(FileManager.default.fileExists(atPath: mac.testDir + "/permission-requested"))

        // An app with a huge name: cut to 200 characters by the agent, still a valid answer.
        mac.set("front", String(repeating: "Ż", count: 7000))
        r = try mac.client([uid, "capture", "320", "60", "main"])
        #expect(r.code == 0, "\(r.out)")
        #expect(r.lines.first == "FRONT " + String(repeating: "Ż", count: AgentInfo.maxNameLength))
        r = try mac.client([uid, "front"])
        #expect(r.code == 0 && r.out.count == "FRONT ".count + AgentInfo.maxNameLength)
    }

    @Test(.enabled(if: AgentBinary.url != nil, AgentBinary.missingReason), .timeLimit(.minutes(3)))
    func agentReportsPermissionLockAndFailures() throws {
        let mac = try FakeIMac(binary: try #require(AgentBinary.url))
        defer { mac.cleanUp() }
        let server = try mac.serve(uid: studentUID)
        let uid = String(studentUID)

        mac.set("perm", "denied")
        var r = try mac.client([uid, "capture", "640", "70", "main"])
        #expect(r.code == AgentInfo.ClientCode.noPermission)
        #expect(r.out.hasPrefix("ERR noperm "))
        #expect(try mac.client([uid, "ping"]).out.contains(" perm=denied "))
        #expect(try mac.client([uid, "request-permission"]).out == "PERMISSION denied")
        // A young process stays (no restart loop while the permission is really missing).
        #expect(server.isRunning)
        mac.set("perm", nil)

        mac.set("locked")
        r = try mac.client([uid, "capture", "640", "70", "main"])
        #expect(r.code == AgentInfo.ClientCode.locked && r.out.hasPrefix("ERR locked "))
        #expect(try mac.client([uid, "notice", "YQ==", "Yg=="]).out == "NOTICE locked")
        #expect(try mac.client([uid, "ping"]).out.contains(" locked=1 "))
        mac.set("locked", nil)

        mac.set("asleep")
        #expect(try mac.client([uid, "capture", "640", "70", "main"]).code == AgentInfo.ClientCode.noImage)
        mac.set("asleep", nil)
        mac.set("notconsole")
        r = try mac.client([uid, "capture", "640", "70", "main"])
        #expect(r.code == AgentInfo.ClientCode.noImage && r.out.hasPrefix("ERR notconsole "))
        mac.set("notconsole", nil)

        mac.set("capture-fail", "dysk pełny")
        r = try mac.client([uid, "capture", "640", "70", "main"])
        #expect(r.code == AgentInfo.ClientCode.captureFailed)
        #expect(r.out == "ERR failed dysk pełny")
        mac.set("capture-fail", nil)
        #expect(try mac.client([uid, "capture", "640", "70", "main"]).code == 0)

        // Usage errors never reach the agent.
        for args in [[uid], [uid, "capture", "640", "70"], [uid, "capture", "640", "5", "main"], [uid, "capture", "640", "70", "x"],
                     [uid, "notice", "%%%", "YQ=="], [uid, "shutdown"], ["abc", "ping"], ["-1", "ping"],
                     ["4294967295", "ping"], ["12345678901", "ping"], [uid, "--pid"], [uid, "--pid", "x", "ping"],
                     [uid, "--pid", "0", "ping"], [uid, "ping", "--pid"], [uid, "--pid", "1", "ping", "--pid", "1"]] {
            r = try mac.client(args)
            #expect(r.code == AgentInfo.ClientCode.usage, "\(args)")
            #expect(r.out.hasPrefix("ERR usage "), "\(args)")
        }

        // An old process without the permission exits after answering (launchd starts a fresh one)…
        mac.set("old")
        mac.set("perm", "denied")
        // …but not while the permission dialog it showed (request-permission above) may still be up.
        r = try mac.client([uid, "capture", "640", "70", "main"])
        #expect(r.code == AgentInfo.ClientCode.noPermission, "\(r.code) \(r.out) \(r.err)")
        usleep(300_000)
        #expect(server.isRunning)
        let otherUID = studentUID + 1, other = String(otherUID)
        let fresh = try mac.serve(uid: otherUID)
        r = try mac.client([other, "capture", "640", "70", "main"])
        #expect(r.code == AgentInfo.ClientCode.noPermission,
                "\(r.code) \(r.out) \(r.err) – serve: \(fresh.isRunning ? "działa" : "zakończony kodem \(fresh.terminationStatus)")")
        let deadline = Date().addingTimeInterval(5)
        while fresh.isRunning && Date() < deadline { usleep(20_000) }
        #expect(!fresh.isRunning)
        #expect(!FileManager.default.fileExists(atPath: mac.paths.socketPath(uid: otherUID)))
        r = try mac.client([other, "ping"])
        #expect(r.code == AgentInfo.ClientCode.unreachable && r.out.hasPrefix("ERR unreachable "))
        // A PING never ends the agent (readiness, status and install ping it; they restart it themselves when needed).
        let pinged = try mac.serve(uid: otherUID)
        #expect(try mac.client([other, "ping"]).out.contains(" perm=denied "))
        usleep(500_000)
        #expect(pinged.isRunning)
        #expect(try mac.client([other, "ping"]).code == 0)
        // A denied capture right after a notice: the agent stays until the notice panel has gone, then exits.
        // The exit is deferred by max(2, notice-seconds) + 0.5 s, counted from the notice. The "still running" checks
        // are made only while that is surely still ahead – on a slow CI runner the clients themselves can take longer
        // than the short deferral, and then the agent has rightly gone already.
        mac.set("notice-seconds", "3")
        let noticeAt = Date()
        #expect(try mac.client([other, "notice", "YQ==", "Yg=="]).out == "NOTICE shown")
        #expect(try mac.client([other, "capture", "640", "70", "main"]).code == AgentInfo.ClientCode.noPermission)
        if Date().timeIntervalSince(noticeAt) < 1.5 {
            #expect(pinged.isRunning)
            if let ping = try? mac.client([other, "ping"]), Date().timeIntervalSince(noticeAt) < 3.0 {
                #expect(ping.code == 0)
            }
        }
        let deadline3 = Date().addingTimeInterval(15)
        while pinged.isRunning && Date() < deadline3 { usleep(20_000) }
        #expect(!pinged.isRunning)
        #expect(!FileManager.default.fileExists(atPath: mac.paths.socketPath(uid: otherUID)))
    }

    @Test(.enabled(if: AgentBinary.url != nil, AgentBinary.missingReason), .timeLimit(.minutes(3)))
    func clientRefusesAnythingButTheInstalledAgent() throws {
        let mac = try FakeIMac(binary: try #require(AgentBinary.url))
        defer { mac.cleanUp() }

        // Nobody listening.
        var r = try mac.client([String(studentUID), "ping"])
        #expect(r.code == AgentInfo.ClientCode.unreachable)

        // The same program, but not the installed copy, serving a student's socket.
        let impostorDir = mac.root + "/impostor"
        try FileManager.default.createDirectory(atPath: impostorDir, withIntermediateDirectories: true)
        let impostor = impostorDir + "/cmcr-screen-agent"
        try FileManager.default.copyItem(atPath: mac.binary.path, toPath: impostor)
        try mac.serve(uid: studentUID, executable: impostor)
        r = try mac.client([String(studentUID), "ping"])
        #expect(r.code == AgentInfo.ClientCode.untrusted)
        #expect(r.out.hasPrefix("ERR untrusted ") && r.out.contains(impostor))
        r = try mac.client([String(studentUID), "capture", "640", "70", "main"])
        #expect(r.code == AgentInfo.ClientCode.untrusted)
        #expect(!FileManager.default.fileExists(atPath: mac.paths.shotsDir(uid: studentUID)))

        // Something that is not a socket at the socket path: not trusted; the agent replaces it (only this user and
        // root can put anything into run/<uid>).
        let otherUID = studentUID + 1, other = String(otherUID)
        try mac.prepareSocketDir(uid: otherUID)
        FileManager.default.createFile(atPath: mac.paths.socketPath(uid: otherUID), contents: Data())
        #expect(try mac.client([other, "ping"]).code == AgentInfo.ClientCode.untrusted)
        try mac.serve(uid: otherUID)
        #expect(try mac.client([other, "ping"]).code == 0)

        // Without its folder the agent does not start (root creates it before every start); the client finds nothing.
        let thirdUID = studentUID + 2, third = String(thirdUID)
        #expect(throws: (any Error).self) { try mac.serve(uid: thirdUID, prepare: false) }
        r = try mac.client([third, "ping"])
        #expect(r.code == AgentInfo.ClientCode.unreachable && r.out.contains("brak katalogu"), "\(r.out)")
        // A folder anybody else could read or enter, or a link instead of the folder: refused on both sides.
        try FileManager.default.createDirectory(atPath: mac.paths.socketDir(uid: thirdUID), withIntermediateDirectories: false)
        chmod(mac.paths.socketDir(uid: thirdUID), 0o755)
        #expect(throws: (any Error).self) { try mac.serve(uid: thirdUID, prepare: false) }
        #expect(try mac.client([third, "ping"]).code == AgentInfo.ClientCode.untrusted)
        try FileManager.default.removeItem(atPath: mac.paths.socketDir(uid: thirdUID))
        let elsewhere = mac.root + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: false)
        chmod(elsewhere, 0o700)
        try FileManager.default.createSymbolicLink(atPath: mac.paths.socketDir(uid: thirdUID), withDestinationPath: elsewhere)
        r = try mac.client([third, "ping"])
        #expect(r.code == AgentInfo.ClientCode.untrusted && r.out.contains("dowiązanie"), "\(r.out)")
        #expect(throws: (any Error).self) { try mac.serve(uid: thirdUID, prepare: false) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere).isEmpty)
        // The old world-writable run folder (1733) is not trusted.
        chmod(mac.paths.runDir, 0o1733)
        #expect(try mac.client([other, "ping"]).code == AgentInfo.ClientCode.untrusted)
        chmod(mac.paths.runDir, 0o755)
    }

    @Test(.enabled(if: AgentBinary.url != nil, AgentBinary.missingReason), .timeLimit(.minutes(3)))
    func clientChecksLaunchdPidAndRefusesAStoppedAgent() throws {
        let mac = try FakeIMac(binary: try #require(AgentBinary.url))
        defer { mac.cleanUp() }
        let server = try mac.serve(uid: studentUID)
        let uid = String(studentUID), pid = String(server.processIdentifier)

        // The pid launchd reports, before the command or after its arguments.
        var r = try mac.client([uid, "--pid", pid, "ping"])
        #expect(r.code == 0, "\(r.out)")
        r = try mac.client([uid, "capture", "320", "60", "main", "--pid", pid])
        #expect(r.code == 0, "\(r.out)")
        // Another pid than the one that made the socket: whoever answers is not launchd's agent.
        r = try mac.client([uid, "--pid", String(server.processIdentifier + 1), "ping"])
        #expect(r.code == AgentInfo.ClientCode.untrusted && r.out.hasPrefix("ERR untrusted "), "\(r.out)")
        r = try mac.client([uid, "capture", "320", "60", "main", "--pid", "1"])
        #expect(r.code == AgentInfo.ClientCode.untrusted)

        // A stopped agent keeps its pid, executable and arguments, but it is not the one answering: refused (even
        // though the kernel still completes the connection).
        kill(server.processIdentifier, SIGSTOP)
        r = try mac.client([uid, "--pid", pid, "ping"])
        #expect(r.code == AgentInfo.ClientCode.untrusted && r.out.contains("zatrzymany"), "\(r.out)")
        r = try mac.client([uid, "ping"])
        #expect(r.code == AgentInfo.ClientCode.untrusted)
        kill(server.processIdentifier, SIGCONT)
        usleep(100_000)
        #expect(try mac.client([uid, "--pid", pid, "ping"]).code == 0)

        // A 10-digit uid (Active Directory) is a valid uid: no agent there, so unreachable, not a usage error.
        r = try mac.client(["4294967294", "ping"])
        #expect(r.code == AgentInfo.ClientCode.unreachable, "\(r.out)")
    }

    @Test(.enabled(if: AgentBinary.url != nil, AgentBinary.missingReason), .timeLimit(.minutes(3)))
    func strictClientChecksTheSocketOwner() throws {
        let mac = try FakeIMac(binary: try #require(AgentBinary.url))
        defer { mac.cleanUp() }
        // Outside the test mode the client trusts only user <uid>: the developer's agent on the socket of "4242" is not.
        try mac.serve(uid: studentUID)
        var r = try mac.client([String(studentUID), "ping"], strict: true)
        // (As the developer it already stops at "run as root or as that user"; as root it would be "untrusted".)
        #expect(r.code == (geteuid() == 0 ? AgentInfo.ClientCode.untrusted : AgentInfo.ClientCode.usage), "\(r.out)")
        // The developer's own session passes every check of the real client (owner, peer uid, executable).
        try mac.serve(uid: nil)
        r = try mac.client([String(getuid()), "ping"], strict: true)
        #expect(r.code == 0, "\(r.out)")
        #expect(r.out.hasPrefix("AGENT \(AgentInfo.version) "))
        r = try mac.client([String(getuid()), "capture", "320", "60", "main"], strict: true)
        #expect(r.code == 0, "\(r.out)")
        #expect(r.lines.last?.hasPrefix("SHOT 1 320 200 ") == true)
        // A stale socket of this user (agent gone) is replaced by a new agent.
        for p in mac.servers { p.stopAndWait() }
        #expect(!FileManager.default.fileExists(atPath: mac.paths.socketPath(uid: getuid())))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try UnixSocket.address(mac.paths.socketPath(uid: getuid()))
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(fd)
        #expect(try mac.client([String(getuid()), "ping"], strict: true).code == AgentInfo.ClientCode.unreachable)
        try mac.serve(uid: nil)
        #expect(try mac.client([String(getuid()), "ping"], strict: true).code == 0)
    }
}
