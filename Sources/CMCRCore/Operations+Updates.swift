import Foundation

/// How long an update is followed once its session broke off (`Operations.installUpdates`, `Operations.followUpdate`).
public struct UpdateFollowPolicy: Sendable {
    /// The pause before each new connection; the last one repeats.
    public var delays: [TimeInterval]
    /// How long the Mac may stay out of reach – counted from the last session that reached it – before the app stops
    /// waiting. A macOS update installs while the Mac restarts, which takes 10–40 minutes on an iMac.
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
    /// Runs a script on the Mac (the first one with the retry policy of a job), streaming its output to `output`.
    var run: @Sendable (_ script: RemoteScript, _ first: Bool, _ output: Operations.Output?) async -> CommandResult
    /// Stops the update run with this id (`Scripts.stopUpdate`); never cancelled by the job's handle.
    var stop: @Sendable (_ runID: String) async -> CommandResult
}

/// Takes the `CMCR:SU-RUN <id>` line (`Scripts.updateRunMarker`) out of a script's stdout as it streams in and keeps the
/// id. The line starts a line of its own; a tail that could still become it is held back until more data arrives or
/// `finish()` hands it over.
final class UpdateRunMarkerFilter: @unchecked Sendable {
    private static let prefix = Data(Scripts.updateRunMarker.utf8)
    private let lock = NSLock()
    private var held = Data()
    private var atLineStart = true
    private var id: String?

    /// The id of the last marker seen.
    var runID: String? { lock.withLock { id } }

    func feed(_ data: Data) -> Data {
        lock.withLock {
            var buf = held
            buf.append(data)
            held = Data()
            var out = Data()
            var i = buf.startIndex
            while i < buf.endIndex {
                let newline = buf[i...].firstIndex(of: 0x0A)
                guard atLineStart else {
                    guard let newline else { out.append(buf[i...]); return out }
                    out.append(buf[i...newline])
                    i = newline + 1
                    atLineStart = true
                    continue
                }
                if let newline {
                    let line = buf[i..<newline]
                    if line.starts(with: Self.prefix) {
                        record(line)
                    } else {
                        out.append(buf[i...newline])
                    }
                    i = newline + 1
                    continue
                }
                let rest = buf[i...]
                let maybe = rest.count < Self.prefix.count ? Self.prefix.starts(with: rest) : rest.starts(with: Self.prefix)
                if maybe { held = Data(rest) } else { out.append(rest); atLineStart = false }
                return out
            }
            return out
        }
    }

    /// What is still held back: a marker cut off at the end is taken, anything else handed over.
    func finish() -> Data {
        lock.withLock {
            let rest = held
            held = Data()
            if rest.starts(with: Self.prefix) { record(rest); return Data() }
            return rest
        }
    }

