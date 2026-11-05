import Darwin
import Foundation
import Testing
@testable import CMCRCore

/// The scripts that run on the iMac for CMCR Screen Agent (docs/screen-agent.md), executed locally as sshd would
/// (`/bin/sh -c remoteCommand()`), without ssh, without root and without the real agent:
/// - every system path lives under `CMCR_SETUP_ROOT_PREFIX` (a folder in /tmp – socket paths must stay short);
/// - the agent is a bash stub at the prefixed executable path that answers like `cmcr-screen-agent client`
///   (control files in $T: agent-state up|down|down-revivable|untrusted, agent-noperm, agent-locked, notice, …);
/// - `launchctl` keeps the loaded state of each `gui/<uid>` in $T/launchd and never reaches the real launchd; `print`
///   of a loaded agent reports `pid = 4242` (the stub ignores `--pid`, the log shows it was passed);
/// - `sudo` runs the command as the current user, `codesign`, `chown`, `tccutil`, `pkill`, `xattr` only log, `ps`
///   reports the GUI sessions listed in $T/sessions, `stat` the console user from $T/console_user (and the owner
///   4242 for the paths listed in $T/foreign), `pgrep` the attention-mode overlay from $T/attention.
/// `guardFakes()` checks that every bash (also a nested one) sees the fakes before any script runs.
@Suite struct ScreenAgentScriptsTests {
    struct Sandbox {
        let dir: URL
        var root: String { dir.appendingPathComponent("root").path }
        var log: URL { dir.appendingPathComponent("log") }
        var agentApp: String { root + ScreenAgentInfo.appPath }
        var agentExe: String { root + ScreenAgentInfo.executablePath }
        var plist: String { root + ScreenAgentInfo.plistPath }
        var runDir: String { root + ScreenAgentInfo.runDir }
        var shotsDir: String { root + ScreenAgentInfo.shotsDir }
        static let me = String(cString: getpwuid(getuid())!.pointee.pw_name)
        static let myUID = Int(getuid())

