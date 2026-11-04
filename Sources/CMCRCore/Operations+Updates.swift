import Foundation

/// How long an update is followed once its session broke off (`Operations.installUpdates`, `Operations.followUpdate`).
public struct UpdateFollowPolicy: Sendable {
    /// The pause before each new connection; the last one repeats.
    public var delays: [TimeInterval]
    /// How long the Mac may stay out of reach before the app stops waiting. A macOS update installs while the Mac
    /// restarts, which takes 10–40 minutes on an iMac.
    public var giveUpAfter: TimeInterval

    public init(delays: [TimeInterval], giveUpAfter: TimeInterval) {
        self.delays = delays
        self.giveUpAfter = giveUpAfter
    }

    public static let standard = UpdateFollowPolicy(delays: [5, 15, 30], giveUpAfter: 75 * 60)

    func delay(_ attempt: Int) -> TimeInterval {
        delays.isEmpty ? 0 : max(0, delays[min(attempt, delays.count - 1)])
    }
}

/// The sessions an update needs, replaceable in the tests.
struct UpdateRemote: Sendable {
    /// Runs a script on the Mac (the first one with the retry policy of a job).
    var run: @Sendable (_ script: RemoteScript, _ first: Bool) async -> CommandResult
    /// Stops the update run with this id (`Scripts.stopUpdate`); never cancelled by the job's handle.
    var stop: @Sendable (_ runID: String) async -> CommandResult
}

public extension Operations {
    /// Installs (or downloads) macOS updates as a detached run on the Mac (`Scripts.installUpdates`) and follows it to
    /// its end. When the session breaks off under it – the master connection's keepalive on a network saturated by the
    /// downloads, Wi‑Fi, the admin's Mac asleep, the iMac restarting to install – softwareupdate goes on, and this
    /// connects again (with pauses, for up to `policy.giveUpAfter` while the Mac is out of reach) and follows the same
    /// run (`Scripts.followUpdate`): its progress, the restart and the system version after it. Cancelling `handle`
    /// („Przerwij”, Ctrl-C) stops the update on the Mac, also while it is being followed again.
    ///
    /// The result's stdout begins with the first session's (the `→ label` lines of what was installed).
    static func installUpdates(restart: Bool, recommendedOnly: Bool, downloadOnly: Bool, allowMajorUpgrade: Bool,
                               on host: Machine, password: String?, settings: SSHSettings,
                               handle: ProcessHandle? = nil, policy: UpdateFollowPolicy = .standard,
                               maxCapture: Int = ProcessRunner.defaultMaxCapture,
                               onOutput: Output? = nil) async -> CommandResult {
        let run = RemoteJobs.newID()
        let script = Scripts.installUpdates(restart: restart, recommendedOnly: recommendedOnly, downloadOnly: downloadOnly,
                                            allowMajorUpgrade: allowMajorUpgrade, runID: run)
        return await installUpdates(script, run: run, policy: policy, handle: handle, onOutput: onOutput,
                                    remote: updateRemote(on: host, password: password, settings: settings, handle: handle,
                                                         maxCapture: maxCapture, onOutput: onOutput))
    }

    /// „Stan instalacji”: the last update run CMCR Manager started on the Mac – what it installs, its log, how it ended –
    /// followed while it runs, also across a restart of the Mac. Cancelling `handle` stops only the watching. A Mac
    /// that cannot be reached at first is reported at once (it may simply be off).
    static func followUpdate(on host: Machine, password: String?, settings: SSHSettings, handle: ProcessHandle? = nil,
                             policy: UpdateFollowPolicy = .standard, maxCapture: Int = ProcessRunner.defaultMaxCapture,
                             onOutput: Output? = nil) async -> CommandResult {
        await followUpdate(run: nil, attached: false, stopOnCancel: false, policy: policy, handle: handle,
                           onOutput: onOutput,
                           remote: updateRemote(on: host, password: password, settings: settings, handle: handle,
                                                maxCapture: maxCapture, onOutput: onOutput))
    }

    /// A started script whose session broke off under it: ssh's 255 without the script's own end (see `SSH.diagnose`).
    /// The script may still be running on the Mac.
    static func sessionBrokeOff(_ r: CommandResult) -> Bool {
        r.started && !r.cancelled && !r.timedOut && r.exitCode == 255 && r.endCode != 255
    }

    internal static func updateRemote(on host: Machine, password: String?, settings: SSHSettings, handle: ProcessHandle?,
                             maxCapture: Int, onOutput: Output?) -> UpdateRemote {
        UpdateRemote(
            run: { script, first in
                await SSH.run(script, on: host, password: password, settings: settings, handle: handle,
                              retry: first ? .job : .transient, maxCapture: maxCapture, onOutput: onOutput)
            },
            stop: { run in
                await SSH.run(Scripts.stopUpdate(runID: run), on: host, password: password, settings: settings,
                              timeout: OperationTimeout.cancel)
            })
    }

