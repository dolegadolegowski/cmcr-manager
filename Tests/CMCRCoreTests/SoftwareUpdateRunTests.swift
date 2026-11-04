import Foundation
import Testing
@testable import CMCRCore

/// macOS updates as a detached run on the iMac (Scripts+Updates.swift) and how the app follows it again after a lost
/// connection (Operations+Updates.swift). The real ssh transport is covered by Tests/e2e/suites/updates-detached.sh.
@Suite struct SoftwareUpdateRunTests {

    // MARK: - Remote scripts

    @Test func theInstallRunsDetachedFromTheSessionAndFollowsItsLog() {
        let body = Scripts.installUpdates(restart: true, recommendedOnly: false, downloadOnly: false, runID: "abc-123").body
        // softwareupdate's output goes only to the log: a lost connection or a stalled relay cannot reach it.
        #expect(body.contains(#"cmcr_su_runner </dev/null >>"$CMCR_SU_LOG" 2>&1 &"#))
        #expect(body.contains("RUN='abc-123'"))
        let launch = body.range(of: "cmcr_su_runner </dev/null")!.lowerBound
        #expect(body.range(of: #"cmcr_su_follow "$RUN""#)!.lowerBound > launch)
        // A run still going is followed instead of starting a second softwareupdate.
        #expect(body.range(of: "if cmcr_su_active; then")!.lowerBound < launch)
        #expect(Scripts.installUpdates(restart: true, recommendedOnly: false, downloadOnly: false).asRoot)
    }

    @Test func anUnsafeRunIDIsReplaced() {
        let body = Scripts.installUpdates(restart: false, recommendedOnly: false, downloadOnly: false,
                                          runID: "x'; rm -rf / #").body
        #expect(!body.contains("rm -rf /"))
        #expect(Scripts.stopUpdate(runID: "a'b").body.contains("RUN='-'"))
        #expect(!Scripts.followUpdate(runID: "a b").body.contains("'a b'"))
    }

    @Test func appleSiliconAuthenticatesAsAVolumeOwnerAndChecksItBeforeDownloading() {
        let body = Scripts.installUpdates(restart: true, recommendedOnly: false, downloadOnly: false).body
        #expect(body.contains(#"softwareupdate "${ARGS[@]}" --user "$CMCR_ADMIN_USER" --stdinpass"#))
        // Not a volume owner: stopped before a download of several GB that would end in a refusal.
        let check = body.range(of: #"if [ "$(cmcr_su_volume_owner)" = "No" ]; then"#)!.lowerBound
        #expect(check < body.range(of: #"softwareupdate "${ARGS[@]}" --user"#)!.lowerBound)
        #expect(body.contains("Nic nie pobrano"))
        #expect(body.contains("sysadminctl -secureTokenOn"))
    }

    @Test func failuresSayWhatToDoInTheirLastLine() {
        let body = Scripts.updateInstallFunctions
        #expect(body.contains("*\"Failed to queue update and restart\"*)"))
        // The system log holds the real reason ("Queue for post-logout failed: …").
        #expect(body.contains("log show --last 30m"))
        #expect(body.contains("post-logout"))
        // A restart that does not come is reported with what holds it back (a logged-in user).
        #expect(Scripts.updateRunFunctions.contains("Aktualizacja czeka na wylogowanie"))
        #expect(Scripts.updateRunFunctions.contains("return \(Scripts.updateNotRestartedCode)"))
    }

    @Test func followingNeedsNoRootAndStoppingKillsTheRunsProcessGroup() {
        #expect(!Scripts.followUpdate().asRoot)
        let stop = Scripts.stopUpdate(runID: "abc")
        #expect(stop.asRoot)
        #expect(stop.body.contains(#"kill -TERM -- "-$G""#))
        #expect(stop.body.contains("phase=cancelled"))
    }

    /// `cmcr_ver_newer` decides which macOS version is installed when several are offered.
    @Test(arguments: [("27.10", "27.9", true), ("27.9", "27.10", false), ("27.2", "27.2", false), ("26.1", "15.7.2", true),
                      ("26.1.1", "26.1", true), ("26.1 (a)", "26.1", false), ("27.0", "26.7.1", true)])
    func versionsAreComparedNumerically(_ a: String, _ b: String, _ newer: Bool) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["--noprofile", "--norc", "-c", Scripts.updateInstallFunctions + "\ncmcr_ver_newer \"$1\" \"$2\"", "x", a, b]
        try p.run()
        p.waitUntilExit()
        #expect((p.terminationStatus == 0) == newer)
    }

