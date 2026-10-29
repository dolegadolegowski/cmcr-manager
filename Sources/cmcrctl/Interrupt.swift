import CMCRCore
import Foundation

/// Ctrl-C (SIGINT) and SIGTERM while commands run on the iMacs (AUDIT ZAD-13). Like „Przerwij” in the app, an
/// interrupted cmcrctl stops the command on every iMac too, waits until that is done and ends with 128 + signal
/// (130 for Ctrl-C).
///
/// Every command that changes something on the iMacs runs its remote work as a registered job (AUDIT REV-36) – `run`
/// for one script, `job` for the file, install and lesson operations that take a ProcessHandle: exec, push, pull,
/// clean, open-app, quit-app, open-url, kill, uninstall, brew, updates install, message, logout, power, install,
/// install-url, mkdir, rm, rename, get, collect, lock, unlock, ask, schedule set/clear, power-later, power-cancel,
/// rename-computer, lesson and setup (and `ls ŚCIEŻKA KOMP` and updates history, which share runScript). Their
/// scripts get a job id and output relays, so a connection lost to a sleeping MacBook no longer kills them either –
/// as in the app. Commands that only read (status, updates list, readiness, filevault, app-version, schedule show,
/// exists, `ls nr`, apps, screenshot, screen-watch, report, wake) are not jobs: Ctrl-C ends them at once.
///
/// Nothing exits from inside a job (AUDIT REV-35): the interrupted jobs return their cancelled results, so every
/// host's output – with how the stop went („▸ Zatrzymano polecenie na komputerze.”, or why it may still run there)
/// and its „✘ … Anulowano.” line – is printed in list order, also the output of hosts buffered while another one was
/// shown (-j N). Hosts not started yet are not started and are listed. main.swift then ends with `exitCode`.
///
/// The handlers are installed with the first job: before that (questions, read-only commands) Ctrl-C works as
/// it always did, and so it does while no job runs (e.g. the pause between the steps of a lesson). A second Ctrl-C
/// ends cmcrctl at once.
///
/// `install` and `lesson start` pack their files before anything runs on the iMacs: that packing is a job without a
/// Mac (`pack`, AUDIT REV-44), so Ctrl-C stops tar and its archive is removed, and nothing is started afterwards.
final class Interruption: @unchecked Sendable {
    static let shared = Interruption()

    /// One running job: everything it starts for its Mac takes `handle`.
    private final class Job: @unchecked Sendable {
        let handle = ProcessHandle()
        /// nil: local work before anything runs on the iMacs (`pack`).
        let host: Machine?
        let order: Int

        init(host: Machine?, order: Int) {
            self.host = host
            self.order = order
        }
    }

    private let lock = NSLock()
    private var installed = false
    private var sources: [DispatchSourceSignal] = []
    private var active: [ObjectIdentifier: Job] = [:]
    private var started = 0
    private var signalNumber: Int32?
    /// Archives made by `pack` and not yet discarded: removed also when cmcrctl ends at once.
    private var archives: Set<URL> = []

    /// The signal that interrupted cmcrctl; nil while it was not interrupted.
    var interruptedBy: Int32? { lock.withLock { signalNumber } }
    var isInterrupted: Bool { interruptedBy != nil }

    /// The exit status for a command that returned `code`: 128 + signal once it was interrupted.
    func exitCode(_ code: Int32) -> Int32 { interruptedBy.map { 128 + $0 } ?? code }

    /// Runs `body` – the remote work for `host` – as a registered job. `body` passes `handle` to everything it starts
    /// (SSH.run, Operations, LessonRunner, Payload.make): an interruption cancels the handle, which stops every
    /// script started with it on the iMac too (SSH.run runs it as a registered remote job and writes how the stop
    /// went to its output) and ends uploads and packing. A job that begins after the interruption gets a cancelled
    /// handle, so it starts nothing. Returns once the stop on the iMac is done.
    func job<T>(on host: Machine, _ body: (ProcessHandle) async -> T) async -> T {
        let job = begin(host)
        let value = await body(job.handle)
        await job.handle.cancellationFinished()
        lock.withLock { _ = active.removeValue(forKey: ObjectIdentifier(job)) }
        return value
    }

