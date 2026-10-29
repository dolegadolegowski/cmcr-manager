import CMCRCore
import Foundation

/// Ctrl-C (SIGINT) and SIGTERM while commands run on the iMacs (AUDIT ZAD-13). Like „Przerwij” in the app, an
/// interrupted cmcrctl stops the command on every iMac too, waits until that is done and ends with 128 + signal
/// (130 for Ctrl-C). Every remote command runs as a registered job (job id, output relays), so a connection lost
/// to a sleeping MacBook no longer kills it either – as in the app.
///
/// The handlers are installed with the first job: before that (questions, read-only commands) Ctrl-C works as
/// it always did. A second Ctrl-C ends cmcrctl at once.
final class Interruption: @unchecked Sendable {
    static let shared = Interruption()

    /// One running remote job.
    final class Job: @unchecked Sendable {
        let handle = ProcessHandle()
        let id = RemoteJobs.newID()
        let host: Machine
        let password: String?
        let settings: SSHSettings

        init(host: Machine, password: String?, settings: SSHSettings) {
            self.host = host
            self.password = password
            self.settings = settings
        }
    }

    private let lock = NSLock()
    private var installed = false
    private var sources: [DispatchSourceSignal] = []
    private var active: [ObjectIdentifier: Job] = [:]
    private var signalNumber: Int32?

    private var interruptedBy: Int32? { lock.withLock { signalNumber } }

    /// Runs `script` on `host` as a job that an interruption stops on the iMac as well.
    func run(_ script: RemoteScript, on host: Machine, password: String?, settings: SSHSettings,
             timeout: TimeInterval? = nil, onOutput: (@Sendable (OutputChannel, Data) -> Void)?) async -> CommandResult {
        let job = Job(host: host, password: password, settings: settings)
        await begin(job)
        var script = script
        script.jobID = job.id
        let r = await SSH.run(script, on: host, password: password, settings: settings, timeout: timeout,
                              handle: job.handle, onOutput: onOutput)
        await finish(job, r, onOutput: onOutput)
        return r
    }

    private func begin(_ job: Job) async {
        let stop: Int32? = lock.withLock {
            if !installed {
                installed = true
                for sig in [SIGINT, SIGTERM] {
                    signal(sig, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                    source.setEventHandler { [unowned self] in self.received(sig) }
                    source.resume()
                    sources.append(source)
                }
            }
            if signalNumber == nil { active[ObjectIdentifier(job)] = job }
            return signalNumber
        }
        // Interrupted while another Mac was being stopped: nothing new starts.
        if let stop { await exitWhenStopped(stop) }
    }

    private func finish(_ job: Job, _ r: CommandResult, onOutput: (@Sendable (OutputChannel, Data) -> Void)?) async {
        // ssh got the terminal's SIGINT too and may end before the handle is cancelled: then the job (which survives
        // a lost connection) is stopped here. A just-ended ssh waits a moment for a signal still on its way.
        var stop = interruptedBy
        if stop == nil, r.started, !r.cancelled, [255, SIGINT, SIGTERM].contains(r.exitCode) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            stop = interruptedBy
        }
        if stop != nil, r.started, !r.cancelled {
            let outcome = await SSH.cancelRemote(jobID: job.id, on: job.host, password: job.password, settings: job.settings)
            onOutput?(.stderr, Data("▸ \(outcome.message)\n".utf8))
        }
        await job.handle.cancellationFinished()
        lock.withLock { _ = active.removeValue(forKey: ObjectIdentifier(job)) }
        if let stop { await exitWhenStopped(stop) }
    }

    private func received(_ sig: Int32) {
        let jobs: [Job]? = lock.withLock {
            if signalNumber != nil { return nil }
            signalNumber = sig
            return Array(active.values)
        }
        guard let jobs else { exit(128 + sig) }   // the second Ctrl-C
        guard !jobs.isEmpty else { exit(128 + sig) }
        Console.err("\n▸ Przerywanie – zatrzymywanie polecenia na komputerach (\(jobs.map(\.host.name).joined(separator: ", ")))… "
                    + "Ponowne Ctrl-C kończy od razu.")
        jobs.forEach { $0.handle.cancel() }
    }

    /// Ends cmcrctl once no job is running any more (each one finishes stopping its own command).
    private func exitWhenStopped(_ sig: Int32) async {
        if lock.withLock({ active.isEmpty }) { exit(128 + sig) }
        // Another job is still stopping its command: it ends the process when it is done.
        while true { try? await Task.sleep(nanoseconds: 1_000_000_000) }
    }
}