    internal static func installUpdates(_ script: RemoteScript, run: String, policy: UpdateFollowPolicy,
                                        handle: ProcessHandle?, onOutput: Output?,
                                        remote: UpdateRemote) async -> CommandResult {
        let first = await remote.run(script, true)
        guard sessionBrokeOff(first) else { return first }
        onOutput?(.stderr, Data(("▸ Połączenie z komputerem zostało przerwane, ale instalacja trwa na nim dalej – "
                                 + "łączę się ponownie, aby śledzić jej postęp…\n").utf8))
        var r = await followUpdate(run: run, attached: true, stopOnCancel: true, policy: policy, handle: handle,
                                   onOutput: onOutput, remote: remote)
        r.stdout = first.stdout + r.stdout
        return r
    }

    /// Follows run `run` (nil: the Mac's last one) over new sessions until one reports how it ended. `attached`: the
    /// run is known to be going on the Mac (its session broke off), so a Mac out of reach is waited for – it is most
    /// likely restarting to install. Otherwise a Mac that cannot be reached is reported at once.
    internal static func followUpdate(run: String?, attached: Bool, stopOnCancel: Bool, policy: UpdateFollowPolicy,
                                      handle: ProcessHandle?, onOutput: Output?,
                                      remote: UpdateRemote) async -> CommandResult {
        let began = Date()
        var attempt = 0, waitFirst = attached, attached = attached, saidUnreachable = false
        func cancelled() async -> CommandResult {
            guard stopOnCancel, let run else { return .cancelledResult }
            let s = await remote.stop(run)
            let said = (s.stdoutText + s.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
            let note = s.started && !said.isEmpty ? said
                : "▸ Nie udało się połączyć, aby zatrzymać polecenie – instalacja może nadal trwać na komputerze "
                    + "(\(SSH.diagnose(s).1))."
            onOutput?(.stderr, Data((note + "\n").utf8))
            var r = CommandResult.cancelledResult
            r.stderr = Data((note + "\nAnulowano.\n").utf8)
            return r
        }
        while true {
            if waitFirst {
                guard await pause(policy.delay(attempt), handle: handle) else { return await cancelled() }
                attempt += 1
            }
            waitFirst = true
            if handle?.isCancelled == true || Task.isCancelled { return await cancelled() }
            let r = await remote.run(Scripts.followUpdate(runID: run, replayLines: attached ? 3 : nil), false)
            if r.cancelled || handle?.isCancelled == true { return await cancelled() }
            if sessionBrokeOff(r) {
                // Most often the Mac going down to install the update.
                attached = true; attempt = 0; saidUnreachable = false
                onOutput?(.stderr, Data(("▸ Połączenie znów przerwane – komputer zapewne uruchamia się ponownie, aby "
                                         + "zainstalować aktualizację. Czekam na niego…\n").utf8))
                continue
            }
            if r.started { return r }
            guard attached, !refusedForGood(r) else { return r }
            let waited = Date().timeIntervalSince(began)
            if waited >= policy.giveUpAfter {
                return .failure("Komputer nie odpowiada od \(Int(waited / 60)) min – nie wiadomo, jak skończyła się "
                                + "instalacja. Sprawdź później: Aktualizacje › Stan instalacji (cmcrctl updates status).",
                                code: 255)
            }
            if !saidUnreachable {
                saidUnreachable = true
                let every = Int(policy.delay(policy.delays.count))
                var why = SSH.diagnose(r).1
                if why.hasSuffix(".") { why.removeLast() }
                onOutput?(.stderr, Data(("▸ \(why) – zapewne instaluje aktualizację i uruchamia się ponownie. "
                                         + "Ponawiam co \(every) s, najdłużej \(Int(policy.giveUpAfter / 60)) min…\n").utf8))
            }
        }
    }

    /// A failure that waiting will not cure: an untrusted or changed host key, a refused login, a broken host entry.
    internal static func refusedForGood(_ r: CommandResult) -> Bool {
        if r.stderrText.hasPrefix(SSH.refusalPrefix) || HostTrust.refusal(r) != nil { return true }
        return SSH.diagnose(r).0 == .authFailed
    }

    /// Sleeps `seconds`; false once `handle` or the task is cancelled.
    internal static func pause(_ seconds: TimeInterval, handle: ProcessHandle?) async -> Bool {
        var left = seconds
        while left > 0 {
            if handle?.isCancelled == true || Task.isCancelled { return false }
            let step = min(left, 0.25)
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            left -= step
        }
        return handle?.isCancelled != true && !Task.isCancelled
    }
}
