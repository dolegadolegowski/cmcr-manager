import Foundation

/// A bash script executed on a remote Mac over SSH.
///
/// The script is shipped base64-encoded on the ssh command line, so no quoting is needed, and the admin
/// password travels as the first line of stdin (never in argv or on disk). Every body can use:
/// - `asroot cmd…`          – run as root (sudo with the password supplied through SUDO_ASKPASS),
/// - `as_console_user cmd…` – run inside the GUI session of the user logged in at the screen,
/// - `with_askpass cmd…`    – run a tool that calls `sudo -A` itself (e.g. Homebrew),
/// - `$CONSOLE_USER`, `$CONSOLE_UID`, `$CMCR_ADMIN_USER`, `$CMCR_TMP` (private temp dir, removed on exit),
/// - `cmcr_pin_dir DIR` / `cmcr_pin_create DIR` – `cd` into a folder one component at a time, refusing a link a
///   user planted on the way (`cmcr_walk`).
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
    # Root gets the system tools first; Homebrew tools only as a fallback.
    if [ "$EUID" -eq 0 ]; then
      export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin"
    else
      export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    fi
    # One fixed locale for every script, so the output they parse (last, sysctl, pmset, softwareupdate…) is
    # always English with '.' decimals. The app inherits no LANG from launchd, but cmcrctl started from a
    # Terminal forwards LANG/LC_* (macOS ssh SendEnv, sshd AcceptEnv): pl_PL gives 'sob. 3 paź' and '1,35'.
    # C, not a UTF-8 locale: bash 3.2 then treats [A-Za-z] as ASCII (in en_US.UTF-8 it matches 'ą'), and
    # sed/tr/grep never stop on bytes that are not UTF-8. Polish text still passes through unchanged.
    export LC_ALL=C
    CMCR_ADMIN_USER="${SUDO_USER:-${USER:-$(id -un)}}"
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
    # Runs in the GUI session of the console user with that user's HOME (sudo -H; macOS sudoers keeps the
    # admin's HOME otherwise) and with the user's home folder as the working directory.
    as_console_user() {
      if [ -z "$CONSOLE_USER" ]; then echo "Brak zalogowanego użytkownika (ekran logowania)." >&2; return 3; fi
      local h=/
      case "$CONSOLE_USER" in *[!A-Za-z0-9._-]*) ;; *) eval "h=~$CONSOLE_USER" ;; esac
      ( cd "$h" 2>/dev/null || cd /; asroot launchctl asuser "$CONSOLE_UID" sudo -H -u "$CONSOLE_USER" -- "$@" )
    }
    # For tools that call `sudo -A` (Homebrew) or plain sudo without a tty (mas ≥ 4: needs DISPLAY to use the
    # askpass). Homebrew re-executes itself with a filtered environment (SUDO_ASKPASS survives, CMCR_PW does
    # not), so this askpass falls back to a 0600 file in a 0700 directory inside the admin's private
    # $CMCR_TMP. The file exists only while the command runs (and the EXIT trap removes $CMCR_TMP if the job
    # dies); only the admin and root can read it – the same accounts that can read the password from stdin.
    # A FIFO would keep the password off the disk, but sudo blocks forever on a FIFO without a writer and a
    # writer left behind by a killed job would hold the password indefinitely.
    with_askpass() {
      local d rc
      d="$(mktemp -d "$CMCR_TMP/askpass.XXXXXX")" || return 90
      ( umask 077; printf '%s\n' "$CMCR_PW" > "$d/pw" )
      cat > "$d/askpass" <<'CMCR_ASKPASS'
    #!/bin/sh
    D="$(dirname "$0")"; M="$D/.used.$PPID"
    [ -e "$M" ] && exit 1
    : > "$M"
    if [ -n "${CMCR_PW:-}" ]; then printf '%s\n' "$CMCR_PW"; else cat "$D/pw"; fi
    CMCR_ASKPASS
      chmod 700 "$d/askpass"
      CMCR_PW="$CMCR_PW" SUDO_ASKPASS="$d/askpass" DISPLAY="${DISPLAY:-:0}" "$@"; rc=$?
      rm -rf "$d"
      return $rc
    }
    is_admin_user() { dseditgroup -o checkmember -m "$1" admin >/dev/null 2>&1; }
    # Adds a command to the EXIT trap, keeping the wrapper's own cleanup.
    cmcr_on_exit() {
      local add="$1" prev=""
      eval "set -- $(trap -p EXIT)"
      [ $# -ge 3 ] && prev="$3"
      trap "$add${prev:+; $prev}" EXIT
    }
    # Stops the script (code 3) when a path or owner uses {console} while nobody is logged in.
    cmcr_require_console() {
      case "$*" in
        *'{console}'*) [ -n "$CONSOLE_USER" ] || { echo "✘ Nikt nie jest zalogowany – nie można użyć {console}." >&2; exit 3; } ;;
      esac
    }
    # Physical path of an existing folder: symlinks resolved (/Volumes/Macintosh HD → /) and every component
    # in its on-disk case. /bin/pwd, not the builtin: the builtin keeps the case as typed (/Users/x/LIBRARY),
    # which the case-insensitive file system accepts but path checks would not recognise.
    cmcr_realdir() { ( cd "$1" 2>/dev/null && /bin/pwd -P ); }
    # Canonical form of a path whose tail may not exist yet: the deepest existing folder through cmcr_realdir,
    # then the missing components as given. Empty when no existing ancestor is a folder.
    cmcr_canonpath() {
      local p="$1" r
      while [ ! -e "$p" ] && [ ! -L "$p" ]; do p="$(dirname "$p")"; done
      r="$(cmcr_realdir "$p")" || return 1
      [ -n "$r" ] || return 1
      r="$r${1#"$p"}"
      case "$r" in //*) r="${r#/}" ;; esac
      printf '%s\n' "$r"
    }
    # cmcr_walk PATH [create [OWNER]] – enters folder PATH one component at a time (from / when PATH is absolute,
    # otherwise from the current folder), so neither a link a user planted nor a folder swapped meanwhile can
    # redirect the shell. Each component is looked at without following it (stat does not follow links) and, after
    # the `cd`, the folder entered must be that same folder (device:inode); a student who swaps their folder and a
    # link back and forth (an atomic rename) only gets a refusal. A link is followed only when root owns it AND
    # it lies in a folder only root can change (/tmp, /var, /etc in /, "/Volumes/Macintosh HD" in /Volumes); its
    # target is walked the same way. Root owning the link is not enough: a student can hard-link root's link into
    # their own folder (macOS allows it), where a relative target (MacOSX.sdk → MacOSX27.0.sdk) names something
    # the student controls, and "/Volumes/Macintosh HD" → / leads to the whole disk.
    # With "create", missing folders are made from inside their parent (owned by OWNER when given).
    # Returns 0 (the shell is in PATH), 2 for a user's link ($CMCR_LINK: where it is) or a swap ($CMCR_LINK
    # empty), 1 when a component is missing, not a folder, not accessible or cannot be created. On failure the
    # shell is back in /.
    cmcr_walk() {
      local todo="$1" mode="${2:-}" owner="${3:-}" c t made hops=0 IFS=$' \t\n'
      CMCR_LINK=""
      case "$todo" in /*) cd / || return 1 ;; esac
      while :; do
        while [ "${todo#/}" != "$todo" ]; do todo="${todo#/}"; done
        [ -n "$todo" ] || return 0
        c="${todo%%/*}"
        if [ "$c" = "$todo" ]; then todo=""; else todo="${todo#*/}"; fi
        case "$c" in
          .) continue ;;
          ..) t="$(/bin/pwd -P)" || { cd /; return 1; }
              t="${t%/*}"; todo="${t:-/}/$todo"; cd /; continue ;;
        esac
        made=0
        set -- $(stat -f '%Sp %u %d:%i' -- "./$c" 2>/dev/null)
        if [ $# -lt 3 ] && [ "$mode" = create ] && mkdir -- "./$c" 2>/dev/null; then
          made=1
          set -- $(stat -f '%Sp %u %d:%i' -- "./$c" 2>/dev/null)
        fi
        case "${1:-}" in
          d*)
            if ! cd -P -- "./$c" 2>/dev/null; then cd /; return 1; fi
            if [ "$(stat -f %d:%i . 2>/dev/null)" != "$3" ]; then cd /; return 2; fi
            if [ $made = 1 ] && [ -n "$owner" ]; then chown "$owner" . 2>/dev/null; fi ;;
          l*)
            t="$(/bin/pwd -P)"; [ "$t" = / ] && t=""
            set -- "$@" $(stat -f '%u %Lp' . 2>/dev/null)
            if [ "$2" != 0 ] || [ "${4:-}" != 0 ] || [ $(( 0${5:-2} & 022 )) != 0 ]; then
              CMCR_LINK="$t/$c"; cd /; return 2
            fi
            hops=$((hops + 1))
            t="$(readlink "./$c")"
            if [ -z "$t" ] || [ $hops -gt 32 ]; then cd /; return 1; fi
            case "$t" in /*) cd / ;; esac
            todo="$t/$todo" ;;
          *) cd /; return 1 ;;
        esac
      done
    }
    # Prints where the way to PATH leads through a link a user could have planted (see cmcr_walk); fails when it
    # does not (also when a component is missing: nothing beyond it can be a link).
    cmcr_user_link() {
      ( cmcr_walk "$1" >/dev/null 2>&1; [ $? = 2 ] && [ -n "$CMCR_LINK" ] && printf '%s\n' "$CMCR_LINK" )
    }
    cmcr_link_refusal() {
      local who; who="$(stat -f %Su "$1" 2>/dev/null)"
      if [ "$who" = root ]; then
        who="konto „root”, ale leży w folderze, który może zmieniać użytkownik (podstawiona kopia dowiązania systemowego)"
      else
        who="konto „${who}”, a nie przez system"
      fi
      echo "Odmowa: „$1” to dowiązanie symboliczne do „$(readlink "$1" 2>/dev/null)”, utworzone przez $who. Ze względów bezpieczeństwa CMCR Manager nie zapisuje ani nie usuwa plików przez dowiązania utworzone przez użytkowników – ktoś mógł je podstawić, żeby dostać się do plików innego konta. Usuń to dowiązanie (np. w Przeglądarce plików) i utwórz w tym miejscu zwykły folder." >&2
    }
    # The refusal after cmcr_walk returned 2 for PATH.
    cmcr_walk_refusal() {
      if [ -n "$CMCR_LINK" ]; then cmcr_link_refusal "$CMCR_LINK"
      else echo "Odmowa: folder $1 został podmieniony w trakcie sprawdzania (dowiązanie symboliczne)." >&2; fi
    }
    # Enters folder DIR through cmcr_walk and sets CMCR_PINNED (physical path) and CMCR_PINNED_ID (device:inode).
    # File operations then use paths relative to the current folder: the student owns the folders on the way and
    # could swap one for a link afterwards, but that cannot move the shell out of the folder it is in. Returns 2
    # (message on stderr) for a user's link or a swap, 1 when DIR cannot be entered (no message).
    cmcr_pin_dir() {
      cmcr_walk "$1"
      case $? in
        0) CMCR_PINNED="$(/bin/pwd -P)"; CMCR_PINNED_ID="$(stat -f %d:%i .)" ;;
        2) cmcr_walk_refusal "$1"; return 2 ;;
        *) return 1 ;;
      esac
    }
    # cmcr_pin_create DIR [OWNER] – cmcr_pin_dir for a folder that may not exist yet: enters the deepest existing
    # folder on the way, then creates the missing ones one at a time from inside their parent (owned by OWNER).
    cmcr_pin_create() {
      local p="$1" rest
      while [ ! -e "$p" ] && [ ! -L "$p" ]; do p="$(dirname "$p")"; done
      cmcr_pin_dir "$p" || return $?
      rest="${1#"$p"}"
      while [ "${rest#/}" != "$rest" ]; do rest="${rest#/}"; done
      [ -n "$rest" ] || return 0
      cmcr_walk "$rest" create "${2:-}"
      case $? in
        0) CMCR_PINNED="$(/bin/pwd -P)"; CMCR_PINNED_ID="$(stat -f %d:%i .)" ;;
        2) cmcr_walk_refusal "$1"; return 2 ;;
        *) return 1 ;;
      esac
    }
    """#

    /// First line the wrapper writes to stderr. Until it arrives nothing has run on the Mac, so a failure is
    /// safe to retry and a cancel needs no remote stop; SSH.run removes it from the output.
    public static let startMarker = "CMCR:SESSION-STARTED"

    /// Full script text that is executed by `/bin/bash` on the remote side.
    public func render() -> String {
        let tag = "CMCR_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let job = RemoteJobs.isValidID(jobID) ? jobID ?? "" : ""
        var s = #"""
        echo \#(Self.startMarker) >&2
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
            // On exit the root shell deletes what it created and hands the rest back to the admin, so the
            // cleanup needs no second sudo and a large extracted payload is not walked twice.
            s += #"""
            if [ "$(id -u)" -ne 0 ] && [ -z "$CMCR_PW" ] && ! sudo -n true 2>/dev/null; then
              echo "Brak hasła administratora – zapisz je w Konfiguracji (wymagane do sudo)." >&2; exit 91
            fi
            ( trap - PIPE; printf '%s\n' "$CMCR_PW" | asroot /bin/bash --noprofile --norc -c 'IFS= read -r CMCR_PW; CMCR_TMP="$1"; export CMCR_TMP; trap "" HUP; trap "find \"\$CMCR_TMP\" -mindepth 1 -maxdepth 1 ! -user $2 -exec rm -rf {} + 2>/dev/null; chown -hR $2 \"\$CMCR_TMP\" 2>/dev/null" EXIT; trap "exit 143" TERM INT; if [ -n "$3" ]; then echo "$$" > "$3.root"; fi; source "$CMCR_TMP/lib.sh"; source "$CMCR_TMP/body.sh"' cmcr "$CMCR_TMP" "$UID" "$CMCR_JOB_FILE" )

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
        return Self.avoidingMuxWindow("/bin/bash --noprofile --norc -c \"$(echo \(b64) | base64 -D)\"")
    }

    /// Through a shared connection (ControlMaster) macOS refuses to pass the session's descriptors when the
    /// request ends just below a multiple of 8 KiB of the local socket buffer ("mm_send_fd: sendmsg(2): Message
    /// too long" for commands of about 8104–8150, 16300–16345, 24490–24535… bytes; the exact spot moves with
    /// the environment variables ssh sends). A command near such a boundary gets trailing spaces – ignored by
    /// the remote shell – that move it safely past it, so the shared connection is used instead of a retry.
    static func avoidingMuxWindow(_ command: String) -> String {
        let block = 8192, before = 600, after = 150
        let length = command.utf8.count
        guard length >= 2048 else { return command }
        let offset = length % block
        guard offset >= block - before || offset < after else { return command }
        let boundary = offset < after ? length - offset : length - offset + block
        return command + String(repeating: " ", count: boundary + after + 50 - length)
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
        // Only trusted host keys (HostTrust): a Mac that was never confirmed is refused before any login, so
        // the password on stdin and in askpass never reaches a device that merely answers to its name.
        o += ["-o", "ConnectTimeout=\(s.connectTimeout)"] + HostTrust.strictOptions(s)
        o += [
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
    ///   command on the Mac, and a timeout does the same (only once it started there). A lost connection
    ///   does not stop it.
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

        let started = OutputFlag()
        var cancelToken: UUID?
        if let handle, let id = script.jobID {
            cancelToken = handle.addCancelAction {
                // Before the wrapper starts there is nothing to stop, and the Mac may not even be reachable.
                guard started.isSet else {
                    onOutput?(.stderr, Data("▸ Polecenie nie zostało uruchomione na komputerze.\n".utf8))
                    return
                }
                let outcome = await cancelRemote(jobID: id, on: host, password: password, settings: settings)
                onOutput?(.stderr, Data("▸ \(outcome.message)\n".utf8))
            }
            if cancelToken == nil { return .cancelledResult }
        }
        defer { if let cancelToken { handle?.removeCancelAction(cancelToken) } }

        let stdin = Data(((password ?? "") + "\n").utf8)
        let command = script.remoteCommand()
        var r = await runWithRetry(on: host, settings: settings, retry: retry, handle: handle, stdoutFile: stdoutFile,
                                   started: started, onOutput: onOutput) { mux, output in
            await ProcessRunner.run(sshPath, options(settings, password: password, mux: mux)
                                        + ["-T", "-p", String(host.port), host.destination, command],
                                    environment: environment(settings, password: password), stdin: stdin,
                                    stdoutFile: stdoutFile, timeout: timeout, maxCapture: maxCapture,
                                    handle: handle, onOutput: output)
        }
        r.started = started.isSet
        if r.timedOut, !r.cancelled, started.isSet, let id = script.jobID, handle != nil {
            let outcome = await cancelRemote(jobID: id, on: host, password: password, settings: settings)
            let note = Data("▸ Przekroczono limit czasu. \(outcome.message)\n".utf8)
            onOutput?(.stderr, note)
            r.stderr.append(note)
        }
        return r
    }

    /// Runs `attempt` (with connection sharing first) and repeats it after failures that happened before
    /// the remote command could start. ssh noise about shared connections and the wrapper's start marker
    /// are removed from the output.
    ///
    /// A remote script has started once its start marker (or any stdout) arrived; from then on nothing is
    /// retried, whatever ssh reports. `started` is set at that moment.
    static func runWithRetry(
        on host: Machine,
        settings: SSHSettings,
        retry: SSHRetryPolicy,
        handle: ProcessHandle?,
        stdoutFile: URL?,
        isCopy: Bool = false,
        started: OutputFlag? = nil,
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
                if channel == .stdout || SSHNoise.containsStartMarker(data) {
                    seen.set()
                    started?.set()
                }
                let clean = channel == .stderr ? SSHNoise.filter(data) : data
                if !clean.isEmpty { onOutput?(channel, clean) }
            }
            var r = await attempt(mux, output)
            let began = seen.isSet || !r.stdout.isEmpty || r.truncated || SSHNoise.containsStartMarker(r.stderr)
                || stdoutFile.map { Payload.size(of: $0) > 0 } ?? false
            if began { started?.set() }
            let failure = began ? nil : connectFailure(r, sshExitOnly: !isCopy)
            // Keep ssh's raw message when it is all there is to explain a failed connection.
            let clean = SSHNoise.filter(r.stderr)
            if began || r.exitCode != 255 || !String(decoding: clean, as: UTF8.self).allSatisfy(\.isWhitespace) {
                r.stderr = clean
            }
            guard let failure, handle?.isCancelled != true, !Task.isCancelled else { return r }
            switch failure {
            case .transient, .sharedConnection, .brokenSharedConnection:
                guard transientLeft > 0 else { return r }
                transientLeft -= 1
            case .unreachable:
                guard unreachableLeft > 0 else { return r }
                unreachableLeft -= 1
            }
            round += 1
            if failure == .sharedConnection || failure == .brokenSharedConnection, mux {
                // A full shared connection is left alone (its sessions keep running); a broken one is closed.
                if failure == .brokenSharedConnection { await closeMaster(host, settings: settings) }
                mux = false
            }
            onOutput?(.stderr, Data("▸ Ponowna próba połączenia (\(round))…\n".utf8))
            let delay: Double = failure == .unreachable ? (round == 1 ? 2 : 5) : Double.random(in: 0.2...0.8)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if handle?.isCancelled == true || Task.isCancelled { return .cancelledResult }
        }
    }

    enum ConnectFailure: Equatable { case transient, sharedConnection, brokenSharedConnection, unreachable }

    /// Classifies ssh failures of a session that never started (`runWithRetry` checks that first), i.e. the
    /// ones that are safe to retry. ssh reports its own failures with exit code 255; scp exits with 1 and
    /// passes ssh's message through.
    static func connectFailure(_ r: CommandResult, sshExitOnly: Bool = true) -> ConnectFailure? {
        guard sshExitOnly ? r.exitCode == 255 : r.exitCode != 0 else { return nil }
        guard !r.timedOut, !r.cancelled, r.stdout.isEmpty else { return nil }
        let e = r.stderrText.lowercased()
        if e.contains("permission denied") || e.contains("host key") || e.contains("authentication failures") {
            return nil
        }
        if e.contains("session open refused by peer") {
            return .sharedConnection
        }
        // Handing the session's descriptors to the shared connection failed (macOS refuses the fd message when
        // the request nearly fills the socket buffer). The connection itself is fine: retry without it, keep it.
        if e.contains("mm_send_fd") || e.contains("send fds failed") {
            return .sharedConnection
        }
        if e.contains("mux_client_") || e.contains("control socket connect") {
            return .brokenSharedConnection
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
        // An untrusted key is shown with its fingerprint and accepted only when the user types "yes" in Terminal.
        a += ["-p", String(host.port)] + HostTrust.strictOptions(settings, mode: "ask")
        a += ["-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"]
        a += muxOptions(settings)
        if !settings.identityFile.isEmpty { a += ["-i", expandTilde(settings.identityFile)] }
        return a + [host.destination]
    }

    /// The `.command` file Terminal runs for cmcr-go. Host fields come from the host list (possibly an imported
    /// file), so every one of them is quoted: the banner is printed with printf '%s' (zsh's echo would also
    /// interpret backslashes) and nothing in the script is expanded by the shell.
    public static func terminalScript(for host: Machine, settings: SSHSettings) -> String {
        let args = interactiveArguments(for: host, settings: settings).map(shQuote).joined(separator: " ")
        return """
        #!/bin/zsh
        clear
        printf '%s\\n' \(shQuote("cmcr-go → \(host.destination)"))
        exec /usr/bin/ssh \(args)

        """
    }

    /// File name for the cmcr-go script: the Mac's name with anything but letters, digits, `-`, `_` and `.`
    /// replaced (a name such as "Sala 3/iMac" must not become a path), never hidden or empty.
    public static func terminalFileName(for host: Machine) -> String {
        let safe = String(host.name.unicodeScalars.map { s -> Character in
            s.isASCII && (CharacterSet.alphanumerics.contains(s) || "-_.".unicodeScalars.contains(s)) ? Character(s) : "_"
        })
        let base = safe.isEmpty || safe.hasPrefix(".") || safe.allSatisfy({ $0 == "_" }) ? host.id.uuidString : safe
        return "cmcr-go-\(base).command"
    }

    /// Retires the shared connection to a Mac (after it restarted, its key changed or the settings changed).
    ///
    /// `-O stop`, not `-O exit`: the connection stops taking new sessions and its socket is removed, but
    /// sessions already running on it (jobs, screen captures, Terminal windows) finish normally. The next
    /// operation opens a fresh connection.
    public static func closeMaster(_ host: Machine, settings: SSHSettings) async {
        guard let dir = controlDirectory(),
              let sockets = try? FileManager.default.contentsOfDirectory(atPath: dir), !sockets.isEmpty else { return }
        var s = settings
        s.reuseConnections = true
        let args = options(s, password: nil) + ["-O", "stop", "-p", String(host.port), host.destination]
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
        if r.timedOut {
            // Once the script ran on the Mac, the Mac answered: the command was just too slow.
            return r.started ? (.online, "Przekroczono limit czasu – polecenie działało na komputerze zbyt długo.")
                : (.offline, "Przekroczono limit czasu.")
        }
        if !r.started, let refusal = HostTrust.refusal(r) {
            switch refusal {
            case .unknown:
                return (.error, "Klucz SSH tego komputera nie jest jeszcze zaufany – połączenie przerwano przed logowaniem, "
                        + "hasło nie zostało wysłane. Sprawdź odcisk klucza i zaufaj mu: Konfiguracja › Przygotowanie iMaców "
                        + "› Szybkie naprawy › Sprawdź klucz komputera.")
            case .changed:
                return (.error, "Klucz SSH komputera się zmienił – połączenie przerwano przed logowaniem, hasło nie zostało "
                        + "wysłane. Jeśli ten iMac był reinstalowany lub wymieniony, sprawdź nowy klucz: Konfiguracja › "
                        + "Przygotowanie iMaców › Szybkie naprawy › Sprawdź klucz komputera. W przeciwnym razie ktoś może "
                        + "podszywać się pod ten komputer.")
            }
        }
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
            if lower.contains("kex_exchange_identification") || lower.contains("banner exchange") {
                return (.error, "Serwer SSH chwilowo odrzucił połączenie (zbyt wiele jednoczesnych połączeń) – spróbuj ponownie.")
            }
            if lower.contains("mm_send_fd") || lower.contains("send fds failed") {
                return (.error, "Nie udało się przekazać sesji przez wspólne połączenie SSH – spróbuj ponownie.")
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