        init() throws {
            // /tmp, not the per-user temp folder: a unix socket path is limited to 104 bytes.
            dir = URL(fileURLWithPath: "/tmp/cmcr-at-\(UUID().uuidString.prefix(8).lowercased())")
            try FileManager.default.createDirectory(atPath: dir.appendingPathComponent("root").path,
                                                    withIntermediateDirectories: true)
            let fakes = #"""
            _t_log() { printf '%s\n' "$*" >> "$T/log"; }
            sudo() {
              while [ $# -gt 0 ]; do
                case "$1" in -A|-n|-k|-H) shift ;; -u|-g|-p|-C|-h) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac
              done
              [ $# -eq 0 ] && return 0
              _t_log "sudo $*"
              SUDO_USER="$(id -un)" "$@"
            }
            stat() {
              if [ "$*" = "-f%Su /dev/console" ]; then
                if [ -f "$T/console_user" ]; then cat "$T/console_user"; else id -un; fi
                return 0
              fi
              if [ $# = 3 ] && [ "$1 $2" = "-f %u" ] && grep -qxF -- "$3" "$T/foreign" 2>/dev/null; then echo 4242; return 0; fi
              command stat "$@"
            }
            ps() {
              if [ "$*" = "-axo uid=,user=,comm=" ]; then cat "$T/sessions" 2>/dev/null; return 0; fi
              command ps "$@"
            }
            _t_revive() { [ "$(cat "$T/agent-state" 2>/dev/null)" = down-revivable ] && echo up > "$T/agent-state"; return 0; }
            launchctl() {
              _t_log "launchctl $*"
              local t uid
              case "${1:-}" in
                print)
                  case "${2:-}" in
                    gui/*/*)
                      t="${2#gui/}"; uid="${t%%/*}"
                      [ -e "$T/launchd/$uid" ] || return 113
                      printf '%s = {\n\tactive count = 1\n\tpid = 4242\n\tendpoints = {\n\t\tpid = 1\n\t}\n}\n' "$2"
                      return 0 ;;
                  esac
                  return 113 ;;
                bootstrap)
                  uid="${2#gui/}"; mkdir -p "$T/launchd"
                  if [ -e "$T/launchd/$uid" ]; then echo "Bootstrap failed: 5: Input/output error" >&2; return 5; fi
                  : > "$T/launchd/$uid"; _t_revive; return 0 ;;
                bootout)
                  t="${2#gui/}"; uid="${t%%/*}"
                  [ -e "$T/launchd/$uid" ] || { echo "Boot-out failed: 3: No such process" >&2; return 3; }
                  rm -f "$T/launchd/$uid"; return 0 ;;
                kickstart)
                  t="${3#gui/}"; uid="${t%%/*}"
                  [ -e "$T/launchd/$uid" ] || return 113
                  _t_revive; return 0 ;;
                enable|disable) return 0 ;;
              esac
              echo "launchctl (atrapa): nieoczekiwane $*" >&2
              return 1
            }
            codesign() {
              _t_log "codesign $*"
              local last="${@: -1}"
              case "${1:-}" in
                --verify) if [ -e "$T/codesign-fail" ]; then echo "$last: invalid signature" >&2; return 1; fi; return 0 ;;
                -d)
                  if [ -e "$T/stable-dr" ]; then echo 'designated => identifier "pl.cmcr.manager.screen-agent" and certificate leaf = H"0011"' >&2
                  else echo "designated => cdhash H\"$(md5 -q "$last/Contents/Info.plist")\"" >&2; fi
                  return 0 ;;
              esac
              return 1
            }
            # The attention-mode overlay: from $T/attention. A real `pgrep -f CMCR_ATTENTION` would also find the pgrep of
            # another test running at the same moment (same account).
            pgrep() {
              case " $* " in *" CMCR_ATTENTION "*) [ -e "$T/attention" ]; return ;; esac
              command pgrep "$@"
            }
            chown() { _t_log "chown $*"; }
            tccutil() { _t_log "tccutil $*"; }
            pkill() { _t_log "pkill $*"; }
            xattr() { _t_log "xattr $*"; }
            export -f _t_log sudo stat ps _t_revive launchctl codesign pgrep chown tccutil pkill xattr
            """#
            try fakes.write(to: dir.appendingPathComponent("fakes.sh"), atomically: true, encoding: .utf8)
        }

        var environment: [String: String] {
            ["BASH_ENV": dir.appendingPathComponent("fakes.sh").path, "T": dir.path, "CMCR_SETUP_ROOT_PREFIX": root,
             "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        }

        func guardFakes() async -> Bool {
            let names = "sudo launchctl codesign chown tccutil pkill pgrep ps stat xattr"
            let r = await ProcessRunner.run("/bin/bash", ["--noprofile", "--norc", "-c",
                                                          "type -t \(names); /bin/bash --noprofile --norc -c 'type -t \(names)'"],
                                            environment: environment)
            return r.stdoutText == String(repeating: "function\n", count: 20)
        }

        func write(_ name: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func touch(_ name: String) { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil) }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
        func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        func clearLog() { try? FileManager.default.removeItem(at: log) }
        func remove() { try? FileManager.default.removeItem(at: dir) }

        /// Marks the agent as loaded (and running) by launchd in gui/<uid>, with its folder run/<uid> as root made it.
        func load(_ uid: Int) throws {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("launchd"), withIntermediateDirectories: true)
            touch("launchd/\(uid)")
            try FileManager.default.createDirectory(atPath: "\(runDir)/\(uid)", withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        func isLoaded(_ uid: Int) -> Bool { exists(dir.appendingPathComponent("launchd/\(uid)").path) }

        /// A socket node like the one the agent binds (the stub cannot): `cmcr_agent_wait` looks for it.
        func makeSocket(_ uid: Int) throws {
            try FileManager.default.createDirectory(atPath: "\(runDir)/\(uid)", withIntermediateDirectories: true)
            let path = root + ScreenAgentInfo.socketPath(uid: "\(uid)")
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(fd >= 0)
            defer { close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            try #require(bytes.count < MemoryLayout.size(ofValue: addr.sun_path), "ścieżka gniazda za długa: \(path)")
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try #require(rc == 0, "bind: \(String(cString: strerror(errno)))")
        }

        /// The fake agent: a bash script answering like `cmcr-screen-agent client <uid> <command> …`.
        static let stub = #"""
        #!/bin/bash
        _t_log "agent $*"
        [ "${1:-}" = client ] || exit 2
        uid="$2"; cmd="$3"
        case "$(cat "$T/agent-state" 2>/dev/null || echo up)" in
          down|down-revivable) echo "ERR unreachable brak odpowiedzi na gnieździe"; exit 10 ;;
          untrusted) echo "ERR untrusted na gnieździe odpowiada inny program"; exit 11 ;;
        esac
        ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(dirname "$0")/../Info.plist" 2>/dev/null)"
        case "$cmd" in
          ping)
            perm=granted; [ -e "$T/agent-noperm" ] && perm=denied
            echo "AGENT $ver perm=$perm locked=0 console=1 asleep=0 user=$(id -un "$uid")"; exit 0 ;;
          notice) echo "NOTICE $(cat "$T/notice" 2>/dev/null || echo shown)"; exit 0 ;;
          request-permission) echo "PERMISSION $(cat "$T/permission" 2>/dev/null || echo denied)"; exit 0 ;;
          capture)
            [ -e "$T/agent-noperm" ] && { echo "ERR noperm brak uprawnienia Nagrywanie ekranu"; exit 12; }
            [ -e "$T/agent-locked" ] && { echo "ERR locked ekran jest zablokowany"; exit 13; }
            [ -e "$T/agent-asleep" ] && { echo "ERR asleep ekran jest uśpiony"; exit 14; }
            d="$CMCR_SETUP_ROOT_PREFIX/Library/Application Support/CMCR/ScreenAgent/shots/$uid"; mkdir -p "$d"
            c=0
            if [ -e "$T/variant-cycle" ]; then c=$(( $(cat "$T/calls" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$T/calls"; fi
            echo "FRONT $(cat "$T/front" 2>/dev/null || echo 'Safari – Nowa karta')"
            case "$6" in main) list=1 ;; all) list="$(seq 1 "$(cat "$T/displays" 2>/dev/null || echo 1)")" ;; *) list="$6" ;; esac
            for i in $list; do
              f="$d/screen-$i.jpg"
              printf 'JPEG ekran %s wersja %s %s\n' "$i" "$c" "$4x$5" > "$f.tmp" && mv -f "$f.tmp" "$f"
              echo "SHOT $i 100 50 $(wc -c < "$f" | tr -d ' ') $f"
            done
            exit 0 ;;
        esac
        echo "ERR protocol nieznane polecenie"; exit 2
        """#

        /// A CMCR Screen Agent.app bundle in `parent` whose executable is the stub.
        static func makeBundle(in parent: String, version: String, id: String = ScreenAgentInfo.bundleID) throws -> URL {
            let app = URL(fileURLWithPath: parent).appendingPathComponent(ScreenAgentInfo.appName)
            let macos = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let info = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(id)</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleExecutable</key><string>\(ScreenAgentInfo.executableName)</string>
            </dict></plist>
            """
            try info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
            let exe = macos.appendingPathComponent(ScreenAgentInfo.executableName)
            try stub.write(to: exe, atomically: true, encoding: .utf8)
            chmod(exe.path, 0o777)  // group/other write: the install must take it away
            return app
        }

        /// The agent installed directly under the prefix (preview and status tests); `running`: launchd runs it in the
        /// sessions of this account and of daemon (uid 1, the "student" of the tests).
        func installAgent(version: String = ScreenAgentInfo.version, running: Bool = true) throws {
            try FileManager.default.createDirectory(atPath: root + ScreenAgentInfo.installDir, withIntermediateDirectories: true)
            _ = try Self.makeBundle(in: root + ScreenAgentInfo.installDir, version: version)
            if running {
                try load(Self.myUID)
                try load(1)
            }
        }

        /// An uploaded archive as `Operations.installScreenAgent` makes it (`Payload.make`), in /tmp like scp puts it.
        func upload(version: String, id: String = ScreenAgentInfo.bundleID) async throws -> String {
            let src = dir.appendingPathComponent("src-\(UUID().uuidString.prefix(6))").path
            let app = try Self.makeBundle(in: src, version: version, id: id)
            let tar = try await Payload.make([app]).get()
            let remote = dir.appendingPathComponent("cmcr-up-\(UUID().uuidString.prefix(8)).tar").path
            try FileManager.default.moveItem(atPath: tar.path, toPath: remote)
            return remote
        }

        func run(_ script: RemoteScript) async -> CommandResult {
            await ProcessRunner.run("/bin/sh", ["-c", script.remoteCommand()], environment: environment,
                                    stdin: Data("haslo\n".utf8), timeout: 90)
        }

        /// Runs a script with stdin left open until it exits – a capture stream waits between cycles only while the
        /// app keeps its input open (end of input ends the stream).
        func runOpen(_ script: RemoteScript, timeout: TimeInterval = 60) async -> (code: Int32, stdout: Data, stderr: String) {
            await withCheckedContinuation { cont in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script.remoteCommand()]
                p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                let out = Pipe(), err = Pipe(), input = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = input
                do { try p.run() } catch { cont.resume(returning: (-1, Data(), "\(error)")); return }
                input.fileHandleForWriting.write(Data("haslo\n".utf8))
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                DispatchQueue.global().async {
                    var errData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    try? input.fileHandleForWriting.close()
                    group.wait()
                    killer.cancel()
                    cont.resume(returning: (p.terminationStatus, outData, String(decoding: errData, as: UTF8.self)))
                }
            }
        }
    }

    static func events(_ data: Data) -> [ScreenEvent] {
        var parser = ScreenStreamParser()
        return parser.feed(data)
    }
    static func options(frames: Int = 1, notify: Bool = true, last: String? = nil, display: ScreenDisplay = .main) -> ScreenCaptureOptions {
        ScreenCaptureOptions(maxSize: 640, quality: 55, interval: 2, notify: notify, alreadyNotifiedUser: last,
                             onlyStandardAccounts: false, allowedUsers: [], display: display, frames: frames)
    }

    // MARK: - Preview script

    @Test func previewSendsTheAgentsFileThenSameWhenUnchanged() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.installAgent()
        let r = await box.runOpen(Scripts.screenCapture(Self.options(frames: 2)))
        let events = Self.events(r.stdout)
        #expect(r.code == 0, "\(r.stderr)")
        #expect(events.first == .hello(privileged: false), "the SSH account is the one at the screen: no sudo")
        #expect(!box.logText().contains("sudo "))
        let file = box.shotsDir + "/\(Sandbox.myUID)/screen-1.jpg"
        let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
        let frames = events.compactMap { e -> Data? in if case .frame(1, 1, _, let d) = e { return d }; return nil }
        #expect(frames == [bytes], "the agent's JPEG is sent as it is (no second encoding)")
        let same = events.contains { if case .unchanged(1, 1, _) = $0 { return true }; return false }
        #expect(same, "\(events)")
        #expect(events.contains(.info(user: Sandbox.me, frontApp: "Safari – Nowa karta")))
        // Notice once per login session, then capture with the requested size, quality and display.
        let log = box.logText()
        #expect(log.components(separatedBy: "agent client \(Sandbox.myUID) notice ").count == 2, "\(log)")
        #expect(log.contains("agent client \(Sandbox.myUID) notice \(Data(Scripts.observeNoticeTitle.utf8).base64EncodedString()) \(Data(Scripts.observeNoticeText.utf8).base64EncodedString())"))
        #expect(log.components(separatedBy: "agent client \(Sandbox.myUID) capture 640 55 main --pid 4242").count == 3, "\(log)")
        #expect(!log.contains("launchctl kickstart") && !log.contains("launchctl bootstrap"), "a running agent is not restarted")
        #expect(events.contains { if case .notified(Sandbox.me, _) = $0 { return true }; return false })
    }

    @Test func previewOfAnotherAccountRunsAsRootOnceAndSendsEveryDisplay() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.installAgent()
        try box.write("console_user", "daemon")
        try box.write("displays", "2")
        box.touch("variant-cycle")
        let r = await box.runOpen(Scripts.screenCapture(Self.options(frames: 2, display: .all)))
        let events = Self.events(r.stdout)
        #expect(r.code == 0, "\(r.stderr)")
        #expect(events.contains(.hello(privileged: true)))
        #expect(box.logText().split(separator: "\n").filter { $0.hasPrefix("sudo ") }.count == 1,
                "one sudo for the whole stream: \(box.logText())")
        let frames = events.compactMap { e -> (Int, Int, String)? in
            if case .frame(let d, let n, let h, _) = e { return (d, n, h) }; return nil
        }
        #expect(frames.map(\.0) == [1, 2, 1, 2] && frames.allSatisfy { $0.1 == 2 }, "\(frames)")
        #expect(Set(frames.map(\.2)).count == 4, "a changed picture is a new frame")
        #expect(box.logText().contains("agent client 1 capture 640 55 all"))
        // No session id without a loginwindow of that account: the account itself is the session.
        #expect(events.contains(.notified(user: "daemon", session: "daemon")))
    }

    @Test func noticeGateAndAlreadyNotifiedSession() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.installAgent()
        try box.write("console_user", "daemon")
        // Told already in this login session: straight to the capture.
        var r = await box.run(Scripts.screenCapture(Self.options(last: "daemon")))
        #expect(r.exitCode == 0, "\(r.stderrText)")
        #expect(!box.logText().contains(" notice "))
        #expect(Operations.screenshot(from: r).imageData != nil)
        // Notice not on screen: no picture, not notified, the next cycle tries again.
        box.clearLog()
        for (state, words) in [("hidden", "nie pojawiło się"), ("locked", "zablokowany lub uśpiony"), ("???", "nie potwierdziła")] {
            try box.write("notice", state)
            r = await box.run(Scripts.screenCapture(Self.options()))
            let shot = Operations.screenshot(from: r)
            #expect(r.exitCode == ScriptCode.observeNotNotified, "\(state): \(r.stdoutText)")
            #expect(shot.imageData == nil && shot.notifiedUser == nil)
            if case .notifyFailed("daemon", let detail)? = shot.issue { #expect(detail.contains(words), "\(detail)") }
            else { Issue.record("\(state): \(String(describing: shot.issue))") }
        }
        #expect(!box.logText().contains(" capture "), "nothing is captured without a confirmed notice")
        // The attention-mode lock is not something the agent sees – still checked by the script, before the agent.
        box.clearLog()
        try box.write("notice", "shown")
        box.touch("attention")
        r = await box.run(Scripts.screenCapture(Self.options()))
        #expect(r.exitCode == ScriptCode.observeNotNotified)
        if case .notifyFailed(_, let detail)? = Operations.screenshot(from: r).issue { #expect(detail.contains("trybie uwagi")) }
        else { Issue.record("\(r.stdoutText)") }
        #expect(!box.logText().contains("agent "))
        try FileManager.default.removeItem(at: box.dir.appendingPathComponent("attention"))
        // Notices off (not reachable from the app, KON-06): never asked.
        box.clearLog()
        r = await box.run(Scripts.screenCapture(Self.options(notify: false)))
        #expect(r.exitCode == 0 && !box.logText().contains(" notice "))
    }

    @Test func lockedScreenAtCaptureIsANoticeProblem() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.installAgent()
        box.touch("agent-locked")
        let r = await box.run(Scripts.screenCapture(Self.options()))
        let shot = Operations.screenshot(from: r)
        #expect(r.exitCode == ScriptCode.observeNotNotified)
        if case .notifyFailed(_, let detail)? = shot.issue { #expect(detail.contains("zablokowany")) }
        else { Issue.record("\(String(describing: shot.issue))") }
        #expect(shot.issue?.hidesImage == true)
        // Asleep (code 14) at capture time is a capture problem, worded for people.
        try FileManager.default.removeItem(at: box.dir.appendingPathComponent("agent-locked"))
        box.touch("agent-asleep")
        let asleep = Operations.screenshot(from: await box.run(Scripts.screenCapture(Self.options())))
        #expect(asleep.issue == .captureFailed("ekran jest uśpiony"))
    }

    @Test func missingUntrustedAndUnpermittedAgents() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.write("console_user", "daemon")
        // Not installed: reported without spending a sudo.
        var r = await box.run(Scripts.screenCapture(Self.options()))
        #expect(r.exitCode == ScriptCode.agentUnavailable, "\(r.stdoutText) \(r.stderrText)")
        #expect(Operations.screenshot(from: r).issue == .agentMissing)
        #expect(!box.logText().contains("sudo "))
        // Something else answers on the socket.
        try box.installAgent()
        try box.write("agent-state", "untrusted")
        r = await box.run(Scripts.screenCapture(Self.options()))
        #expect(r.exitCode == ScriptCode.agentUnavailable)
        #expect(Operations.screenshot(from: r).issue == .agentUntrusted("na gnieździe odpowiada inny program"))
        #expect(!box.logText().contains("kickstart") && !box.logText().contains("bootstrap"), "no restart for an impostor")
        // No Screen Recording permission yet.
        try box.write("agent-state", "up")
        box.touch("agent-noperm")
        r = await box.run(Scripts.screenCapture(Self.options()))
        #expect(r.exitCode == ScriptCode.captureFailed)
        #expect(Operations.screenshot(from: r).issue == .agentPermission)
    }

    @Test func silentAgentIsRestartedOnceThenReportedDown() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.installAgent(running: false)
        try box.makeSocket(Sandbox.myUID)
        // Not loaded in the session: never asked without a process launchd started – bootstrap, then it answers.
        try box.write("agent-state", "down-revivable")
        var r = await box.run(Scripts.screenCapture(Self.options()))
        #expect(r.exitCode == 0, "\(r.stdoutText) \(r.stderrText)")
        #expect(Operations.screenshot(from: r).imageData != nil)
        let log = box.logText()
        #expect(log.contains("launchctl bootstrap gui/\(Sandbox.myUID) \(box.plist)"), "\(log)")
        #expect(!log.contains("kickstart"))
        #expect(!log.contains(" notice ") || log.range(of: "launchctl bootstrap")!.lowerBound < log.range(of: " notice ")!.lowerBound,
                "the client is not run before launchd has the agent: \(log)")
        // Loaded but silent: kickstart -k; still silent – asked once more, then STATE agent-down.
        box.clearLog()
        try box.write("agent-state", "down")
        let started = Date()
        r = await box.run(Scripts.screenCapture(Self.options()))
        #expect(r.exitCode == ScriptCode.agentUnavailable)
        #expect(Operations.screenshot(from: r).issue == .agentDown("brak odpowiedzi na gnieździe"))
        let again = box.logText()
        #expect(again.contains("launchctl kickstart -k gui/\(Sandbox.myUID)/\(ScreenAgentInfo.label)"), "\(again)")
        #expect(again.components(separatedBy: " notice ").count == 3, "the notice is asked exactly twice: \(again)")
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test func reviveMakesTheAgentsOwnFolderFirst() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.installAgent(running: false)
        let mine = "\(box.runDir)/\(Sandbox.myUID)"
        // Something planted at the agent's folder name: a file, a link to another folder, a folder of another account.
        try FileManager.default.createDirectory(atPath: box.runDir, withIntermediateDirectories: true)
        let elsewhere = box.dir.appendingPathComponent("elsewhere").path
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: elsewhere + "/keep", contents: Data("x".utf8))
        chmod(box.runDir, 0o1733)
        let planted: [(String, () throws -> Void)] = [
            ("file", { FileManager.default.createFile(atPath: mine, contents: Data("x".utf8)) }),
            ("link", { try FileManager.default.createSymbolicLink(atPath: mine, withDestinationPath: elsewhere) }),
            ("foreign", {
                try FileManager.default.createDirectory(atPath: mine, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: mine + "/planted", contents: nil)
                try box.write("foreign", mine + "\n")
            }),
        ]
        for (name, plant) in planted {
            try? FileManager.default.removeItem(atPath: mine)
            try? FileManager.default.removeItem(at: box.dir.appendingPathComponent("launchd/\(Sandbox.myUID)"))
            try plant()
            box.clearLog()
            let r = await box.run(Scripts.screenCapture(Self.options(notify: false)))
            #expect(r.exitCode == 0, "\(name): \(r.stdoutText) \(r.stderrText)")
            // Only root can make the folder: even the account at the screen asks through sudo then.
            #expect(Operations.screenshot(from: r).privileged, "\(name)")
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: mine, isDirectory: &isDir) && isDir.boolValue, "\(name)")
            #expect(mode(mine) == 0o700 && mode(box.runDir) == 0o755, "\(name): \(String(mode(mine), radix: 8))")
            #expect(!box.exists(mine + "/planted"), "\(name)")
            #expect(box.logText().contains("chown \(Sandbox.myUID):"), "\(name): \(box.logText())")
            let log = box.logText()
            let made = try #require(log.range(of: "chown \(Sandbox.myUID):"), "\(name)")
            let started = try #require(log.range(of: "launchctl bootstrap gui/\(Sandbox.myUID)"), "\(name)")
            #expect(made.lowerBound < started.lowerBound, "the folder exists before launchd starts the agent")
            try? FileManager.default.removeItem(at: box.dir.appendingPathComponent("foreign"))
        }
        #expect(box.exists(elsewhere + "/keep"), "a link is removed, never what it points to")
    }

    @Test func nobodyLoggedInAndRestrictionsNeverAskTheAgent() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.installAgent()
        try box.write("console_user", "root")
        var r = await box.run(Scripts.screenCapture(Self.options()))
        #expect(r.exitCode == ScriptCode.noConsoleUser)
        #expect(Operations.screenshot(from: r).issue == .noUser)
        try box.write("console_user", "daemon")
        var o = Self.options()
        o.allowedUsers = ["student"]
        r = await box.run(Scripts.screenCapture(o))
        #expect(r.exitCode == ScriptCode.observeDenied)
        #expect(!box.logText().contains("agent "), "the agent is not asked for anything")
    }

    // MARK: - Install, update, removal

    @Test func installUpdateAndUnchanged() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.write("sessions", "  \(Sandbox.myUID) \(Sandbox.me) /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow\n")
        try box.makeSocket(Sandbox.myUID)
        // A socket of the older layout (run/<uid>.sock in a run/ everyone could write) goes with the install.
        FileManager.default.createFile(atPath: "\(box.runDir)/1234.sock", contents: nil)

        // Fresh install.
        var tar = try await box.upload(version: ScreenAgentInfo.version)
        var r = await box.run(Scripts.installScreenAgent(remoteTar: tar))
        #expect(r.exitCode == 0, "\(r.stdoutText)\n\(r.stderrText)")
        #expect(r.stdoutText.contains("CMCR:AGENT installed \(ScreenAgentInfo.version)\n"))
        #expect(r.stdoutText.contains("CMCR:AGENT-SESSION \(Sandbox.me) \(Sandbox.myUID) AGENT \(ScreenAgentInfo.version) perm=granted"), "\(r.stdoutText)")
        #expect(!box.exists(tar), "the uploaded archive is always removed")
        #expect(box.isLoaded(Sandbox.myUID))
        let plistText = try String(contentsOfFile: box.plist, encoding: .utf8)
        #expect(plistText == ScreenAgentInfo.launchAgentPlist(executable: box.agentExe))
        #expect(mode(box.plist) == 0o644)
        #expect(mode(box.runDir) == 0o755, "run/ is root's own")
        #expect(mode("\(box.runDir)/\(Sandbox.myUID)") == 0o700, "the agent's own folder, made before it starts")
        #expect(!box.exists("\(box.runDir)/1234.sock"))
        #expect(mode(box.shotsDir) == 0o700)
        #expect(mode(box.agentExe) == 0o755, "group/other write removed")
        let log = box.logText()
        #expect(log.contains("chown -R root:wheel"))
        #expect(log.contains("xattr -dr com.apple.quarantine"))
        #expect(log.contains("launchctl bootstrap gui/\(Sandbox.myUID) \(box.plist)"))
        #expect(!log.contains("tccutil"), "a first install has no permission to lose")
        #expect(log.components(separatedBy: " ping --pid 4242").count == 2, "asked once, as the launchd process: \(log)")
        let inode = try inodeOf(box.agentExe)

        // The same version again: untouched, only started where it is not loaded.
        box.clearLog()
        try FileManager.default.removeItem(at: box.dir.appendingPathComponent("launchd/\(Sandbox.myUID)"))
        tar = try await box.upload(version: ScreenAgentInfo.version)
        r = await box.run(Scripts.installScreenAgent(remoteTar: tar))
        #expect(r.exitCode == 0, "\(r.stderrText)")
        #expect(r.stdoutText.contains("CMCR:AGENT unchanged \(ScreenAgentInfo.version)\n"))
        #expect(try inodeOf(box.agentExe) == inode, "the same file stays (with its Screen Recording permission)")
        #expect(!box.logText().contains("bootout"))
        #expect(box.logText().contains("launchctl bootstrap gui/\(Sandbox.myUID)"))
        #expect(!box.exists(tar))
        // …and nothing at all when it runs already.
        box.clearLog()
        r = await box.run(Scripts.installScreenAgent(remoteTar: try await box.upload(version: ScreenAgentInfo.version)))
        #expect(r.stdoutText.contains("CMCR:AGENT unchanged"))
        #expect(!box.logText().contains("bootstrap") && !box.logText().contains("bootout"))

        // A new version (ad-hoc: another designated requirement): stopped first, swapped, permission reset.
        box.clearLog()
        r = await box.run(Scripts.installScreenAgent(remoteTar: try await box.upload(version: "9.0.0")))
        #expect(r.exitCode == 0, "\(r.stderrText)")
        #expect(r.stdoutText.contains("CMCR:AGENT updated 9.0.0\n"))
        #expect(r.stdoutText.contains("trzeba nadać ponownie"))
        #expect(try inodeOf(box.agentExe) != inode)
        let up = box.logText()
        let bootout = try #require(up.range(of: "launchctl bootout gui/\(Sandbox.myUID)/\(ScreenAgentInfo.label)"), "\(up)")
        let bootstrap = try #require(up.range(of: "launchctl bootstrap gui/\(Sandbox.myUID)"), "\(up)")
        #expect(bootout.lowerBound < bootstrap.lowerBound)
        #expect(up.contains("tccutil reset ScreenCapture \(ScreenAgentInfo.label)"))
        #expect(r.stdoutText.contains("CMCR:AGENT-SESSION \(Sandbox.me) \(Sandbox.myUID) AGENT 9.0.0 "))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.root + ScreenAgentInfo.installDir)
        #expect(Set(leftovers) == [ScreenAgentInfo.appName, "run", "shots"], "\(leftovers)")

        // A stable signing identity keeps the permission: no reset, no warning.
        box.clearLog()
        box.touch("stable-dr")
        r = await box.run(Scripts.installScreenAgent(remoteTar: try await box.upload(version: "9.1.0")))
        #expect(r.stdoutText.contains("CMCR:AGENT updated 9.1.0\n"))
        #expect(!r.stdoutText.contains("trzeba nadać ponownie") && !box.logText().contains("tccutil"))

        // Never a downgrade: an older upload leaves the newer copy, its LaunchAgent and its sessions alone.
        box.clearLog()
        let newer = try inodeOf(box.agentExe)
        r = await box.run(Scripts.installScreenAgent(remoteTar: try await box.upload(version: ScreenAgentInfo.version)))
        #expect(r.exitCode == 0, "\(r.stderrText)")
        #expect(r.stdoutText.contains("CMCR:AGENT newer 9.1.0\n") && r.stdoutText.contains("Zaktualizuj CMCR Manager"),
                "\(r.stdoutText)")
        #expect(!r.stdoutText.contains("CMCR:AGENT-SESSION"))
        #expect(try inodeOf(box.agentExe) == newer)
        let kept = box.logText()
        #expect(!kept.contains("bootout") && !kept.contains("bootstrap") && !kept.contains("kickstart") && !kept.contains("tccutil"),
                "\(kept)")
        // 10 > 9 (numbers, not text): an upgrade.
        r = await box.run(Scripts.installScreenAgent(remoteTar: try await box.upload(version: "10.0.0")))
        #expect(r.stdoutText.contains("CMCR:AGENT updated 10.0.0\n"), "\(r.stdoutText)")

        // Removal: stopped, every file and the permission entry gone.
        box.clearLog()
        r = await box.run(Scripts.removeScreenAgent())
        #expect(r.exitCode == 0, "\(r.stderrText)")
        #expect(r.stdoutText.contains("CMCR:AGENT removed 10.0.0\n"))
        #expect(!box.exists(box.agentApp) && !box.exists(box.plist) && !box.exists(box.runDir) && !box.exists(box.shotsDir))
        #expect(!box.isLoaded(Sandbox.myUID))
        #expect(box.logText().contains("tccutil reset ScreenCapture \(ScreenAgentInfo.label)"))
        r = await box.run(Scripts.removeScreenAgent())
        #expect(r.exitCode == 0 && r.stdoutText.contains("CMCR:AGENT absent -"))
    }

    @Test func installRestartsAnAgentWithoutPermissionOnceAndOnlyAnOldOne() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.write("sessions", "  \(Sandbox.myUID) \(Sandbox.me) /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow\n")
        box.touch("agent-noperm")
        // Started by this install: its answer is already fresh.
        var r = await box.run(Scripts.installScreenAgent(remoteTar: try await box.upload(version: ScreenAgentInfo.version)))
        #expect(r.stdoutText.contains("CMCR:AGENT-SESSION \(Sandbox.me) \(Sandbox.myUID) AGENT \(ScreenAgentInfo.version) perm=denied"),
                "\(r.stdoutText)")
        #expect(!box.logText().contains("kickstart"), "\(box.logText())")
        #expect(box.logText().components(separatedBy: " ping --pid").count == 2, "asked once: \(box.logText())")
        // Running from before (the usual state before a visit): started anew once, so a permission granted meanwhile
        // counts – and the answer is the fresh agent's, not a missing one.
        box.clearLog()
        r = await box.run(Scripts.installScreenAgent(remoteTar: try await box.upload(version: ScreenAgentInfo.version)))
        #expect(r.stdoutText.contains("CMCR:AGENT unchanged"))
        #expect(r.stdoutText.contains("CMCR:AGENT-SESSION \(Sandbox.me) \(Sandbox.myUID) AGENT \(ScreenAgentInfo.version) perm=denied"),
                "\(r.stdoutText)")
        let log = box.logText()
        #expect(log.components(separatedBy: "launchctl kickstart -k gui/\(Sandbox.myUID)/").count == 2, "\(log)")
        // Granted: nothing restarted.
        try FileManager.default.removeItem(at: box.dir.appendingPathComponent("agent-noperm"))
        box.clearLog()
        r = await box.run(Scripts.installScreenAgent(remoteTar: try await box.upload(version: ScreenAgentInfo.version)))
        #expect(r.stdoutText.contains("perm=granted") && !box.logText().contains("kickstart"), "\(box.logText())")
    }

    @Test func badUploadsAreRefusedAndRemoved() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        var tar = try await box.upload(version: "1.0.0", id: "com.example.other")
        var r = await box.run(Scripts.installScreenAgent(remoteTar: tar))
        #expect(r.exitCode == 1 && r.stderrText.contains("com.example.other"), "\(r.stderrText)")
        #expect(!box.exists(tar) && !box.exists(box.agentApp) && !box.exists(box.plist))
        tar = try await box.upload(version: "1.0.0")
        box.touch("codesign-fail")
        r = await box.run(Scripts.installScreenAgent(remoteTar: tar))
        #expect(r.exitCode == 1 && r.stderrText.contains("Podpis"), "\(r.stderrText)")
        #expect(!box.exists(tar) && !box.exists(box.agentApp))
        try "not a tar".write(toFile: box.dir.appendingPathComponent("junk.tar").path, atomically: true, encoding: .utf8)
        r = await box.run(Scripts.installScreenAgent(remoteTar: box.dir.appendingPathComponent("junk.tar").path))
        #expect(r.exitCode == 1 && !box.exists(box.dir.appendingPathComponent("junk.tar").path))
        // Nobody logged in: installed, started at the next login.
        try FileManager.default.removeItem(at: box.dir.appendingPathComponent("codesign-fail"))
        r = await box.run(Scripts.installScreenAgent(remoteTar: try await box.upload(version: "1.0.0")))
        #expect(r.exitCode == 0 && r.stdoutText.contains("CMCR:AGENT installed 1.0.0"), "\(r.stderrText)")
        #expect(r.stdoutText.contains("Nikt nie jest zalogowany") && !r.stdoutText.contains("CMCR:AGENT-SESSION"))
    }

    @Test func permissionRequestNeedsSomeoneAtTheScreen() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        var r = await box.run(Scripts.requestScreenAgentPermission())
        #expect(r.exitCode == ScriptCode.agentUnavailable, "\(r.stderrText)")
        try box.installAgent()
        r = await box.run(Scripts.requestScreenAgentPermission())
        #expect(r.exitCode == 0, "\(r.stderrText)")
        #expect(r.stdoutText.contains("CMCR:AGENT-PERMISSION denied\n") && r.stdoutText.contains("Nagrywanie ekranu"))
        #expect(box.logText().contains("agent client \(Sandbox.myUID) request-permission --pid 4242"))
        #expect(!box.logText().contains("kickstart"), "an agent with the permission is not restarted")
        // Without the permission: started anew first (a stale process may not see a permission granted since).
        box.clearLog()
        box.touch("agent-noperm")
        r = await box.run(Scripts.requestScreenAgentPermission())
        #expect(r.exitCode == 0, "\(r.stderrText)")
        let fresh = box.logText()
        let restart = try #require(fresh.range(of: "launchctl kickstart -k gui/\(Sandbox.myUID)/"), "\(fresh)")
        let request = try #require(fresh.range(of: "request-permission"), "\(fresh)")
        #expect(restart.lowerBound < request.lowerBound)
        try FileManager.default.removeItem(at: box.dir.appendingPathComponent("agent-noperm"))
        try box.write("permission", "granted")
        r = await box.run(Scripts.requestScreenAgentPermission())
        #expect(r.stdoutText.contains("CMCR:AGENT-PERMISSION granted\n"))
        try box.write("console_user", "root")
        r = await box.run(Scripts.requestScreenAgentPermission())
        #expect(r.exitCode == ScriptCode.noConsoleUser && r.stderrText.contains("Nikt nie jest zalogowany"))
    }

    // MARK: - Status and readiness

    @Test func statusComesFromTheAgentOfTheConsoleUser() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        var r = await box.run(Scripts.screenAgentStatus())
        #expect(r.exitCode == 0)
        var status = ScreenAgentStatus.parse(r.stdoutText)
        #expect(!status.isInstalled && status.consoleUser == Sandbox.me && status.permission == .unknown)
        try box.installAgent()
        try box.load(1)
        try box.write("console_user", "daemon")
        box.touch("agent-noperm")
        r = await box.run(Scripts.screenAgentStatus())
        #expect(r.exitCode == 0, "\(r.stderrText)")
        status = ScreenAgentStatus.parse(r.stdoutText)
        #expect(status.installedVersion == ScreenAgentInfo.version && status.isCurrent)
        #expect(status.loaded == true && status.permission == .denied && status.consoleUser == "daemon" && status.error == nil)
        #expect(box.logText().contains("sudo /bin/bash"), "another account's agent is asked as root")
        #expect(box.logText().contains("launchctl kickstart -k gui/1/"), "denied: asked again by a fresh agent")
        #expect(box.logText().components(separatedBy: "agent client 1 ping --pid 4242").count >= 3, "\(box.logText())")
        try box.write("agent-state", "down")
        status = ScreenAgentStatus.parse(await box.run(Scripts.screenAgentStatus()).stdoutText)
        #expect(status.errorCode == "unreachable" && status.error == "brak odpowiedzi na gnieździe")
        // Loaded without a process: not asked at all, reported as not answering.
        try FileManager.default.removeItem(at: box.dir.appendingPathComponent("launchd/1"))
        try box.write("agent-state", "up")
        box.clearLog()
        status = ScreenAgentStatus.parse(await box.run(Scripts.screenAgentStatus()).stdoutText)
        #expect(status.errorCode == "unreachable" && status.loaded == false, "\(status)")
        #expect(!box.logText().contains("agent client"), "\(box.logText())")
    }

    @Test func readinessAsksTheAgentInTheSandbox() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        try box.installAgent()
        try box.load(Sandbox.myUID)
        let r = await box.run(Scripts.readiness(student: "student", sharedFolder: "/Users/student/Public/cmcr", publicKey: nil))
        let report = ReadinessReport.parse(r.stdoutText, student: "student", sharedFolder: "/Users/student/Public/cmcr")
        #expect(report.values["agent_installed"] == "1" && report.values["agent_loaded"] == "1", "\(r.stdoutText)")
        #expect(report[.screen].state == .ok && report[.screen].short == "gotowy", "\(report[.screen]) \(r.stdoutText)")
        #expect(box.logText().components(separatedBy: " ping --pid 4242").count == 2, "asked once: \(box.logText())")
        #expect(!box.logText().contains("kickstart"))
        // Denied: the answer comes from an agent started anew (one granted at the computer since would show).
        box.clearLog()
        box.touch("agent-noperm")
        let denied = await box.run(Scripts.readiness(student: "student", sharedFolder: "/Users/student/Public/cmcr", publicKey: nil))
        let again = ReadinessReport.parse(denied.stdoutText, student: "student", sharedFolder: "/Users/student/Public/cmcr")
        #expect(again[.screen].short == "nadaj uprawnienie", "\(again[.screen])")
        #expect(box.logText().components(separatedBy: "launchctl kickstart -k gui/\(Sandbox.myUID)/").count == 2, "\(box.logText())")
    }
}

private func mode(_ path: String) -> Int {
    var st = Darwin.stat()
    return lstat(path, &st) == 0 ? Int(st.st_mode) & 0o7777 : -1
}

private func inodeOf(_ path: String) throws -> UInt64 {
    var st = Darwin.stat()
    try #require(lstat(path, &st) == 0)
    return UInt64(st.st_ino)
}

// MARK: - Status parser and the „Podgląd ekranu” cell

@Test func agentStatusParsesPingAndErrors() {
    let ok = ScreenAgentStatus.parse("console=jan\nagent_installed=1\nagent_version=1.0.0\nagent_loaded=1\n"
        + "agent_ping=AGENT 1.0.0 perm=granted locked=1 console=0 asleep=1 user=Jan Kowalski\nagent_ping_rc=0\n")
    #expect(ok.installedVersion == "1.0.0" && ok.isCurrent && ok.loaded == true && ok.runningVersion == "1.0.0")
    #expect(ok.permission == .granted && ok.locked && !ok.onConsole && ok.asleep)
    #expect(ok.consoleUser == "Jan Kowalski" && ok.error == nil && ok.errorCode == nil)

    let down = ScreenAgentStatus.parse("console=jan\nagent_installed=1\nagent_version=0.9\nagent_loaded=0\n"
        + "agent_ping=ERR unreachable brak gniazda\nagent_ping_rc=10\n")
    #expect(down.installedVersion == "0.9" && !down.isCurrent && down.loaded == false)
    #expect(down.permission == .unknown && down.errorCode == "unreachable" && down.error == "brak gniazda")
    #expect(down.consoleUser == "jan")

    let impostor = ScreenAgentStatus.parse("agent_installed=1\nagent_ping=ERR failed coś\nagent_ping_rc=11\n")
    #expect(impostor.errorCode == "untrusted" && impostor.installedVersion == "?")
    let garbage = ScreenAgentStatus.parse("agent_installed=1\nagent_version=1.0.0\nagent_ping=Segmentation fault\nagent_ping_rc=139\n")
    #expect(garbage.errorCode == "failed" && garbage.error == "Segmentation fault")
    let none = ScreenAgentStatus.parse("console=\nagent_installed=0\n")
    #expect(!none.isInstalled && none.consoleUser == nil && none.error == nil && none.permission == .unknown)
    // Without sudo for another account's session only the installed version is known.
    let nosudo = ScreenAgentStatus.parse("console=jan\nagent_installed=1\nagent_version=1.0.0\n")
    #expect(nosudo.loaded == nil && !nosudo.sessionChecked && nosudo.permission == .unknown)
}

@Test func screenCellFollowsTheReadinessTable() {
    let base = "os=14.7\nadmin=imac07\nkey=ok\nfolder=ok\nsudo=ok\n"
    func cell(_ extra: String) -> ReadinessItem {
        ReadinessReport.parse(base + extra, student: "student", sharedFolder: "/Users/student/Public/cmcr")[.screen]
    }
    func report(_ extra: String) -> ReadinessReport {
        ReadinessReport.parse(base + extra, student: "student", sharedFolder: "/Users/student/Public/cmcr")
    }
    let v = ScreenAgentInfo.version
    let ping = "agent_ping=AGENT \(v) perm=granted locked=0 console=1 asleep=0 user=student\nagent_ping_rc=0\n"

    #expect(ReadinessCheck.screen.title == "Podgląd ekranu")
    #expect(ReadinessCheck.screen.needsVisit)
    // No data from an older probe.
    #expect(cell("console=student\n").state == .unknown)
    // brak usługi → problem (fixable)
    let missing = report("console=student\nagent_installed=0\n")
    #expect(missing[.screen].state == .problem && missing[.screen].short == "brak usługi")
    #expect(missing.fixableBySetup.contains(.screen))
    // older → warning "v…" (fixable)
    let old = report("console=student\nagent_installed=1\nagent_version=0.9.1\n" + ping)
    #expect(old[.screen].state == .warning && old[.screen].short == "v0.9.1" && old.fixableBySetup.contains(.screen))
    // nobody logged in → unknown
    let nobody = cell("console=\nagent_installed=1\nagent_version=\(v)\n")
    #expect(nobody.state == .unknown && nobody.short == "nikt nie zalogowany")
    // not answering → warning (fixable); an impostor too
    let down = report("console=student\nagent_installed=1\nagent_version=\(v)\nagent_loaded=0\nagent_ping=ERR unreachable brak gniazda\nagent_ping_rc=10\n")
    #expect(down[.screen].state == .warning && down[.screen].short == "nie odpowiada" && down.fixableBySetup.contains(.screen))
    #expect(down[.screen].detail.contains("brak gniazda"))
    let impostor = cell("console=student\nagent_installed=1\nagent_version=\(v)\nagent_ping=ERR untrusted obcy proces\nagent_ping_rc=11\n")
    #expect(impostor.state == .warning && impostor.short == "niezaufana")
    // perm=denied → manual (visit)
    let denied = report("console=student\nagent_installed=1\nagent_version=\(v)\nagent_loaded=1\n"
        + ping.replacingOccurrences(of: "perm=granted", with: "perm=denied"))
    #expect(denied[.screen].state == .manual && denied[.screen].short == "nadaj uprawnienie")
    #expect(denied.needsVisit.contains(.screen) && !denied.fixableBySetup.contains(.screen))
    #expect(denied[.screen].detail.contains(ScreenAgentInfo.displayName))
    // perm=granted → ok
    let ready = cell("console=student\nagent_installed=1\nagent_version=\(v)\nagent_loaded=1\n" + ping)
    #expect(ready.state == .ok && ready.short == "gotowy" && !ready.detail.contains("Od macOS 15"))
    let locked = cell("console=student\nagent_installed=1\nagent_version=\(v)\n"
        + ping.replacingOccurrences(of: "locked=0", with: "locked=1"))
    #expect(locked.state == .ok && locked.detail.contains("zablokowany"))
    // A newer agent than this app still works.
    let newer = cell("console=student\nagent_installed=1\nagent_version=99.0.0\n" + ping)
    #expect(newer.state == .ok && newer.detail.contains("uaktualnij CMCR Manager"))
    // Without sudo the agent of another account cannot be asked.
    let nosudo = ReadinessReport.parse("os=14.7\nadmin=imac07\nconsole=student\nsudo=nopassword\nagent_installed=1\nagent_version=\(v)\n",
                                       student: "student", sharedFolder: "/Users/student/Public/cmcr")[.screen]
    #expect(nosudo.state == .unknown && nosudo.detail.contains("sudo"))
    // macOS 15+: the consent window of replayd is explained with the agent's name.
    let sequoia = ReadinessReport.parse("os=15.6\nadmin=imac07\nconsole=student\nsudo=ok\nagent_installed=1\nagent_version=\(v)\n" + ping
        + "screen_alert=ok\nscreen_alert_user=student\n", student: "student", sharedFolder: "/Users/student/Public/cmcr")[.screen]
    #expect(sequoia.state == .ok && sequoia.detail.contains("usługi podglądu do ekranu jest wyłączone"))
}

@Test func agentScriptsAreValidBashAndQuoteTheirValues() async {
    let awkward = ScriptCatalog.awkward
    let install = Scripts.installScreenAgent(remoteTar: "/tmp/\(awkward).tar")
    #expect(install.asRoot)
    #expect(install.body.contains("TAR=" + shQuote("/tmp/\(awkward).tar")))
    #expect(install.body.contains("tar -xf \"$TAR\" --no-same-owner"))
    #expect(Scripts.removeScreenAgent().asRoot && Scripts.requestScreenAgentPermission().asRoot)
    #expect(!Scripts.screenAgentStatus().asRoot, "the installed version is visible without sudo")
    let samples = ["installScreenAgent", "removeScreenAgent", "requestScreenAgentPermission", "screenAgentStatus"]
        .compactMap { name in ScriptCatalog.samples.first { $0.name == name } }
    #expect(samples.count == 4)
    let problems = await ScriptCatalog.syntaxCheck(samples)
    #expect(problems.isEmpty, "\(problems.map(\.description).joined(separator: "\n"))")
    // The LaunchAgent the install writes is exactly ScreenAgentInfo's, for the prefixed executable.
    #expect(Scripts.screenAgentPlistShell.contains("cmcr_agent_plist()"))
}