    private func record(_ line: Data) {
        let text = String(decoding: line.dropFirst(Self.prefix.count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if RemoteJobs.isValidID(text) { id = text }
    }

    /// `data` without marker lines, and the last marker's id.
    static func strip(_ data: Data) -> (Data, String?) {
        let f = UpdateRunMarkerFilter()
        var out = f.feed(data)
        out.append(f.finish())
        return (out, f.runID)
    }
}

/// Calls an action once, from whichever path gets there first.
final class OnceAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    init(_ action: (@Sendable () -> Void)?) { self.action = action }
    func fire() {
        let a: (@Sendable () -> Void)? = lock.withLock { defer { action = nil }; return action }
        a?()
    }
}

public extension Operations {
    /// Installs (or downloads) macOS updates as a detached run on the Mac (`Scripts.installUpdates`) and follows it to
    /// its end. When the session breaks off under it – the master connection's keepalive on a network saturated by the
    /// downloads, Wi‑Fi, the admin's Mac asleep, the iMac restarting to install – softwareupdate goes on, and this
    /// connects again (with pauses, for up to `policy.giveUpAfter` since the Mac last answered) and follows the same run
    /// (`Scripts.followUpdate`): its progress, the restart and the system version after it. The run is the one the
    /// script names (`Scripts.updateRunMarker`): a new one, or one already going on the Mac that it joined. Cancelling
    /// `handle` („Przerwij”, Ctrl-C) stops that run on the Mac, also while it is being followed again.
    ///
    /// `launched` is called once, as soon as the run is going on the Mac (or the first session ended): a caller that
    /// limits how many installs start at a time releases its slot there, not when the install has finished.
    ///
    /// The result's stdout begins with the first session's (the `→ label` lines of what was installed).
    static func installUpdates(restart: Bool, recommendedOnly: Bool, downloadOnly: Bool, allowMajorUpgrade: Bool,
                               on host: Machine, password: String?, settings: SSHSettings,
                               handle: ProcessHandle? = nil, policy: UpdateFollowPolicy = .standard,
                               maxCapture: Int = ProcessRunner.defaultMaxCapture,
                               launched: (@Sendable () -> Void)? = nil,
                               onOutput: Output? = nil) async -> CommandResult {
        let run = RemoteJobs.newID()
        let script = Scripts.installUpdates(restart: restart, recommendedOnly: recommendedOnly, downloadOnly: downloadOnly,
                                            allowMajorUpgrade: allowMajorUpgrade, runID: run)
        return await installUpdates(script, run: run, policy: policy, handle: handle, launched: launched,
                                    onOutput: onOutput,
                                    remote: updateRemote(on: host, password: password, settings: settings, handle: handle,
                                                         maxCapture: maxCapture))
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
                                                maxCapture: maxCapture))
    }

    /// A started script ended by SIGTERM that this job did not send (the wrapper exits with 143): `cmcr_su_stop`, run by
    /// another job that joined this run and was stopped, ends the run's whole process group, this session included.
    static func stoppedFromElsewhere(_ r: CommandResult, handle: ProcessHandle?) -> Bool {
        r.started && !r.cancelled && !r.timedOut && handle?.isCancelled != true
            && (r.endCode == 143 || (r.endCode == nil && r.exitCode == 143))
    }

    /// A started script whose session broke off under it: ssh's 255 without the script's own end (see `SSH.diagnose`).
    /// The script may still be running on the Mac.
    static func sessionBrokeOff(_ r: CommandResult) -> Bool {
        r.started && !r.cancelled && !r.timedOut && r.exitCode == 255 && r.endCode != 255
    }

    internal static func updateRemote(on host: Machine, password: String?, settings: SSHSettings, handle: ProcessHandle?,
                                      maxCapture: Int) -> UpdateRemote {
        UpdateRemote(
            run: { script, first, output in
                await SSH.run(script, on: host, password: password, settings: settings, handle: handle,
                              retry: first ? .job : .transient, maxCapture: maxCapture, onOutput: output)
            },
            stop: { run in
                await SSH.run(Scripts.stopUpdate(runID: run), on: host, password: password, settings: settings,
                              timeout: OperationTimeout.cancel)
            })
    }

    /// Runs `script` with its run marker taken out of the output; returns the result (marker removed) and the run's id.
    internal static func runFollowingMarker(_ script: RemoteScript, first: Bool, remote: UpdateRemote,
                                            onLaunch: OnceAction? = nil,
                                            onOutput: Output?) async -> (CommandResult, String?) {
        let marker = UpdateRunMarkerFilter()
        let output: Output = { channel, data in
            guard channel == .stdout else { onOutput?(channel, data); return }
            let clean = marker.feed(data)
            if marker.runID != nil { onLaunch?.fire() }
            if !clean.isEmpty { onOutput?(channel, clean) }
        }
        var r = await remote.run(script, first, output)
        let rest = marker.finish()
        if !rest.isEmpty { onOutput?(.stdout, rest) }
        let (stdout, id) = UpdateRunMarkerFilter.strip(r.stdout)
        r.stdout = stdout
        return (r, marker.runID ?? id)
    }

    internal static func installUpdates(_ script: RemoteScript, run: String, policy: UpdateFollowPolicy,
                                        handle: ProcessHandle?, launched: (@Sendable () -> Void)? = nil,
                                        onOutput: Output?, remote: UpdateRemote) async -> CommandResult {
        let launch = OnceAction(launched)
        defer { launch.fire() }
        let (first, named) = await runFollowingMarker(script, first: true, remote: remote, onLaunch: launch,
                                                      onOutput: onOutput)
        launch.fire()
        if stoppedFromElsewhere(first, handle: handle) {
            // Another job's „Przerwij” stopped the run it joined – this one – together with this session: one more
            // look says so, instead of a bare „kod 143”.
            let (f, _) = await runFollowingMarker(Scripts.followUpdate(runID: named ?? run, replayLines: 1), first: false,
                                                  remote: remote, onOutput: onOutput)
            guard f.started, !f.cancelled else { return first }
            var r = f
            r.stdout = first.stdout + f.stdout
            return r
        }
        guard sessionBrokeOff(first) else { return first }
        onOutput?(.stderr, Data(("▸ Połączenie z komputerem zostało przerwane, ale instalacja trwa na nim dalej – "
                                 + "łączę się ponownie, aby śledzić jej postęp…\n").utf8))
        // The run the script named: a run already going that it joined has an id of its own. Broken off before the
        // script named one, it can only be ours.
        var r = await followUpdate(run: named ?? run, attached: true, stopOnCancel: true, policy: policy, handle: handle,
                                   onOutput: onOutput, remote: remote)
        r.stdout = first.stdout + r.stdout
        return r
    }

    /// Follows run `run` (nil: the Mac's last one) over new sessions until one reports how it ended. `attached`: the
    /// run is known to be going on the Mac (its session broke off), so a Mac out of reach is waited for – it is most
    /// likely restarting to install – for up to `policy.giveUpAfter` since a session last reached it. Otherwise a Mac
    /// that cannot be reached is reported at once.
    internal static func followUpdate(run: String?, attached: Bool, stopOnCancel: Bool, policy: UpdateFollowPolicy,
                                      handle: ProcessHandle?, onOutput: Output?,
                                      remote: UpdateRemote) async -> CommandResult {
        let clock = ContinuousClock()
        var lastContact = clock.now
        var run = run
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
            let (r, named) = await runFollowingMarker(Scripts.followUpdate(runID: run, replayLines: attached ? 3 : nil),
                                                      first: false, remote: remote, onOutput: onOutput)
            if let named { run = named }
            if r.cancelled || handle?.isCancelled == true { return await cancelled() }
            if r.started { lastContact = clock.now }
            if sessionBrokeOff(r) {
                // Most often the Mac going down to install the update.
                attached = true; attempt = 0; saidUnreachable = false
                onOutput?(.stderr, Data(("▸ Połączenie znów przerwane – komputer zapewne uruchamia się ponownie, aby "
                                         + "zainstalować aktualizację. Czekam na niego…\n").utf8))
                continue
            }
            if r.started { return r }
            guard attached, !refusedForGood(r) else { return r }
            let silent = lastContact.duration(to: clock.now)
            if silent >= .seconds(policy.giveUpAfter) {
                return .failure("Komputer nie odpowiada od \(Int(silent.components.seconds / 60)) min – nie wiadomo, jak "
                                + "skończyła się instalacja. Sprawdź później: Aktualizacje › Stan instalacji "
                                + "(cmcrctl updates status).", code: 255)
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