    // MARK: - Following again after a lost connection

    /// A scripted remote side: the results for the sessions in order, and what was asked.
    final class FakeRemote: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [CommandResult]
        private(set) var scripts: [String] = []
        private(set) var stopped: [String] = []
        let handle: ProcessHandle?
        /// Cancels `handle` when the session with this index (0 = the install) is asked for.
        var cancelAt: Int?

        init(_ results: [CommandResult], handle: ProcessHandle? = nil) {
            self.results = results
            self.handle = handle
        }

        var remote: UpdateRemote {
            UpdateRemote(
                run: { [self] script, _ in
                    let (r, index): (CommandResult, Int) = lock.withLock {
                        scripts.append(script.body)
                        return (results.isEmpty ? .failure("nic więcej", code: 99) : results.removeFirst(), scripts.count - 1)
                    }
                    if index == cancelAt { handle?.cancel(); return .cancelledResult }
                    return r
                },
                stop: { [self] run in
                    lock.withLock { stopped.append(run) }
                    return CommandResult(exitCode: 0, stdout: Data("▸ Zatrzymano instalację aktualizacji na komputerze.\n".utf8),
                                         started: true, endCode: 0)
                })
        }
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
        var output: Operations.Output { { [self] _, d in lock.withLock { data.append(d) } } }
    }

    static let fast = UpdateFollowPolicy(delays: [0], giveUpAfter: 60)
    static func broken(_ out: String = "") -> CommandResult {
        CommandResult(exitCode: 255, stdout: Data(out.utf8), started: true)
    }
    static func ended(_ code: Int32, _ out: String) -> CommandResult {
        CommandResult(exitCode: code, stdout: Data(out.utf8), started: true, endCode: code)
    }
    static let offline = CommandResult(exitCode: 255, stderr: Data("ssh: connect to host imac02 port 22: Operation timed out\n".utf8))
    static let refusedKey = CommandResult(exitCode: 255,
                                          stderr: Data("Permission denied (publickey,password,keyboard-interactive).\n".utf8))
    static let script = Scripts.installUpdates(restart: true, recommendedOnly: false, downloadOnly: false, runID: "run-1")

    @Test func aSessionThatEndedByItselfIsTheResult() async {
        let fake = FakeRemote([Self.ended(1, "→ macOS 27.2-26C1\nFailed to queue update and restart.\n")])
        let r = await Operations.installUpdates(Self.script, run: "run-1", policy: Self.fast, handle: nil, onOutput: nil,
                                                remote: fake.remote)
        #expect(r.exitCode == 1)
        #expect(fake.scripts.count == 1)
    }

    @Test func aBrokenSessionIsFollowedAgainUntilTheRunEnds() async {
        let out = Collected()
        let fake = FakeRemote([Self.broken("→ macOS 27.2-26C1\nDownloading: 41.15%\n"), Self.offline, Self.offline,
                               Self.broken("Done.\n"), Self.offline,
                               Self.ended(0, "✔ Komputer uruchomił się ponownie z nowym systemem: macOS 27.2 (26C1)\n")])
        let r = await Operations.installUpdates(Self.script, run: "run-1", policy: Self.fast, handle: nil,
                                                onOutput: out.output, remote: fake.remote)
        #expect(r.succeeded)
        // What the first session printed stays first: the app takes the installed labels off its list.
        #expect(r.stdoutText.hasPrefix("→ macOS 27.2-26C1\n"))
        #expect(r.stdoutText.contains("nowym systemem"))
        #expect(fake.scripts.count == 6)
        // The same run is followed, not a new one started.
        #expect(fake.scripts.dropFirst().allSatisfy { $0.contains("RUN='run-1'") && !$0.contains("cmcr_su_runner <") })
        #expect(out.text.contains("instalacja trwa na nim dalej"))
        #expect(out.text.contains("komputer zapewne uruchamia się ponownie"))
        // „Komputer nie odpowiada” once per outage, not for every attempt.
        #expect(out.text.components(separatedBy: "Komputer nie odpowiada").count == 3)
    }

    @Test func aMacOutOfReachForTooLongEndsTheFollowing() async {
        let fake = FakeRemote([Self.broken(), Self.offline, Self.offline, Self.offline])
        let r = await Operations.installUpdates(Self.script, run: "run-1",
                                                policy: UpdateFollowPolicy(delays: [0.05], giveUpAfter: 0.08),
                                                handle: nil, onOutput: nil, remote: fake.remote)
        #expect(!r.succeeded)
        #expect(SSH.diagnose(r).1.contains("nie wiadomo, jak skończyła się instalacja"))
        #expect(SSH.diagnose(r).1.contains("Stan instalacji"))
    }

    @Test func aRefusedLoginIsNotWaitedFor() async {
        let fake = FakeRemote([Self.broken(), Self.refusedKey, Self.ended(0, "")])
        let r = await Operations.installUpdates(Self.script, run: "run-1", policy: Self.fast, handle: nil, onOutput: nil,
                                                remote: fake.remote)
        #expect(SSH.diagnose(r).0 == .authFailed)
        #expect(fake.scripts.count == 2)
    }

    @Test func cancellingWhileFollowingStopsTheUpdateOnTheMac() async {
        let handle = ProcessHandle()
        let out = Collected()
        let fake = FakeRemote([Self.broken(), Self.offline, Self.ended(0, "")], handle: handle)
        fake.cancelAt = 2
        let r = await Operations.installUpdates(Self.script, run: "run-1", policy: Self.fast, handle: handle,
                                                onOutput: out.output, remote: fake.remote)
        #expect(r.cancelled)
        #expect(fake.stopped == ["run-1"])
        #expect(out.text.contains("Zatrzymano instalację aktualizacji na komputerze."))
    }

    @Test func theStatusOnlyWatches() async {
        let handle = ProcessHandle()
        let fake = FakeRemote([Self.broken(), Self.ended(0, "")], handle: handle)
        fake.cancelAt = 1
        let r = await Operations.followUpdate(run: nil, attached: false, stopOnCancel: false, policy: Self.fast,
                                              handle: handle, onOutput: nil, remote: fake.remote)
        #expect(r.cancelled)
        #expect(fake.stopped.isEmpty)
    }

    @Test func theStatusOfAMacThatIsOffIsReportedAtOnce() async {
        let fake = FakeRemote([Self.offline, Self.ended(0, "")])
        let r = await Operations.followUpdate(run: nil, attached: false, stopOnCancel: false, policy: Self.fast,
                                              handle: nil, onOutput: nil, remote: fake.remote)
        #expect(SSH.diagnose(r).0 == .offline)
        #expect(fake.scripts.count == 1)
    }

    @Test func onlyABrokenSessionOfAStartedScriptCountsAsBroken() {
        #expect(Operations.sessionBrokeOff(Self.broken()))
        #expect(!Operations.sessionBrokeOff(Self.ended(255, "")))      // the script's own 255
        #expect(!Operations.sessionBrokeOff(Self.offline))              // never started
        #expect(!Operations.sessionBrokeOff(.cancelledResult))
    }
}
