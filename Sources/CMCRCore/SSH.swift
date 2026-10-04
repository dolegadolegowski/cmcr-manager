import Foundation

/// A bash script executed on a remote Mac over SSH.
///
/// The script is shipped base64-encoded on the ssh command line, so no quoting is needed, and the admin
/// password travels as the first line of stdin (never in argv or on disk). Every body can use:
/// - `asroot cmd…`          – run as root (sudo with the password supplied through SUDO_ASKPASS),
/// - `as_console_user cmd…` – run inside the GUI session of the user logged in at the screen,
/// - `with_askpass cmd…`    – run a tool that calls `sudo -A` itself (e.g. Homebrew),
/// - `$CONSOLE_USER`, `$CONSOLE_UID`, `$CMCR_ADMIN_USER`, `$CMCR_TMP` (private temp dir, removed on exit).
public struct RemoteScript: Sendable {
    public var body: String
    public var asRoot: Bool

    public init(_ body: String, asRoot: Bool = false) {
        self.body = body
        self.asRoot = asRoot
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
        var s = #"""
        IFS= read -r CMCR_PW || CMCR_PW=""
        CMCR_TMP="$(mktemp -d /tmp/cmcr.XXXXXX)" || { echo "mktemp nie powiódł się" >&2; exit 90; }
        export CMCR_TMP
        cmcr_cleanup() {
          if [ -n "$(find "$CMCR_TMP" ! -user "$(id -u)" -print -quit 2>/dev/null)" ]; then asroot rm -rf "$CMCR_TMP" 2>/dev/null; fi
          rm -rf "$CMCR_TMP" 2>/dev/null
        }
        trap cmcr_cleanup EXIT
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
        if asRoot {
            s += #"""
            if [ "$(id -u)" -ne 0 ] && [ -z "$CMCR_PW" ] && ! sudo -n true 2>/dev/null; then
              echo "Brak hasła administratora – zapisz je w Konfiguracji (wymagane do sudo)." >&2; exit 91
            fi
            printf '%s\n' "$CMCR_PW" | asroot /bin/bash -c 'IFS= read -r CMCR_PW; CMCR_TMP="$1"; export CMCR_TMP; source "$CMCR_TMP/lib.sh"; source "$CMCR_TMP/body.sh"' cmcr "$CMCR_TMP"

            """#
        } else {
            s += "source \"$CMCR_TMP/body.sh\"\n"
        }
        return s
    }

    /// Command line handed to ssh (interpreted by the remote login shell).
    public func remoteCommand() -> String {
        let b64 = Data(render().utf8).base64EncodedString()
        return "/bin/bash -c \"$(echo \(b64) | base64 -D)\""
    }
}

public struct SSHSettings: Sendable {
    public var identityFile: String
    public var connectTimeout: Int
    public var extraOptions: [String]
    public var askpassPath: String

    public init(identityFile: String = "", connectTimeout: Int = 5, extraOptions: [String] = [], askpassPath: String) {
        self.identityFile = identityFile
        self.connectTimeout = connectTimeout
        self.extraOptions = extraOptions
        self.askpassPath = askpassPath
    }

    public init(_ s: AppSettings, askpassPath: String) {
        self.init(identityFile: s.identityFile, connectTimeout: s.connectTimeout,
                  extraOptions: s.extraSSHOptionList, askpassPath: askpassPath)
    }
}

public enum SSH {
    public static let sshPath = "/usr/bin/ssh"
    public static let scpPath = "/usr/bin/scp"

    static func options(_ s: SSHSettings, password: String?) -> [String] {
        var o = [
            "-o", "ConnectTimeout=\(s.connectTimeout)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "LogLevel=ERROR",
        ]
        if let pw = password, !pw.isEmpty {
            o += ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"]
        } else {
            o += ["-o", "BatchMode=yes"]
        }
        let identity = expandTilde(s.identityFile)
        if !s.identityFile.isEmpty { o += ["-i", identity] }
        for extra in s.extraOptions { o += ["-o", extra] }
        return o
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
    public static func run(
        _ script: RemoteScript,
        on host: Machine,
        password: String?,
        settings: SSHSettings,
        stdoutFile: URL? = nil,
        timeout: TimeInterval? = nil,
        handle: ProcessHandle? = nil,
        onOutput: (@Sendable (OutputChannel, Data) -> Void)? = nil
    ) async -> CommandResult {
        let args = options(settings, password: password)
            + ["-T", "-p", String(host.port), host.destination, script.remoteCommand()]
        let stdin = Data(((password ?? "") + "\n").utf8)
        return await ProcessRunner.run(sshPath, args, environment: environment(settings, password: password),
                                       stdin: stdin, stdoutFile: stdoutFile, timeout: timeout,
                                       handle: handle, onOutput: onOutput)
    }

    /// Copies local files to a remote path with scp (cmcr-push transport).
    public static func upload(
        _ files: [URL],
        to remotePath: String,
        on host: Machine,
        password: String?,
        settings: SSHSettings,
        handle: ProcessHandle? = nil
    ) async -> CommandResult {
        let args = ["-q", "-r", "-p", "-P", String(host.port)] + options(settings, password: password)
            + files.map(\.path) + ["\(host.destination):\(remotePath)"]
        return await ProcessRunner.run(scpPath, args, environment: environment(settings, password: password),
                                       handle: handle)
    }

    /// Arguments for an interactive session (cmcr-go).
    public static func interactiveArguments(for host: Machine, settings: SSHSettings) -> [String] {
        var a = ["-p", String(host.port), "-o", "StrictHostKeyChecking=accept-new"]
        if !settings.identityFile.isEmpty { a += ["-i", expandTilde(settings.identityFile)] }
        for extra in settings.extraOptions { a += ["-o", extra] }
        return a + [host.destination]
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
