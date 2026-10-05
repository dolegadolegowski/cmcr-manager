import Foundation

/// A bash script executed on a remote Mac over SSH.
///
/// The script is shipped base64-encoded on the ssh command line, so no quoting is needed, and the admin
/// password travels as the first line of stdin (never in argv or on disk). Every body can use:
/// - `asroot cmd…`          – run as root (sudo with the password supplied through SUDO_ASKPASS),
/// - `as_console_user cmd…` – run inside the GUI session of the user logged in at the screen,
/// - `with_askpass cmd…`    – run a tool that calls `sudo -A` itself (e.g. Homebrew),
/// - `$CONSOLE_USER`, `$CONSOLE_UID`, `$CMCR_ADMIN_USER`, `$CMCR_TMP` (private temp dir, removed on exit).
///
/// The wrapper ignores SIGHUP and SIGPIPE, so it always cleans up; the body runs in a subshell with the usual
/// SIGPIPE behaviour. A job (`jobID`) writes through relays that outlive the connection, so it keeps running
/// when the admin's Mac sleeps or the connection drops. Only an explicit cancel (`SSH.cancelRemote`) stops it.
public struct RemoteScript: Sendable {
    public var body: String
    public var asRoot: Bool
    /// Registers the job on the remote Mac (process group in /tmp/cmcr-jobs/<id>) so that it can be
    /// stopped by `SSH.cancelRemote`, and relays its output so it survives a lost connection.
    /// SSH.run assigns one when the operation has a ProcessHandle. Letters, digits and '-' only.
    public var jobID: String?

    public init(_ body: String, asRoot: Bool = false, jobID: String? = nil) {
        self.body = body
        self.asRoot = asRoot
        self.jobID = jobID
    }

