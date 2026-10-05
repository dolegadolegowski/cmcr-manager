import Foundation

/// Which ssh failures `SSH.run` repeats. Only failures before the remote session started are retried,
/// so a command never runs twice.
public struct SSHRetryPolicy: Sendable, Equatable {
    /// Extra attempts after a transient refusal (sshd busy, shared connection full).
    public var attempts: Int
    /// Extra attempts when the Mac could not be reached at all (it may be waking up).
    public var unreachableAttempts: Int

    public init(attempts: Int, unreachableAttempts: Int) {
        self.attempts = attempts
        self.unreachableAttempts = unreachableAttempts
    }

    public static let none = SSHRetryPolicy(attempts: 0, unreachableAttempts: 0)
    /// Quick operations such as status checks: an unreachable Mac is simply reported.
    public static let transient = SSHRetryPolicy(attempts: 1, unreachableAttempts: 0)
    /// Jobs started by the user.
    public static let job = SSHRetryPolicy(attempts: 2, unreachableAttempts: 1)
}

/// Time limits per kind of operation; long jobs (installs, copies, updates) have none.
public enum OperationTimeout {
    public static func status(connectTimeout: Int) -> TimeInterval { TimeInterval(connectTimeout + 25) }
    /// Lists of running or installed apps, folder listings.
    public static let list: TimeInterval = 40
    public static let screenshot: TimeInterval = 45
    /// `softwareupdate --list` contacts Apple's servers and can be slow.
    public static let updateList: TimeInterval = 600
    /// Stopping a remote job.
    public static let cancel: TimeInterval = 30
}

/// Limits concurrent SSH sessions per Mac. With connection sharing every session of a Mac goes through one
/// connection, and sshd refuses more than MaxSessions (10 by default) of them.
public final class HostGate: @unchecked Sendable {
    public static let shared = HostGate()
    public static let defaultLimit = 6

    private struct Waiter {
        let id: UUID
        let cont: CheckedContinuation<Bool, Never>
    }

    public let limit: Int
    private let lock = NSLock()
    private var inUse: [String: Int] = [:]
    private var waiters: [String: [Waiter]] = [:]
    /// Waiters that gave up (timeout or cancellation) before they were queued.
    private var abandoned = Set<UUID>()

    public init(limit: Int = HostGate.defaultLimit) {
        self.limit = max(1, limit)
    }

    public static func key(for host: Machine) -> String {
        "\(host.user)@\(host.address.lowercased()):\(host.port)"
    }

    /// Waits for a free slot. Returns false after `timeout`, or when `handle` or the Task is cancelled.
    public func acquire(_ key: String, timeout: TimeInterval? = nil, handle: ProcessHandle? = nil) async -> Bool {
        let id = UUID()
        var token: UUID?
        if let handle {
            token = handle.addCancelAction { [weak self] in self?.giveUp(key, id) }
            if token == nil { return false }
        }
        defer {
            if let token { handle?.removeCancelAction(token) }
            forget(id)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if abandoned.remove(id) != nil {
                    lock.unlock()
                    cont.resume(returning: false)
                    return
                }
                if inUse[key, default: 0] < limit {
                    inUse[key, default: 0] += 1
                    lock.unlock()
                    cont.resume(returning: true)
                    return
                }
                waiters[key, default: []].append(Waiter(id: id, cont: cont))
                lock.unlock()
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.giveUp(key, id, rememberIfMissing: false)
                    }
                }
            }
        } onCancel: {
            giveUp(key, id)
        }
    }

    /// `rememberIfMissing`: the waiter may not be queued yet (cancellation racing with `acquire`).
    private func giveUp(_ key: String, _ id: UUID, rememberIfMissing: Bool = true) {
        lock.lock()
        guard var list = waiters[key], let i = list.firstIndex(where: { $0.id == id }) else {
            if rememberIfMissing { abandoned.insert(id) }
            lock.unlock()
            return
        }
        let w = list.remove(at: i)
        waiters[key] = list.isEmpty ? nil : list
        lock.unlock()
        w.cont.resume(returning: false)
    }

    private func forget(_ id: UUID) {
        lock.lock()
        abandoned.remove(id)
        lock.unlock()
    }

    public func release(_ key: String) {
        lock.lock()
        if var list = waiters[key], !list.isEmpty {
            // The slot passes straight to the next waiter.
            let w = list.removeFirst()
            waiters[key] = list.isEmpty ? nil : list
            lock.unlock()
            w.cont.resume(returning: true)
            return
        }
        let n = (inUse[key] ?? 1) - 1
        inUse[key] = n > 0 ? n : nil
        lock.unlock()
    }

    func sessions(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inUse[key] ?? 0
    }

    static func busyResult(_ host: Machine) -> CommandResult {
        .failure("Zbyt wiele jednoczesnych operacji na \(host.name) – spróbuj ponownie za chwilę.", code: 255)
    }
}

