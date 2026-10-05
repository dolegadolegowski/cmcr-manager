import Foundation
import Testing
@testable import CMCRCore

private func value(of option: String, in args: [String]) -> [String] {
    var found: [String] = []
    for (i, a) in args.enumerated() where a == "-o" && i + 1 < args.count && args[i + 1].hasPrefix(option + "=") {
        found.append(String(args[i + 1].dropFirst(option.count + 1)))
    }
    return found
}

private func syntaxCheck(_ script: String) async -> CommandResult {
    await ProcessRunner.run("/bin/bash", ["-n"], stdin: Data(script.utf8))
}

private func result(_ code: Int32, stderr: String, stdout: String = "") -> CommandResult {
    CommandResult(exitCode: code, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
}

struct SSHOptionTests {
    let settings = SSHSettings(identityFile: "~/klucz", connectTimeout: 5,
                               extraOptions: ["ConnectTimeout=20", "StrictHostKeyChecking=no"], askpassPath: "/tmp/askpass")

    @Test func userOptionsComeFirstSoTheyWin() {
        let o = SSH.options(settings, password: nil)
        // OpenSSH takes the first value of an option.
        #expect(value(of: "ConnectTimeout", in: o).first == "20")
        #expect(value(of: "StrictHostKeyChecking", in: o).first == "no")
        #expect(value(of: "ServerAliveInterval", in: o) == ["5"])
        #expect(value(of: "ServerAliveCountMax", in: o) == ["3"])
        #expect(o.contains(expandTilde("~/klucz")))
    }

    @Test func connectionSharingUsesAPrivateShortSocketPath() throws {
        let o = SSH.options(settings, password: nil)
        #expect(value(of: "ControlMaster", in: o) == ["auto"])
        #expect(value(of: "ControlPersist", in: o) == ["120"])
        let path = try #require(value(of: "ControlPath", in: o).first)
        #expect(path.hasSuffix("/%C"))
        // 40 characters of %C plus ssh's temporary suffix must fit into a 104-byte socket path.
        #expect(path.utf8.count - 2 + 40 + 17 < 104)
        let dir = String(path.dropLast(3))
        var st = stat()
        #expect(lstat(dir, &st) == 0)
        #expect(st.st_mode & S_IFMT == S_IFDIR)
        #expect(st.st_mode & 0o777 == 0o700)
        #expect(st.st_uid == getuid())
    }

    @Test func connectionSharingCanBeTurnedOff() {
        var s = settings
        s.reuseConnections = false
        let o = SSH.options(s, password: nil)
        #expect(value(of: "ControlPath", in: o) == ["none"])
        #expect(value(of: "ControlMaster", in: o) == ["no"])
        #expect(value(of: "ControlPath", in: SSH.options(settings, password: nil, mux: false)) == ["none"])
    }

    @Test func passwordSwitchesBatchMode() {
        #expect(value(of: "BatchMode", in: SSH.options(settings, password: "x")) == ["no"])
        #expect(value(of: "BatchMode", in: SSH.options(settings, password: nil)) == ["yes"])
    }

    @Test func interactiveSessionsShareConnectionsToo() {
        let host = Machine(name: "imac04", address: "imac04.local", user: "imac04")
        let a = SSH.interactiveArguments(for: host, settings: settings)
        #expect(a.last == "imac04@imac04.local")
        #expect(value(of: "ConnectTimeout", in: a).first == "20")
        #expect(value(of: "ControlMaster", in: a) == ["auto"])
    }

    @Test func settingsCarryConnectionSharing() {
        var app = AppSettings()
        #expect(app.reuseConnections)
        app.reuseConnections = false
        #expect(!SSHSettings(app, askpassPath: "/x").reuseConnections)
    }

    @Test func knownHostsOverrideIsFound() {
        var s = settings
        #expect(SSH.knownHostsFiles(s).isEmpty)
        s.extraOptions = ["ProxyJump=brama", "UserKnownHostsFile=~/lab_known_hosts /tmp/drugi"]
        #expect(SSH.knownHostsFiles(s) == [expandTilde("~/lab_known_hosts"), "/tmp/drugi"])
        s.extraOptions = ["userknownhostsfile /tmp/trzeci"]
        #expect(SSH.knownHostsFiles(s) == ["/tmp/trzeci"])
    }
}

struct SSHFailureTests {
    @Test func onlyPreSessionFailuresAreRetried() {
        typealias F = SSH.ConnectFailure
        let cases: [(CommandResult, F?)] = [
            (result(255, stderr: "kex_exchange_identification: read: Connection reset by peer\n"), .transient),
            (result(255, stderr: "Connection closed by 10.0.0.4 port 22\n"), .transient),
            (result(255, stderr: "Connection reset by 10.0.0.4 port 22\n"), .transient),
            (result(255, stderr: "Connection timed out during banner exchange\n"), .transient),
            (result(255, stderr: "mux_client_request_session: session request failed: Session open refused by peer\n"), .sharedConnection),
            (result(255, stderr: "mux_client_hello_exchange: read packet failed\n"), .brokenSharedConnection),
            (result(255, stderr: "ssh: Could not resolve hostname imac99.local: nodename nor servname provided\n"), .unreachable),
            (result(255, stderr: "ssh: connect to host imac04.local port 22: Operation timed out\n"), .unreachable),
            // After the command started: never repeat it.
            (result(255, stderr: "Connection to imac04.local closed by remote host.\n"), nil),
            (result(255, stderr: "client_loop: send disconnect: Broken pipe\n"), nil),
            (result(255, stderr: "kex_exchange_identification: Connection closed\n", stdout: "częściowe"), nil),
            (result(1, stderr: "ssh: connect to host imac04.local port 22: Operation timed out\n"), nil),
            (result(255, stderr: "imac04@imac04.local: Permission denied (publickey,password).\n"), nil),
            (result(255, stderr: "Host key verification failed.\n"), nil),
        ]
        for (r, expected) in cases {
            #expect(SSH.connectFailure(r) == expected, "\(r.stderrText)")
        }
        // scp reports ssh's failure with exit code 1.
        let scp = result(1, stderr: "ssh: connect to host imac04.local port 22: Operation timed out\n")
        #expect(SSH.connectFailure(scp, sshExitOnly: false) == .unreachable)
    }

    @Test func sharedConnectionNoiseIsFilteredLineByLine() {
        let noisy = Data("mux_client_request_session: session request failed: Session open refused by peer\nprawdziwy błąd\nControlSocket /tmp/x already exists, disabling multiplexing\n".utf8)
        #expect(String(decoding: SSHNoise.filter(noisy), as: UTF8.self) == "prawdziwy błąd\n")
        let binary = Data([0xFF, 0xD8, 0x00, 0x0A, 0x80])
        #expect(SSHNoise.filter(binary) == binary)
    }

    @Test func startMarkerIsDetectedAndRemoved() {
        let data = Data("\(RemoteScript.startMarker)\nbłąd polecenia\n".utf8)
        #expect(SSHNoise.containsStartMarker(data))
        #expect(String(decoding: SSHNoise.filter(data), as: UTF8.self) == "błąd polecenia\n")
        #expect(!SSHNoise.containsStartMarker(Data("Connection reset by 10.0.0.4 port 22\n".utf8)))
        #expect(RemoteScript("echo x").render().hasPrefix("echo \(RemoteScript.startMarker) >&2\n"))
    }

    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private static let machine = Machine(name: "imac99", address: "imac99.invalid", user: "imac99")
    private static let settings = SSHSettings(askpassPath: "/tmp/askpass", reuseConnections: false)

    @Test func aStartedCommandIsNeverRetried() async {
        // Without connection sharing ssh reports a connection lost mid-session like a refused one.
        let attempts = Attempts()
        let started = OutputFlag()
        let reset = "\(RemoteScript.startMarker)\nConnection reset by 10.0.0.4 port 22\n"
        let r = await SSH.runWithRetry(on: Self.machine, settings: Self.settings, retry: .job, handle: nil,
                                       stdoutFile: nil, started: started, onOutput: nil) { _, output in
            _ = attempts.next()
            output(.stderr, Data(reset.utf8))
            return result(255, stderr: reset)
        }
        #expect(attempts.count == 1)
        #expect(started.isSet)
        #expect(!r.stderrText.contains(RemoteScript.startMarker))
        #expect(r.stderrText.contains("Connection reset"))
    }

    @Test func aFailureBeforeTheStartIsRetried() async {
        let attempts = Attempts()
        let started = OutputFlag()
        let r = await SSH.runWithRetry(on: Self.machine, settings: Self.settings, retry: .transient, handle: nil,
                                       stdoutFile: nil, started: started, onOutput: nil) { _, output in
            if attempts.next() == 1 { return result(255, stderr: "Connection reset by 10.0.0.4 port 22\n") }
            output(.stderr, Data("\(RemoteScript.startMarker)\n".utf8))
            return result(0, stderr: "\(RemoteScript.startMarker)\n", stdout: "ok\n")
        }
        #expect(attempts.count == 2)
        #expect(started.isSet)
        #expect(r.succeeded)
        #expect(r.stderr.isEmpty)
    }

    @Test func newFailureKindsHaveClearMessages() {
        #expect(SSH.diagnose(result(255, stderr: "kex_exchange_identification: read: Connection reset by peer")).1.contains("chwilowo"))
        #expect(SSH.diagnose(result(255, stderr: "Connection to x closed by remote host.")).1.contains("przerwane"))
        #expect(SSH.diagnose(result(255, stderr: "Timeout, server x not responding.")).0 == .offline)
    }
}

struct RemoteJobTests {
    @Test func wrapperIgnoresHangupAndPipeSignals() {
        let s = RemoteScript("echo x").render()
        #expect(s.contains("trap '' HUP PIPE"))
        #expect(s.contains("trap 'exit 143' TERM INT"))
        #expect(!s.contains("cmcr_jobs_dir"))
        // Pipelines in the body keep their usual SIGPIPE behaviour (no "Broken pipe" noise).
        #expect(s.contains(#"( trap - PIPE; source "$CMCR_TMP/body.sh" )"#))
        #expect(RemoteScript("id", asRoot: true).render().contains("( trap - PIPE; printf"))
    }

    @Test func jobIDRegistersTheJobAndRelaysOutput() {
        let s = RemoteScript("echo x", jobID: "abc-123").render()
        #expect(s.contains("CMCR_JOB_ID='abc-123'"))
        #expect(s.contains("mkfifo"))
        #expect(s.contains(#"echo "$$ $CMCR_TMP" > "$CMCR_JOB_FILE""#))
    }

    @Test func unsafeJobIDsAreIgnored() {
        #expect(!RemoteJobs.isValidID("a'b"))
        #expect(!RemoteJobs.isValidID("../x"))
        #expect(!RemoteJobs.isValidID(""))
        #expect(RemoteJobs.isValidID(RemoteJobs.newID()))
        #expect(!RemoteScript("echo x", jobID: "a'b; rm -rf /").render().contains("CMCR_JOB_ID="))
    }

    @Test func rootShellReturnsItsFilesSoCleanupNeedsNoSecondSudo() {
        let s = RemoteScript("id", asRoot: true, jobID: "j1").render()
        // What root created is deleted by root (not walked twice), the rest is handed back.
        #expect(s.contains(#"-mindepth 1 -maxdepth 1 ! -user $2 -exec rm -rf {} +"#))
        #expect(s.contains(#"chown -hR $2"#))
        #expect(s.contains(#"cmcr "$CMCR_TMP" "$UID" "$CMCR_JOB_FILE""#))
    }

    @Test func renderedScriptsAreValidBash() async {
        let scripts = [
            RemoteScript("echo x").render(),
            RemoteScript("echo x", jobID: RemoteJobs.newID()).render(),
            RemoteScript("id -u", asRoot: true).render(),
            RemoteScript("id -u", asRoot: true, jobID: RemoteJobs.newID()).render(),
            RemoteJobs.cancelScript(jobID: RemoteJobs.newID()).render(),
        ]
        for s in scripts {
            let r = await syntaxCheck(s)
            #expect(r.exitCode == 0, "\(r.stderrText)")
        }
    }

    @Test func cancelOutcomeIsParsed() {
        #expect(RemoteCancelOutcome(result(0, stderr: "", stdout: "CMCR:CANCEL:OK\n")) == .stopped)
        #expect(RemoteCancelOutcome(result(0, stderr: "", stdout: "CMCR:CANCEL:NOTRUNNING\n")) == .notRunning)
        #expect(RemoteCancelOutcome(result(1, stderr: "", stdout: "CMCR:CANCEL:ALIVE\n")) == .stillRunning)
        if case .failed = RemoteCancelOutcome(result(255, stderr: "ssh: connect to host x port 22: Operation timed out")) {} else {
            Issue.record("brak połączenia powinien być błędem")
        }
    }
}

struct HostGateTests {
    private final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var peak = 0
        func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
        var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
    }

    @Test func limitsConcurrentSessionsPerHost() async {
        let gate = HostGate(limit: 2)
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    guard await gate.acquire("a@imac01:22") else { return }
                    peak.enter()
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    peak.leave()
                    gate.release("a@imac01:22")
                }
            }
        }
        #expect(peak.maximum == 2)
        #expect(gate.sessions("a@imac01:22") == 0)
    }

    @Test func otherHostsAreNotBlocked() async {
        let gate = HostGate(limit: 1)
        #expect(await gate.acquire("a@imac01:22"))
        #expect(await gate.acquire("a@imac02:22", timeout: 0.1))
        gate.release("a@imac01:22")
        gate.release("a@imac02:22")
    }

    @Test func waitingEndsOnTimeoutOrCancel() async {
        let gate = HostGate(limit: 1)
        #expect(await gate.acquire("k"))
        let start = Date()
        #expect(!(await gate.acquire("k", timeout: 0.2)))
        #expect(Date().timeIntervalSince(start) < 2)
        let handle = ProcessHandle()
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            handle.cancel()
        }
        #expect(!(await gate.acquire("k", handle: handle)))
        gate.release("k")
        #expect(gate.sessions("k") == 0)
        #expect(await gate.acquire("k", timeout: 0.1))
        gate.release("k")
    }
}

