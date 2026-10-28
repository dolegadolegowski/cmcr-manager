import Foundation
import Testing
@testable import CMCRCore

/// P2 audit fixes in the remote scripts, run locally as sshd would (`/bin/sh -c remoteCommand()`), without ssh.
/// The fakes are shell functions loaded through BASH_ENV, so every bash (also the root re-exec) sees them:
/// `sudo` runs the command as the current user, `kill` signals only PIDs listed in `kill.allow`, and the
/// console user is the account running the tests. `guardFakes()` checks them before any script runs.
@Suite struct P2ScriptsTests {
    struct Box {
        let dir: URL
        var log: URL { dir.appendingPathComponent("log") }

        init(extraFakes: String = "", exports: [String] = []) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-p2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fakes = #"""
            _p2_log() { printf '%s\n' "$*" >> "$P2_DIR/log"; }
            sudo() {
              while [ $# -gt 0 ]; do
                case "$1" in -A|-n|-k|-H) shift ;; -u|-g|-p|-C|-h) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac
              done
              [ $# -eq 0 ] && return 0
              _p2_log "sudo $*"
              SUDO_USER="$(id -un)" "$@"
            }
            stat() {
              if [ "$*" = "-f%Su /dev/console" ]; then id -un; return 0; fi
              command stat "$@"
            }
            kill() {
              local a
              for a in "$@"; do
                case "$a" in
                  -*) ;;
                  *) grep -qx -- "$a" "$P2_DIR/kill.allow" 2>/dev/null || { _p2_log "kill-blocked $*"; return 1; } ;;
                esac
              done
              _p2_log "kill $*"
              builtin kill "$@"
            }
            """# + "\n" + extraFakes + "\n" + "export -f _p2_log sudo stat kill " + exports.joined(separator: " ") + "\n"
            try fakes.write(to: dir.appendingPathComponent("fakes.sh"), atomically: true, encoding: .utf8)
        }

        var environment: [String: String] {
            ["BASH_ENV": dir.appendingPathComponent("fakes.sh").path, "P2_DIR": dir.path]
        }

        func guardFakes() async -> Bool {
            let r = await ProcessRunner.run("/bin/bash", ["--noprofile", "--norc", "-c",
                                                          #"type -t sudo kill; /bin/bash --noprofile --norc -c 'type -t sudo kill'"#],
                                            environment: environment)
            return r.stdoutText == "function\nfunction\nfunction\nfunction\n"
        }

        func run(_ script: RemoteScript) async -> CommandResult {
            await ProcessRunner.run("/bin/sh", ["-c", script.remoteCommand()], environment: environment,
                                    stdin: Data("haslo\n".utf8), timeout: 60)
        }

        func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        func allowKill(_ pid: Int32) throws {
            try "\(pid)\n".write(to: dir.appendingPathComponent("kill.allow"), atomically: true, encoding: .utf8)
        }
        func touch(_ name: String) { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil) }
        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    /// A process that sleeps until killed, started from `executable`.
    static func start(_ executable: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["300"]
        try p.run()
        return p
    }

    static func waitForExit(_ p: Process, seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        return !p.isRunning
    }

    // MARK: - APL-06: killing by PID

    /// A PID from a stale list (or `cmcrctl kill PID all`) may now belong to another account: as root it must not
    /// be signalled. PID 1 is launchd (root); the fake `kill` refuses it anyway, the log shows any attempt.
    @Test func killProcessRefusesAProcessOfAnotherAccount() async throws {
        let box = try Box()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapy nieaktywne – test przerwany")
        let r = await box.run(Scripts.killProcess(1, force: true))
        #expect(r.exitCode == 1)
        #expect(r.stderrText.contains("Odmowa"), "\(r.stderrText)")
        #expect(!box.logText().contains("kill"), "\(box.logText())")
    }

    @Test func killProcessRefusesAnotherProgramUnderTheSamePID() async throws {
        let box = try Box()
        defer { box.remove() }
        try #require(await box.guardFakes())
        let p = try Self.start("/bin/sleep")
        defer { p.terminate() }
        try box.allowKill(p.processIdentifier)
        let r = await box.run(Scripts.killProcess(Int(p.processIdentifier), force: true, bundlePath: "/Applications/Safari.app"))
        #expect(r.exitCode == 1)
        #expect(r.stderrText.contains("Odmowa"), "\(r.stderrText)")
        #expect(p.isRunning, "proces innego programu zakończony")
        #expect(!box.logText().contains("kill -KILL"))
    }

    @Test func killProcessEndsTheListedApp() async throws {
        let box = try Box()
        defer { box.remove() }
        try #require(await box.guardFakes())
        let app = box.dir.appendingPathComponent("P2 Test.app")
        let exe = app.appendingPathComponent("Contents/MacOS/P2Test")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: exe.path)
        _ = await ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", "-", exe.path])
        let p = try Self.start(exe.path)
        defer { if p.isRunning { p.terminate() } }
        try box.allowKill(p.processIdentifier)
        let r = await box.run(Scripts.killProcess(Int(p.processIdentifier), force: true, bundlePath: app.path))
        #expect(r.exitCode == 0, "\(r.stderrText)")
        #expect(await Self.waitForExit(p), "aplikacja nadal działa")
        #expect(box.logText().contains("sudo kill -KILL \(p.processIdentifier)"))
    }

    // MARK: - APL-07: the list of installed apps

    /// /Applications/Safari.app is a link into the system cryptex since macOS 13: the list shows where the app really
    /// is, so the app does not offer to uninstall it from /Applications.
    @Test func installedAppsShowLinkedAppsWhereTheyAre() async throws {
        let link = "/Applications/Safari.app"
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return }
        let box = try Box()
        defer { box.remove() }
        try #require(await box.guardFakes())
        let r = await box.run(Scripts.installedApps())
        let lines = Parsers.lines(r.stdoutText)
        #expect(r.exitCode == 0)
        #expect(!lines.contains(link), "dowiązanie na liście jako aplikacja z /Applications")
        let real = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: "/Applications")).resolvingSymlinksInPath().path
        #expect(lines.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == real }, "\(lines.filter { $0.contains("Safari") })")
        #expect(Set(lines).count == lines.count, "powtórzone wpisy")
    }
}