    static let library = #"""
    export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    CMCR_ADMIN_USER="${SUDO_USER:-$(id -un)}"
    CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null)"
    case "$CONSOLE_USER" in root|_mbsetupuser|loginwindow) CONSOLE_USER="" ;; esac
    CONSOLE_UID=""
    if [ -n "$CONSOLE_USER" ]; then CONSOLE_UID="$(id -u "$CONSOLE_USER" 2>/dev/null)"; fi
    asroot() {
      if [ "$(id -u)" -eq 0 ]; then "$@"; return; fi
      if [ -z "$CMCR_PW" ]; then
        if sudo -n true 2>/dev/null; then sudo -n -- "$@"; return; fi
        echo "Brak hasła administratora – zapisz je w Konfiguracji (wymagane do sudo)." >&2; return 91
      fi
      CMCR_PW="$CMCR_PW" SUDO_ASKPASS="$CMCR_TMP/askpass" sudo -A -k -- "$@"
    }
    as_console_user() {
      if [ -z "$CONSOLE_USER" ]; then echo "Brak zalogowanego użytkownika (ekran logowania)." >&2; return 3; fi
      asroot launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" -- "$@"
    }
    with_askpass() { CMCR_PW="$CMCR_PW" SUDO_ASKPASS="$CMCR_TMP/askpass" "$@"; }
    is_admin_user() { dseditgroup -o checkmember -m "$1" admin >/dev/null 2>&1; }
    """#

    /// Full script text that is executed by `/bin/bash` on the remote side.
    public func render() -> String {
        let tag = "CMCR_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let job = RemoteJobs.isValidID(jobID) ? jobID ?? "" : ""
        var s = #"""
        IFS= read -r CMCR_PW || CMCR_PW=""
        trap '' HUP PIPE
        CMCR_TMP="$(mktemp -d /tmp/cmcr.XXXXXX)" || { echo "mktemp nie powiódł się" >&2; exit 90; }
        export CMCR_TMP
        CMCR_JOB_FILE=""
        cmcr_cleanup() {
          if [ -n "$CMCR_JOB_FILE" ]; then rm -f "$CMCR_JOB_FILE" "$CMCR_JOB_FILE.root" 2>/dev/null; fi
          if [ -n "$(find "$CMCR_TMP" ! -user "$UID" -print -quit 2>/dev/null)" ]; then asroot rm -rf "$CMCR_TMP" 2>/dev/null; fi
          rm -rf "$CMCR_TMP" 2>/dev/null
        }
        trap cmcr_cleanup EXIT
        trap 'exit 143' TERM INT
        cat > "$CMCR_TMP/askpass" <<'\#(tag)_A'
        #!/bin/sh
        # Answer each sudo only once, so a wrong password costs a single failed attempt.
        M="$(dirname "$0")/.used.$PPID"
        [ -e "$M" ] && exit 1
        : > "$M"
        printf '%s\n' "$CMCR_PW"
        \#(tag)_A
        chmod 700 "$CMCR_TMP/askpass"
        cat > "$CMCR_TMP/lib.sh" <<'\#(tag)_L'
        \#(Self.library)
        \#(tag)_L
        cat > "$CMCR_TMP/body.sh" <<'\#(tag)_B'
        \#(body)
        \#(tag)_B
        source "$CMCR_TMP/lib.sh"

        """#
        if !job.isEmpty {
            s += RemoteJobs.registration(jobID: job)
        }
        if asRoot {
            // The root shell hands its files back to the admin on exit, so the cleanup needs no second sudo.
            s += #"""
            if [ "$(id -u)" -ne 0 ] && [ -z "$CMCR_PW" ] && ! sudo -n true 2>/dev/null; then
              echo "Brak hasła administratora – zapisz je w Konfiguracji (wymagane do sudo)." >&2; exit 91
            fi
            ( trap - PIPE; printf '%s\n' "$CMCR_PW" | asroot /bin/bash --noprofile --norc -c 'IFS= read -r CMCR_PW; CMCR_TMP="$1"; export CMCR_TMP; trap "" HUP; trap "chown -hR $2 \"\$CMCR_TMP\" 2>/dev/null" EXIT; trap "exit 143" TERM INT; if [ -n "$3" ]; then echo "$$" > "$3.root"; fi; source "$CMCR_TMP/lib.sh"; source "$CMCR_TMP/body.sh"' cmcr "$CMCR_TMP" "$UID" "$CMCR_JOB_FILE" )

            """#
        } else {
            s += "( trap - PIPE; source \"$CMCR_TMP/body.sh\" )\n"
        }
        return s
    }

    /// Command line handed to ssh (interpreted by the remote login shell).
    ///
    /// `--noprofile --norc` matters: bash started by sshd otherwise sources /etc/bashrc and the admin's
    /// ~/.bashrc, whose output or aliases could corrupt results (e.g. the tar stream of a pull).
    public func remoteCommand() -> String {
        let b64 = Data(render().utf8).base64EncodedString()
        return "/bin/bash --noprofile --norc -c \"$(echo \(b64) | base64 -D)\""
    }
}

public struct SSHSettings: Sendable {
    public var identityFile: String
    public var connectTimeout: Int
    public var extraOptions: [String]
    public var askpassPath: String
    /// OpenSSH connection sharing (ControlMaster): one login per Mac, later sessions start instantly.
    public var reuseConnections: Bool

    public init(identityFile: String = "", connectTimeout: Int = 5, extraOptions: [String] = [], askpassPath: String,
                reuseConnections: Bool = true) {
        self.identityFile = identityFile
        self.connectTimeout = connectTimeout
        self.extraOptions = extraOptions
        self.askpassPath = askpassPath
        self.reuseConnections = reuseConnections
    }

    public init(_ s: AppSettings, askpassPath: String) {
        self.init(identityFile: s.identityFile, connectTimeout: s.connectTimeout,
                  extraOptions: s.extraSSHOptionList, askpassPath: askpassPath,
                  reuseConnections: s.reuseConnections)
    }
}

public enum SSH {
    public static let sshPath = "/usr/bin/ssh"
    public static let scpPath = "/usr/bin/scp"
    /// Seconds an idle shared connection stays open.
    static let controlPersist = 120

    static func options(_ s: SSHSettings, password: String?, mux: Bool = true) -> [String] {
        // OpenSSH uses the first value given for an option, so the user's own options go first and win.
        var o: [String] = s.extraOptions.flatMap { ["-o", $0] }
        o += [
            "-o", "ConnectTimeout=\(s.connectTimeout)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "LogLevel=ERROR",
        ]
        o += muxOptions(s, enabled: mux)
        if let pw = password, !pw.isEmpty {
            o += ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"]
        } else {
            o += ["-o", "BatchMode=yes"]
        }
        let identity = expandTilde(s.identityFile)
        if !s.identityFile.isEmpty { o += ["-i", identity] }
        return o
    }

    static func muxOptions(_ s: SSHSettings, enabled: Bool = true) -> [String] {
        if enabled, s.reuseConnections, let dir = controlDirectory() {
            return ["-o", "ControlMaster=auto", "-o", "ControlPath=\(dir)/%C", "-o", "ControlPersist=\(controlPersist)"]
        }
        return ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
    }

    /// Private directory for the shared-connection sockets. It lives in /tmp because a socket path must stay
    /// under 104 bytes; nil (no sharing) when it is not a real directory owned by this user.
    /// `CMCR_SSH_CONTROL_DIR` overrides it (the tests keep their connections apart from the app's).
    public static func controlDirectory() -> String? {
        var dir = "/tmp/cmcr-\(getuid())"
        if let custom = ProcessInfo.processInfo.environment["CMCR_SSH_CONTROL_DIR"], custom.hasPrefix("/") {
            // %C adds 40 characters and ssh a 17-character suffix while creating the socket.
            guard custom.utf8.count + 58 < 104 else { return nil }
            dir = custom
        }
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard mkdir(dir, 0o700) == 0 || errno == EEXIST, lstat(dir, &st) == 0 else { return nil }
        }
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { return nil }
        if st.st_mode & 0o077 != 0 { chmod(dir, 0o700) }
        return dir
    }

    static func environment(_ s: SSHSettings, password: String?) -> [String: String] {
        guard let pw = password, !pw.isEmpty else { return ["SSH_ASKPASS_REQUIRE": "never"] }
        return [
            "SSH_ASKPASS": s.askpassPath,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0",
            "CMCR_SSH_PASSWORD": pw,
        ]
    }

    /// Runs a remote script (cmcr-exec equivalent).
    ///
    /// - With a `handle` the script runs as a registered remote job: cancelling the handle also stops the
    ///   command on the Mac, and a timeout does the same. A lost connection does not stop it.
    /// - Failures before the remote session started are retried according to `retry`.
    /// - At most `HostGate.limit` sessions run per Mac at a time (sshd allows 10 per connection).
    public static func run(
        _ script: RemoteScript,
        on host: Machine,
        password: String?,
        settings: SSHSettings,
        stdoutFile: URL? = nil,
        timeout: TimeInterval? = nil,
        handle: ProcessHandle? = nil,
        retry: SSHRetryPolicy = .transient,
        maxCapture: Int = ProcessRunner.defaultMaxCapture,
        onOutput: (@Sendable (OutputChannel, Data) -> Void)? = nil
    ) async -> CommandResult {
        var script = script
        if script.jobID == nil, handle != nil { script.jobID = RemoteJobs.newID() }
        let key = HostGate.key(for: host)
        guard await HostGate.shared.acquire(key, timeout: timeout, handle: handle) else {
            return handle?.isCancelled == true || Task.isCancelled ? .cancelledResult : HostGate.busyResult(host)
        }
        defer { HostGate.shared.release(key) }
        if handle?.isCancelled == true || Task.isCancelled { return .cancelledResult }

        var cancelToken: UUID?
        if let handle, let id = script.jobID {
            cancelToken = handle.addCancelAction {
                let outcome = await cancelRemote(jobID: id, on: host, password: password, settings: settings)
                onOutput?(.stderr, Data("▸ \(outcome.message)\n".utf8))
            }
            if cancelToken == nil { return .cancelledResult }
        }
        defer { if let cancelToken { handle?.removeCancelAction(cancelToken) } }

        let stdin = Data(((password ?? "") + "\n").utf8)
        let command = script.remoteCommand()
        var r = await runWithRetry(on: host, settings: settings, retry: retry, handle: handle, stdoutFile: stdoutFile,
                                   onOutput: onOutput) { mux, output in
            await ProcessRunner.run(sshPath, options(settings, password: password, mux: mux)
                                        + ["-T", "-p", String(host.port), host.destination, command],
                                    environment: environment(settings, password: password), stdin: stdin,
                                    stdoutFile: stdoutFile, timeout: timeout, maxCapture: maxCapture,
                                    handle: handle, onOutput: output)
        }
        if r.timedOut, !r.cancelled, let id = script.jobID, handle != nil {
            let outcome = await cancelRemote(jobID: id, on: host, password: password, settings: settings)
            let note = Data("▸ Przekroczono limit czasu. \(outcome.message)\n".utf8)
            onOutput?(.stderr, note)
            r.stderr.append(note)
        }
        return r
    }

    /// Runs `attempt` (with connection sharing first) and repeats it after failures that happened before
    /// the remote command could start. ssh noise about shared connections is removed from the output.
    static func runWithRetry(
        on host: Machine,
        settings: SSHSettings,
        retry: SSHRetryPolicy,
        handle: ProcessHandle?,
        stdoutFile: URL?,
        isCopy: Bool = false,
        onOutput: (@Sendable (OutputChannel, Data) -> Void)?,
        attempt: (_ mux: Bool, _ output: @escaping @Sendable (OutputChannel, Data) -> Void) async -> CommandResult
    ) async -> CommandResult {
        var mux = settings.reuseConnections
        var transientLeft = retry.attempts
        var unreachableLeft = retry.unreachableAttempts
        var round = 0
        while true {
            let seen = OutputFlag()
            let output: @Sendable (OutputChannel, Data) -> Void = { channel, data in
                if channel == .stdout { seen.set() }
                let clean = channel == .stderr ? SSHNoise.filter(data) : data
                if !clean.isEmpty { onOutput?(channel, clean) }
            }
            var r = await attempt(mux, output)
            let wroteStdout = seen.isSet || stdoutFile.map { Payload.size(of: $0) > 0 } ?? false
            let failure = wroteStdout ? nil : connectFailure(r, sshExitOnly: !isCopy)
            // Keep ssh's raw message when it is all there is to explain a failed connection.
            let clean = SSHNoise.filter(r.stderr)
            if r.exitCode != 255 || !String(decoding: clean, as: UTF8.self).allSatisfy(\.isWhitespace) {
                r.stderr = clean
            }
            guard let failure, handle?.isCancelled != true, !Task.isCancelled else { return r }
            switch failure {
            case .transient, .sharedConnection:
                guard transientLeft > 0 else { return r }
                transientLeft -= 1
            case .unreachable:
                guard unreachableLeft > 0 else { return r }
                unreachableLeft -= 1
            }
            round += 1
            if failure == .sharedConnection, mux {
                await closeMaster(host, settings: settings)
                mux = false
            }
            onOutput?(.stderr, Data("▸ Ponowna próba połączenia (\(round))…\n".utf8))
            let delay: Double = failure == .unreachable ? (round == 1 ? 2 : 5) : Double.random(in: 0.2...0.8)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if handle?.isCancelled == true || Task.isCancelled { return .cancelledResult }
        }
    }

    enum ConnectFailure: Equatable { case transient, sharedConnection, unreachable }

    /// Classifies ssh failures that certainly happened before the remote command started (safe to retry).
    /// ssh reports its own failures with exit code 255; scp exits with 1 and passes ssh's message through.
    static func connectFailure(_ r: CommandResult, sshExitOnly: Bool = true) -> ConnectFailure? {
        guard sshExitOnly ? r.exitCode == 255 : r.exitCode != 0 else { return nil }
        guard !r.timedOut, !r.cancelled, r.stdout.isEmpty else { return nil }
        let e = r.stderrText.lowercased()
        if e.contains("permission denied") || e.contains("host key") || e.contains("authentication failures") {
            return nil
        }
        if e.contains("mux_client_request_session") || e.contains("session open refused by peer")
            || e.contains("mux_client_hello_exchange") || e.contains("control socket connect") {
            return .sharedConnection
        }
        if e.contains("kex_exchange_identification") || e.contains("ssh_exchange_identification")
            || e.contains("banner exchange")
            || e.range(of: #"connection (closed|reset) by \S+ port \d+"#, options: .regularExpression) != nil {
            return .transient
        }
        if e.contains("could not resolve hostname") || e.contains("nodename nor servname")
            || e.contains("ssh: connect to host") {
            return .unreachable
        }
        return nil
    }

    /// Copies local files to a remote path with scp (cmcr-push transport).
    public static func upload(
        _ files: [URL],
        to remotePath: String,
        on host: Machine,
        password: String?,
        settings: SSHSettings,
        handle: ProcessHandle? = nil,
        retry: SSHRetryPolicy = .transient
    ) async -> CommandResult {
        let key = HostGate.key(for: host)
        guard await HostGate.shared.acquire(key, handle: handle) else { return .cancelledResult }
        defer { HostGate.shared.release(key) }
        // No -q: it would also hide ssh's own diagnostics (unknown host, refused, wrong password).
        return await runWithRetry(on: host, settings: settings, retry: retry, handle: handle, stdoutFile: nil,
                                  isCopy: true, onOutput: nil) { mux, output in
            let args = ["-r", "-p", "-P", String(host.port)] + options(settings, password: password, mux: mux)
                + files.map(\.path) + ["\(host.destination):\(remotePath)"]
            return await ProcessRunner.run(scpPath, args, environment: environment(settings, password: password),
                                           handle: handle, onOutput: output)
        }
    }

    /// Arguments for an interactive session (cmcr-go).
    public static func interactiveArguments(for host: Machine, settings: SSHSettings) -> [String] {
        var a: [String] = settings.extraOptions.flatMap { ["-o", $0] }
        a += ["-p", String(host.port), "-o", "StrictHostKeyChecking=accept-new",
              "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"]
        a += muxOptions(settings)
        if !settings.identityFile.isEmpty { a += ["-i", expandTilde(settings.identityFile)] }
        return a + [host.destination]
    }

    /// Closes the shared connection to a Mac (after it restarted, its key changed or the settings changed).
    public static func closeMaster(_ host: Machine, settings: SSHSettings) async {
        guard let dir = controlDirectory(),
              let sockets = try? FileManager.default.contentsOfDirectory(atPath: dir), !sockets.isEmpty else { return }
        var s = settings
        s.reuseConnections = true
        let args = options(s, password: nil) + ["-O", "exit", "-p", String(host.port), host.destination]
        _ = await ProcessRunner.run(sshPath, args, environment: ["SSH_ASKPASS_REQUIRE": "never"], timeout: 5)
    }

    public static func closeMasters(_ hosts: [Machine], settings: SSHSettings) async {
        await withTaskGroup(of: Void.self) { group in
            for h in hosts { group.addTask { await closeMaster(h, settings: settings) } }
        }
    }

    /// Known-hosts files set with `UserKnownHostsFile` in the extra options (empty: ssh's default).
    public static func knownHostsFiles(_ s: SSHSettings) -> [String] {
        for option in s.extraOptions {
            let parts = option.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == " " })
            guard parts.count == 2, parts[0].lowercased() == "userknownhostsfile" else { continue }
            return parts[1].split(separator: " ").map { expandTilde(String($0)) }.filter { $0 != "none" }
        }
        return []
    }

    /// Stops a remote job started by `run` with a handle (kills its process group, as root if needed).
    public static func cancelRemote(jobID: String, on host: Machine, password: String?,
                                    settings: SSHSettings) async -> RemoteCancelOutcome {
        guard RemoteJobs.isValidID(jobID) else { return .failed("nieprawidłowy identyfikator zadania") }
        let stdin = Data(((password ?? "") + "\n").utf8)
        // Not gated: it must get through while the job it stops still holds a session slot.
        let command = RemoteJobs.cancelScript(jobID: jobID).remoteCommand()
        let r = await runWithRetry(on: host, settings: settings, retry: .transient, handle: nil, stdoutFile: nil,
                                   onOutput: nil) { mux, output in
            await ProcessRunner.run(sshPath, options(settings, password: password, mux: mux)
                                        + ["-T", "-p", String(host.port), host.destination, command],
                                    environment: environment(settings, password: password), stdin: stdin,
                                    timeout: OperationTimeout.cancel, onOutput: output)
        }
        return RemoteCancelOutcome(r)
    }

    /// Turns an ssh failure into a status and a human readable (Polish) explanation.
    public static func diagnose(_ r: CommandResult) -> (Reachability, String) {
        let err = r.stderrText
        let lower = err.lowercased()
        if r.cancelled { return (.error, "Anulowano.") }
        if r.timedOut { return (.offline, "Przekroczono limit czasu.") }
        if r.exitCode == 255 || lower.contains("ssh:") {
            if lower.contains("permission denied") || lower.contains("too many authentication failures") {
                return (.authFailed, "Odmowa dostępu – brak klucza SSH na komputerze lub błędne hasło administratora.")
            }
            if lower.contains("could not resolve hostname") || lower.contains("nodename nor servname") {
                return (.offline, "Nie można odnaleźć nazwy hosta w sieci (Bonjour/.local).")
            }
            if lower.contains("connection refused") {
                return (.error, "Połączenie odrzucone – włącz „Logowanie zdalne” (Remote Login) na tym Macu.")
            }
            if lower.contains("timed out") || lower.contains("no route to host") || lower.contains("host is down") {
                return (.offline, "Komputer nie odpowiada (wyłączony lub poza siecią).")
            }
            if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
                return (.error, "Klucz hosta się zmienił – usuń stary wpis (Konfiguracja › Przygotowanie › Zapomnij klucz hosta).")
            }
            if lower.contains("kex_exchange_identification") || lower.contains("banner exchange") {
                return (.error, "Serwer SSH chwilowo odrzucił połączenie (zbyt wiele jednoczesnych połączeń) – spróbuj ponownie.")
            }
            if lower.contains("session open refused by peer") || lower.contains("mux_client_request_session") {
                return (.error, "Przekroczono limit jednoczesnych sesji SSH na komputerze – spróbuj ponownie lub zmniejsz liczbę równoległych operacji.")
            }
            if lower.contains("timeout, server") || lower.contains("not responding") {
                return (.offline, "Połączenie zerwane – komputer przestał odpowiadać (uśpiony, wyłączony lub poza siecią).")
            }
            if lower.contains("closed by remote host") || lower.contains("broken pipe") {
                return (.error, "Połączenie zostało przerwane – polecenie mogło nadal działać na komputerze.")
            }
            return (.error, err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Błąd połączenia SSH (kod 255)." : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if lower.contains("incorrect password attempt") || lower.contains("sorry, try again")
            || lower.contains("no password was provided") {
            return (.online, "Błędne hasło administratora (sudo).")
        }
        if r.exitCode == 91 || err.contains("Brak hasła administratora") {
            return (.online, "Brak zapisanego hasła administratora – wymagane do sudo (Konfiguracja › Dostęp i hasła).")
        }
        return (.online, "Polecenie zakończone kodem \(r.exitCode).")
    }
}

/// Packs local files/folders into one tar archive (preserves app bundles, symlinks and permissions).
public enum Payload {
    public static func make(_ items: [URL]) async -> Result<URL, Error> {
        struct PayloadError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        guard !items.isEmpty else { return .failure(PayloadError(message: "Nie wybrano plików.")) }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmcr-payload-\(UUID().uuidString).tar")
        var args = ["-cf", out.path]
        for item in items {
            args += ["-C", item.deletingLastPathComponent().path, item.lastPathComponent]
        }
        let r = await ProcessRunner.run("/usr/bin/tar", args)
        if r.succeeded { return .success(out) }
        try? FileManager.default.removeItem(at: out)
        return .failure(PayloadError(message: "Nie udało się spakować plików: \(r.stderrText)"))
    }

    public static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