/// A TCP port that accepts connections but never sends an SSH banner: ssh hangs before the session starts.
private final class SilentListener {
    let fd: Int32
    let port: Int

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return nil }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.fd = fd
        port = Int(UInt16(bigEndian: addr.sin_port))
    }

    deinit { close(fd) }
}

private final class OutputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

struct SessionStartTests {
    private let settings = SSHSettings(connectTimeout: 10, extraOptions: ["UserKnownHostsFile=/dev/null"],
                                       askpassPath: "/tmp/askpass", reuseConnections: false)

    @Test func cancelBeforeTheCommandStartedNeedsNoRemoteStop() async throws {
        let listener = try #require(SilentListener())
        let host = Machine(name: "cisza", address: "127.0.0.1", user: "nikt", port: listener.port)
        let handle = ProcessHandle()
        let log = OutputLog()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            handle.cancel()
        }
        let start = Date()
        let r = await SSH.run(RemoteScript("echo x"), on: host, password: nil, settings: settings, handle: handle,
                              onOutput: { _, d in log.append(d) })
        await handle.cancellationFinished()
        #expect(r.cancelled)
        #expect(log.text.contains("Polecenie nie zostało uruchomione"))
        #expect(!log.text.contains("zatrzymać"))
        // A remote stop would itself wait for the silent port (ConnectTimeout 10 s).
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aTimeoutBeforeTheStartNeedsNoRemoteStop() async throws {
        let listener = try #require(SilentListener())
        let host = Machine(name: "cisza", address: "127.0.0.1", user: "nikt", port: listener.port)
        let handle = ProcessHandle()
        let log = OutputLog()
        let start = Date()
        let r = await SSH.run(RemoteScript("echo x"), on: host, password: nil, settings: settings, timeout: 1,
                              handle: handle, onOutput: { _, d in log.append(d) })
        #expect(r.timedOut)
        #expect(!log.text.contains("zatrzymać"))
        #expect(!r.stderrText.contains("▸"))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func portProbeTellsAnsweringMacsApart() async throws {
        let listener = try #require(SilentListener())
        let s = SSHSettings(askpassPath: "/tmp/askpass")
        #expect(await SSH.portAnswers(Machine(name: "a", address: "127.0.0.1", user: "x", port: listener.port), settings: s) == true)
        // Refused: the Mac is on, only Remote Login is off.
        let closedPort = try #require(SilentListener()).port
        #expect(await SSH.portAnswers(Machine(name: "b", address: "127.0.0.1", user: "x", port: closedPort), settings: s) == true)
        #expect(await SSH.portAnswers(Machine(name: "c", address: "cmcr-brak.invalid", user: "x"), settings: s) == false)
        var routed = s
        routed.extraOptions = ["ProxyJump=brama"]
        #expect(await SSH.portAnswers(Machine(name: "d", address: "127.0.0.1", user: "x", port: listener.port), settings: routed) == nil)
    }
}