/// A flag set from any thread.
final class OutputFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// ssh's messages about shared connections ("mux_client_request_session: … refused", "ControlSocket … already
/// exists") are not the command's output.
enum SSHNoise {
    static let markers = ["mux_client_", "muxclient: ", "ControlSocket ", "Control socket connect("].map { Data($0.utf8) }

    static func filter(_ data: Data) -> Data {
        guard !data.isEmpty, markers.contains(where: { data.range(of: $0) != nil }) else { return data }
        var out = Data()
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? data.endIndex
            let line = data[start..<end]
            if !markers.contains(where: { line.starts(with: $0) }) { out.append(line) }
            start = end
        }
        return out
    }
}

/// Remote job registry used to stop commands on the Mac (not just the local ssh).
///
/// A job wrapper records `<pid of its bash> <CMCR_TMP>` in `/tmp/cmcr-jobs/<id>` (a 0700 directory of the
/// admin; `/tmp/cmcr-jobs-<uid>` if that name is taken) and the root shell's pid in `<id>.root`. The cancel
/// script kills those process groups. A `<id>.cancel` marker stops a job that registers after the cancel.
public enum RemoteJobs {
    public static func newID() -> String { UUID().uuidString.lowercased() }

    public static func isValidID(_ id: String?) -> Bool {
        guard let id, !id.isEmpty, id.count <= 64 else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    static let jobsDirFunction = #"""
    cmcr_jobs_dir() {
      CMCR_JOBS=/tmp/cmcr-jobs
      if [ -L "$CMCR_JOBS" ] || { [ -e "$CMCR_JOBS" ] && [ ! -O "$CMCR_JOBS" ]; }; then CMCR_JOBS="/tmp/cmcr-jobs-$UID"; fi
      [ -d "$CMCR_JOBS" ] || mkdir -m 700 "$CMCR_JOBS" 2>/dev/null
      [ -d "$CMCR_JOBS" ] && [ ! -L "$CMCR_JOBS" ] && [ -O "$CMCR_JOBS" ]
    }
    """#

    /// Wrapper part for jobs: registration, plus output relays. The body writes into FIFOs drained by `cat`;
    /// when the connection is gone the relays keep draining, so the body never sees a broken pipe.
    static func registration(jobID: String) -> String {
        jobsDirFunction + "\n" + #"""
        CMCR_JOB_ID='\#(jobID)'
        if cmcr_jobs_dir; then
          CMCR_JOB_FILE="$CMCR_JOBS/$CMCR_JOB_ID"
          echo "$$ $CMCR_TMP" > "$CMCR_JOB_FILE"
          if [ -e "$CMCR_JOB_FILE.cancel" ]; then rm -f "$CMCR_JOB_FILE.cancel"; echo "Anulowano." >&2; exit 130; fi
        fi
        if mkfifo "$CMCR_TMP/.out" "$CMCR_TMP/.err" 2>/dev/null; then
          ( ( cat 2>/dev/null || cat >/dev/null ) <"$CMCR_TMP/.out" & ( cat >&2 2>/dev/null || cat >/dev/null ) <"$CMCR_TMP/.err" & )
          exec >"$CMCR_TMP/.out" 2>"$CMCR_TMP/.err"
        fi

        """#
    }

    /// Stops a registered job: SIGTERM to its process groups (via sudo for root-owned processes), SIGKILL
    /// after 3 s. Prints one `CMCR:CANCEL:<state>` line.
    public static func cancelScript(jobID: String) -> RemoteScript {
        RemoteScript(jobsDirFunction + "\n" + #"""
        CMCR_JOB_ID='\#(jobID)'
        cmcr_jobs_dir || { echo "CMCR:CANCEL:NOREG"; exit 0; }
        F="$CMCR_JOBS/$CMCR_JOB_ID"
        find "$CMCR_JOBS" -name '*.cancel' -mmin +120 -exec rm -f {} + 2>/dev/null
        : > "$F.cancel"
        if [ ! -f "$F" ]; then echo "CMCR:CANCEL:NOTRUNNING"; exit 0; fi
        read -r P T < "$F"
        U=""; G=""; C=""
        case "$P" in ''|*[!0-9]*) ;; *) set -- $(ps -o uid=,pgid=,comm= -p "$P" 2>/dev/null); U="${1:-}"; G="${2:-}"; C="${3:-}" ;; esac
        case "$C" in *bash*) ;; *) G="" ;; esac
        case "$G" in ''|0|1|*[!0-9]*) G="" ;; esac
        if [ -z "$G" ] || [ "$U" != "$UID" ] || [ "$G" = "$(ps -o pgid= -p $$ | tr -d ' ')" ]; then
          rm -f "$F" "$F.root" "$F.cancel"; echo "CMCR:CANCEL:NOTRUNNING"; exit 0
        fi
        RG=""
        if [ -f "$F.root" ]; then
          read -r R < "$F.root"
          case "$R" in ''|*[!0-9]*) ;; *) RG="$(ps -o pgid= -p "$R" 2>/dev/null | tr -d ' ')" ;; esac
          case "$RG" in ''|0|1|"$G"|*[!0-9]*) RG="" ;; esac
        fi
        cmcr_members() {
          ps -A -o pgid=,uid= 2>/dev/null | awk -v a="$G" -v b="${RG:-$G}" -v u="$UID" -v f="${1:-}" \
            '($1 == a || $1 == b) && (f == "" || $2 != u) { n++ } END { print n + 0 }'
        }
        cmcr_signal() {
          kill "-$1" -- "-$G" ${RG:+"-$RG"} 2>/dev/null
          if [ "$(cmcr_members foreign)" -gt 0 ]; then asroot /bin/kill "-$1" -- "-$G" ${RG:+"-$RG"} 2>/dev/null; fi
        }
        cmcr_signal TERM
        i=0
        while [ "$(cmcr_members)" -gt 0 ] && [ "$i" -lt 15 ]; do sleep 0.2; i=$((i + 1)); done
        if [ "$(cmcr_members)" -gt 0 ]; then cmcr_signal KILL; sleep 0.3; fi
        case "$T" in
          /tmp/cmcr.??????) if [ -d "$T" ]; then rm -rf "$T" 2>/dev/null || asroot rm -rf "$T" 2>/dev/null; fi ;;
        esac
        rm -f "$F" "$F.root" "$F.cancel"
        if [ "$(cmcr_members)" -gt 0 ]; then echo "CMCR:CANCEL:ALIVE"; exit 1; fi
        echo "CMCR:CANCEL:OK"
        """#)
    }
}

/// Result of stopping a remote job.
public enum RemoteCancelOutcome: Sendable, Equatable {
    case stopped, notRunning, stillRunning, unsupported
    case failed(String)

    init(_ r: CommandResult) {
        let out = r.stdoutText
        if out.contains("CMCR:CANCEL:OK") { self = .stopped }
        else if out.contains("CMCR:CANCEL:NOTRUNNING") { self = .notRunning }
        else if out.contains("CMCR:CANCEL:ALIVE") { self = .stillRunning }
        else if out.contains("CMCR:CANCEL:NOREG") { self = .unsupported }
        else { self = .failed(SSH.diagnose(r).1) }
    }

    public var message: String {
        switch self {
        case .stopped: return "Zatrzymano polecenie na komputerze."
        case .notRunning: return "Polecenie nie działało już na komputerze."
        case .stillRunning: return "Nie udało się zatrzymać wszystkich procesów polecenia na komputerze."
        case .unsupported: return "Nie można zatrzymać polecenia na komputerze – może ono nadal działać."
        case .failed(let why): return "Nie udało się połączyć, aby zatrzymać polecenie – może ono nadal działać na komputerze (\(why))."
        }
    }
}