    /// Packs `items` (Payload.make) as a job without a Mac (AUDIT REV-44). A large app or materials folder takes
    /// minutes, and Ctrl-C used to end cmcrctl at once while tar – in a process group of its own, out of the terminal's
    /// reach – went on writing an archive nobody removed. Now Ctrl-C stops tar and Payload.make removes the unfinished
    /// archive; an archive finished just as Ctrl-C came is removed here. After an interruption the result is a failure
    /// and the caller starts nothing on the iMacs (it returns, main.swift ends with 130). The archive stays registered
    /// until `discard`, so a later immediate end (a second Ctrl-C, Ctrl-C between jobs) removes it too.
    func pack(_ items: [URL]) async -> Result<URL, Error> {
        let job = begin(nil)
        let result = await Payload.make(items, handle: job.handle)
        let interrupted: Bool = lock.withLock {
            active.removeValue(forKey: ObjectIdentifier(job))
            if signalNumber == nil, case .success(let url) = result { archives.insert(url) }
            return signalNumber != nil
        }
        guard interrupted else { return result }
        if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
        return .failure(PackingInterrupted())
    }

    /// Removes an archive made by `pack`.
    func discard(_ archive: URL) {
        lock.withLock { _ = archives.remove(archive) }
        try? FileManager.default.removeItem(at: archive)
    }

    struct PackingInterrupted: LocalizedError {
        var errorDescription: String? { "Przerwano pakowanie plików." }
    }

    /// Runs `script` on `host` as a job (see `job`).
    func run(_ script: RemoteScript, on host: Machine, password: String?, settings: SSHSettings,
             timeout: TimeInterval? = nil, onOutput: (@Sendable (OutputChannel, Data) -> Void)?) async -> CommandResult {
        var script = script
        let id = RemoteJobs.newID()
        script.jobID = id
        return await job(on: host) { handle in
            let r = await SSH.run(script, on: host, password: password, settings: settings, timeout: timeout,
                                  handle: handle, onOutput: onOutput)
            // ssh may have ended on its own just before the handle was cancelled (a lost connection, or a signal sent
            // to ssh as well), and the job survives that: it is stopped here. A just-ended ssh waits a moment for a
            // signal still on its way.
            var stop = isInterrupted
            if !stop, r.started, !r.cancelled, [255, SIGINT, SIGTERM].contains(r.exitCode) {
                try? await Task.sleep(nanoseconds: 200_000_000)
                stop = isInterrupted
            }
            if stop, r.started, !r.cancelled {
                let outcome = await SSH.cancelRemote(jobID: id, on: host, password: password, settings: settings)
                onOutput?(.stderr, Data("▸ \(outcome.message)\n".utf8))
            }
            return r
        }
    }

    /// After an interruption: the hosts on which the command was not started.
    func reportNotStarted(_ hosts: [Machine]) {
        guard !hosts.isEmpty else { return }
        Console.err("▸ Nie uruchomiono polecenia \(Polish.onComputers(hosts.count)): "
                    + "\(hosts.map(\.name).joined(separator: ", ")).")
    }

    /// Registers a job – in the same lock as `received` reads the jobs, so none is missed – and installs the handlers
    /// with the first one. Interrupted already: the job is not registered and its handle starts cancelled.
    private func begin(_ host: Machine?) -> Job {
        let (job, interrupted): (Job, Bool) = lock.withLock {
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
            started += 1
            let job = Job(host: host, order: started)
            if signalNumber == nil { active[ObjectIdentifier(job)] = job }
            return (job, signalNumber != nil)
        }
        if interrupted { job.handle.cancel() }
        return job
    }

    private func received(_ sig: Int32) {
        let (jobs, packed): ([Job]?, Set<URL>) = lock.withLock {
            if signalNumber != nil { return (nil, self.archives) }
            signalNumber = sig
            return (active.values.sorted { $0.order < $1.order }, self.archives)
        }
        // The second Ctrl-C, or nothing runs: ends at once, as before – without leaving the packed files behind.
        guard let jobs, !jobs.isEmpty else {
            packed.forEach { unlink($0.path) }
            exit(128 + sig)
        }
        let hosts = jobs.compactMap(\.host?.name)
        Console.err(hosts.isEmpty
                    ? "\n▸ Przerywanie – zatrzymywanie pakowania plików (na komputerach nic jeszcze nie uruchomiono)… "
                        + "Ponowne Ctrl-C kończy od razu."
                    : "\n▸ Przerywanie – zatrzymywanie polecenia na komputerach (\(hosts.joined(separator: ", ")))… "
                        + "Ponowne Ctrl-C kończy od razu.")
        jobs.forEach { $0.handle.cancel() }
    }
}
