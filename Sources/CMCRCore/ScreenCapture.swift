import Foundation

// Screen preview (view only): the remote capture script, its line/frame protocol and both transports –
// a single capture over `SSH.run` (CLI, "save screenshot") and a long-lived stream used by the app.

public extension ScriptCode {
    /// The capture needs sudo (`launchctl asuser`) and sudo failed: no stored password, a wrong one, or no rights.
    static let captureSudoFailed: Int32 = 6
    /// The observed user could not be shown the "your screen is being viewed" notice, so nothing was captured.
    static let observeNotNotified: Int32 = 8
}

/// Which display of the observed Mac is captured.
public enum ScreenDisplay: Hashable, Sendable, Codable {
    case main
    case all
    case number(Int)

    public var scriptValue: String {
        switch self {
        case .main: return "main"
        case .all: return "all"
        case .number(let n): return String(min(9, max(1, n)))
        }
    }

    public init?(scriptValue: String) {
        switch scriptValue {
        case "main": self = .main
        case "all": self = .all
        default:
            guard let n = Int(scriptValue), (1...9).contains(n) else { return nil }
            self = .number(n)
        }
    }

    public var label: String {
        switch self {
        case .main: return "Ekran główny"
        case .all: return "Wszystkie ekrany"
        case .number(let n): return "Ekran \(n)"
        }
    }
}

/// Parameters of one capture session (single frame or stream).
public struct ScreenCaptureOptions: Sendable, Equatable {
    public var maxSize: Int
    public var quality: Int
    public var interval: Int
    /// Show the "your screen is being viewed" notification to a console user who was not told yet.
    public var notify: Bool
    /// Console user already notified in this observation session; not notified again.
    public var alreadyNotifiedUser: String?
    public var onlyStandardAccounts: Bool
    public var allowedUsers: [String]
    public var display: ScreenDisplay
    /// Number of capture cycles before the script ends; 0 streams until the app closes stdin.
    public var frames: Int
    /// A stream ends after this many seconds (the app reconnects transparently).
    public var maxDuration: Int

    public init(maxSize: Int, quality: Int = 60, interval: Int = 10, notify: Bool = true,
                alreadyNotifiedUser: String? = nil, onlyStandardAccounts: Bool = true, allowedUsers: [String] = [],
                display: ScreenDisplay = .main, frames: Int = 1, maxDuration: Int = 3600) {
        self.maxSize = maxSize
        self.quality = quality
        self.interval = interval
        self.notify = notify
        self.alreadyNotifiedUser = alreadyNotifiedUser
        self.onlyStandardAccounts = onlyStandardAccounts
        self.allowedUsers = allowedUsers
        self.display = display
        self.frames = frames
        self.maxDuration = maxDuration
    }

    /// Options carrying the observation restrictions from the app settings.
    public init(settings: AppSettings, maxSize: Int? = nil, interval: Int? = nil, notify: Bool? = nil,
                alreadyNotifiedUser: String? = nil, display: ScreenDisplay = .main, frames: Int = 1) {
        self.init(maxSize: maxSize ?? settings.screenshotMaxSize, quality: settings.screenshotQuality,
                  interval: interval ?? settings.screenshotInterval, notify: notify ?? settings.notifyOnObserve,
                  alreadyNotifiedUser: alreadyNotifiedUser, onlyStandardAccounts: settings.observeOnlyStandardAccounts,
                  allowedUsers: settings.observeAllowedUserList, display: display, frames: frames)
    }

    public static func clampedSize(_ px: Int) -> Int { min(5120, max(320, px)) }
    public static func clampedInterval(_ s: Int) -> Int { min(3600, max(2, s)) }
}

/// Why no current image can be shown.
public enum ScreenIssue: Equatable, Sendable {
    case noUser
    case userNotAllowed(String)
    case adminAccount(String)
    case sudoPasswordMissing
    case sudoPasswordWrong
    case sudoNotPermitted
    case captureFailed(String)
    /// The observation notice could not be shown to this user, so the screen is not captured (user, detail).
    case notifyFailed(String, String)
    case connection(Reachability, String)
    case other(String)

    /// Nothing is wrong – the restrictions or the login window simply leave nothing to show.
    public var isIdle: Bool {
        switch self {
        case .noUser, .userNotAllowed, .adminAccount: return true
        default: return false
        }
    }

    /// The image must not stay on screen (another user, a session the restrictions exclude, or a user who
    /// was not told about the observation).
    public var hidesImage: Bool {
        if case .notifyFailed = self { return true }
        return isIdle
    }

    public var title: String {
        switch self {
        case .noUser: return "Nikt nie jest zalogowany"
        case .userNotAllowed, .adminAccount: return "Podgląd zablokowany"
        case .sudoPasswordMissing: return "Brak hasła administratora"
        case .sudoPasswordWrong: return "Błędne hasło administratora"
        case .sudoNotPermitted: return "Konto bez uprawnień sudo"
        case .captureFailed: return "Brak uprawnienia do nagrywania ekranu"
        case .notifyFailed: return "Nie udało się powiadomić ucznia"
        case .connection(let r, _): return r == .offline ? "Komputer nie odpowiada" : r == .authFailed ? "Odmowa dostępu" : "Błąd połączenia"
        case .other: return "Błąd podglądu"
        }
    }

    public var message: String {
        switch self {
        case .noUser:
            return "Nikt nie jest zalogowany (okno logowania)."
        case .userNotAllowed(let u):
            return "Konto \(u) nie jest na liście kont dozwolonych do podglądu."
        case .adminAccount(let u):
            return "Zalogowane konto administratora (\(u)) – podgląd zablokowany przez ograniczenia."
        case .sudoPasswordMissing:
            return "Podgląd konta ucznia wymaga sudo: zapisz hasło administratora (Konfiguracja › Dostęp i hasła) albo włącz sudo bez hasła skryptem przygotowującym iMaca."
        case .sudoPasswordWrong:
            return "Błędne hasło administratora (sudo) – popraw je w Konfiguracji › Dostęp i hasła."
        case .sudoNotPermitted:
            return "Konto, którym łączy się aplikacja, nie może używać sudo (nie jest administratorem tego Maca)."
        case .captureFailed(let detail):
            let base = "Zrzut ekranu nieudany. Na tym Macu nadaj sesjom SSH uprawnienie „Nagrywanie ekranu i dźwięku systemowego”: Ustawienia systemowe › Prywatność i ochrona › „+” › /usr/libexec/sshd-keygen-wrapper (w nowszych macOS może być potrzebne także /usr/libexec/sshd-session). Konfiguracja › Przygotowanie iMaców pokazuje, czy działa."
            return detail.isEmpty ? base : "\(base) (\(detail))"
        case .notifyFailed(let user, let detail):
            let base = "Na ekranie użytkownika \(user) nie udało się wyświetlić informacji o podglądzie, więc obraz nie jest pobierany. Kolejna próba przy następnym odświeżeniu."
            return detail.isEmpty ? base : "\(base) (\(detail))"
        case .connection(_, let message), .other(let message):
            return message
        }
    }

    public var symbol: String {
        switch self {
        case .noUser: return "person.crop.circle.badge.questionmark"
        case .userNotAllowed, .adminAccount: return "eye.slash"
        case .sudoPasswordMissing, .sudoPasswordWrong, .sudoNotPermitted: return "key.slash"
        case .captureFailed: return "rectangle.dashed.badge.record"
        case .notifyFailed: return "bell.slash"
        case .connection(let r, _): return r == .offline ? "wifi.slash" : "exclamationmark.triangle"
        case .other: return "exclamationmark.triangle"
        }
    }

    /// Exit code of a single capture with this outcome.
    public var exitCode: Int32 {
        switch self {
        case .noUser: return ScriptCode.noConsoleUser
        case .userNotAllowed, .adminAccount: return ScriptCode.observeDenied
        case .sudoPasswordMissing, .sudoPasswordWrong, .sudoNotPermitted: return ScriptCode.captureSudoFailed
        case .captureFailed: return ScriptCode.captureFailed
        case .notifyFailed: return ScriptCode.observeNotNotified
        case .connection, .other: return 1
        }
    }

    init?(stateCode code: String, user: String, detail: String) {
        switch code {
        case "nouser": self = .noUser
        case "denied": self = .userNotAllowed(user.isEmpty ? "?" : user)
        case "admin": self = .adminAccount(user.isEmpty ? "?" : user)
        case "sudo-missing": self = .sudoPasswordMissing
        case "sudo-wrong": self = .sudoPasswordWrong
        case "sudo-denied": self = .sudoNotPermitted
        case "capture": self = .captureFailed(detail)
        case "notify": self = .notifyFailed(user.isEmpty ? "?" : user, detail)
        case "error": self = .other(detail.isEmpty ? "Błąd skryptu podglądu." : detail)
        default: return nil
        }
    }
}

/// One message of the capture protocol.
public enum ScreenEvent: Equatable, Sendable {
    /// The capture loop started; `privileged` when it runs as root (one sudo for the whole session).
    case hello(privileged: Bool)
    case info(user: String?, frontApp: String?)
    case frame(display: Int, count: Int, hash: String, data: Data)
    /// The display looks exactly like the last frame sent for it.
    case unchanged(display: Int, count: Int, hash: String)
    case state(ScreenIssue)
    case notified(user: String)
    case bye(reason: String)
}

/// Incremental parser of the capture protocol: tab-separated `CMCR1` lines on stdout, a `FRAME` line being
/// followed by exactly `<bytes>` of JPEG data. Anything else on stdout is ignored.
public struct ScreenStreamParser: Sendable {
    static let prefix = "CMCR1"
    static let maxLine = 16 * 1024
    static let maxFrame = 64 * 1024 * 1024

    private var buffer = Data()
    private var pending: (display: Int, count: Int, hash: String, length: Int)?

    public init() {}

    public mutating func feed(_ chunk: Data) -> [ScreenEvent] {
        buffer.append(chunk)
        var events: [ScreenEvent] = []
        while true {
            if let p = pending {
                guard buffer.count >= p.length else { break }
                let data = Data(buffer.prefix(p.length))
                buffer.removeFirst(p.length)
                pending = nil
                events.append(.frame(display: p.display, count: p.count, hash: p.hash, data: data))
                continue
            }
            guard let nl = buffer.firstIndex(of: 0x0A) else {
                if buffer.count > Self.maxLine { buffer.removeAll(keepingCapacity: false) }
                break
            }
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let e = parseLine(line) { events.append(e) }
        }
        if buffer.isEmpty { buffer = Data() }
        return events
    }

    private mutating func parseLine(_ raw: String) -> ScreenEvent? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 2, f[0] == Self.prefix else { return nil }
        func field(_ i: Int) -> String { i < f.count ? f[i].trimmingCharacters(in: .whitespaces) : "" }
        func optional(_ i: Int) -> String? { let v = field(i); return v.isEmpty ? nil : v }
        switch f[1] {
        case "HELLO":
            return .hello(privileged: field(2) == "root")
        case "INFO":
            return .info(user: optional(2), frontApp: optional(3))
        case "FRAME":
            guard let display = Int(field(2)), let count = Int(field(3)), let length = Int(field(4)),
                  length >= 0, length <= Self.maxFrame else { return nil }
            if length == 0 { return .frame(display: display, count: count, hash: field(5), data: Data()) }
            pending = (display, count, field(5), length)
            return nil
        case "SAME":
            guard let display = Int(field(2)) else { return nil }
            return .unchanged(display: display, count: Int(field(3)) ?? 1, hash: field(4))
        case "STATE":
            return ScreenIssue(stateCode: field(2), user: field(3), detail: field(4)).map { .state($0) }
        case "NOTIFIED":
            return optional(2).map { .notified(user: $0) }
        case "BYE":
            return .bye(reason: field(2))
        default:
            return nil
        }
    }
}

/// Control commands understood by a running capture stream (one line each on its stdin).
public enum ScreenStreamCommand: Equatable, Sendable {
    case now
    case size(Int)
    case interval(Int)
    case display(ScreenDisplay)
    case pause
    case resume
    case quit

    var line: String {
        switch self {
        case .now: return "now"
        case .size(let px): return "size \(ScreenCaptureOptions.clampedSize(px))"
        case .interval(let s): return "interval \(ScreenCaptureOptions.clampedInterval(s))"
        case .display(let d): return "display \(d.scriptValue)"
        case .pause: return "pause"
        case .resume: return "resume"
        case .quit: return "quit"
        }
    }
}

public extension Scripts {
    /// Captures the console user's screen as JPEG, honouring the observation restrictions.
    ///
    /// Runs unprivileged when the SSH account is the one logged in at the screen; otherwise the capture loop
    /// is re-executed once as root (`launchctl asuser` needs it), so a whole stream costs a single sudo.
    /// The console user and the frontmost application are re-read on every cycle; a user who has not been
    /// told yet in this observation session is notified once before the first capture.
    static func screenCapture(_ o: ScreenCaptureOptions) -> RemoteScript {
        RemoteScript(#"""
        CMCR_MAXSIZE=\#(ScreenCaptureOptions.clampedSize(o.maxSize))
        CMCR_QUALITY=\#(min(100, max(10, o.quality)))
        CMCR_INTERVAL=\#(ScreenCaptureOptions.clampedInterval(o.interval))
        CMCR_FRAMES=\#(max(0, o.frames))
        CMCR_MAXTIME=\#(max(60, o.maxDuration))
        CMCR_ALLOWED=\#(shQuote(o.allowedUsers.joined(separator: ",")))
        CMCR_ONLYSTD=\#(o.onlyStandardAccounts ? 1 : 0)
        CMCR_NOTIFY=\#(o.notify ? 1 : 0)
        CMCR_LAST=\#(shQuote(o.alreadyNotifiedUser ?? ""))
        CMCR_DISPLAY=\#(shQuote(o.display.scriptValue))
        SCR_NOTICE="$(echo \#(Data(observeNoticeJXA().utf8).base64EncodedString()) | base64 -D)"
        if [ -n "${SCR_IN_SET:-}" ]; then
          CMCR_MAXSIZE="$SCR_IN_SIZE"; CMCR_INTERVAL="$SCR_IN_INTERVAL"; CMCR_DISPLAY="$SCR_IN_DISPLAY"; CMCR_LAST="$SCR_IN_LAST"
        fi

        scr_emit() {
          local line="CMCR1" f
          for f in "$@"; do
            f="${f//$'\t'/ }"; f="${f//$'\n'/ }"; f="${f//$'\r'/ }"
            line="$line"$'\t'"$f"
          done
          printf '%s\n' "$line" 2>/dev/null || exit 0
        }
        scr_console() {
          CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null)"
          case "$CONSOLE_USER" in root|_mbsetupuser|loginwindow) CONSOLE_USER="" ;; esac
          if [ "$CONSOLE_USER" != "${SCR_UID_FOR-x}" ]; then
            CONSOLE_UID=""
            if [ -n "$CONSOLE_USER" ]; then CONSOLE_UID="$(id -u "$CONSOLE_USER" 2>/dev/null)"; fi
            SCR_UID_FOR="$CONSOLE_USER"
          fi
        }
        # Runs a tool in the console user's GUI session: directly when that is us, else through launchctl (root).
        scr_gui() {
          if [ "$SCR_ME" = "$CONSOLE_UID" ]; then "${1##*/}" "${@:2}"; else launchctl asuser "$CONSOLE_UID" "$@"; fi
        }
        scr_gui_user() {
          if [ "$SCR_ME" = "$CONSOLE_UID" ]; then "${1##*/}" "${@:2}"; else launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" -- "$@"; fi
        }
        scr_allowed() {
          if [ -z "$CONSOLE_USER" ]; then scr_emit STATE nouser; SCR_RC=\#(ScriptCode.noConsoleUser); return 1; fi
          if [ -n "$CMCR_ALLOWED" ]; then
            case ",$CMCR_ALLOWED," in
              *",$CONSOLE_USER,"*) ;;
              *) scr_emit STATE denied "$CONSOLE_USER"; SCR_RC=\#(ScriptCode.observeDenied); return 1 ;;
            esac
          fi
          if [ "$CMCR_ONLYSTD" = 1 ]; then
            if [ "${SCR_ADMIN_FOR-x}" != "$CONSOLE_USER" ] || [ $((SCR_N % 30)) = 0 ]; then
              SCR_ADMIN_FOR="$CONSOLE_USER"; SCR_IS_ADMIN=0
              if is_admin_user "$CONSOLE_USER"; then SCR_IS_ADMIN=1; fi
            fi
            if [ "$SCR_IS_ADMIN" = 1 ]; then scr_emit STATE admin "$CONSOLE_USER"; SCR_RC=\#(ScriptCode.observeDenied); return 1; fi
          fi
          return 0
        }
        # Stops a process and everything it started, children first: the wrapper subshell of a notice, the
        # launchctl/sudo under it and the osascript itself. They stay in the script's process group, so a job
        # cancel still reaches them too.
        scr_kill_tree() {
          local c
          for c in $(pgrep -P "$1" 2>/dev/null); do scr_kill_tree "$c"; done
          kill "$1" 2>/dev/null
        }
        # Tells a user who was not told yet that the screen is being viewed. The notice is a small panel drawn by
        # osascript in the user's session (Scripts.observeNoticeJXA): unlike `display notification` it needs no
        # Notification Center permission and Focus does not hide it, and it confirms that it is on screen
        # (CMCR:NOTICE:shown). Without that confirmation the user counts as not notified: nothing is captured
        # (STATE notify) and the next cycle tries again.
        scr_notify() {
          [ "$CMCR_NOTIFY" = 1 ] || return 0
          [ "$CONSOLE_USER" = "$CMCR_LAST" ] && return 0
          local out err pid i=0 state="" rc="" detail="" why
          # Fresh files per attempt: a late answer of an earlier attempt must not count for this one.
          SCR_NOTICE_N=$((${SCR_NOTICE_N:-0} + 1))
          rm -f "$SCR_DIR"/notice.* 2>/dev/null
          out="$SCR_DIR/notice.$SCR_NOTICE_N.out"; err="$SCR_DIR/notice.$SCR_NOTICE_N.err"
          : > "$out"; : > "$err"
          scr_gui_user /usr/bin/osascript -l JavaScript -e "$SCR_NOTICE" CMCR_OBSERVE_NOTICE </dev/null >"$out" 2>"$err" &
          pid=$!
          # The panel stays up for a few seconds after it answers; only its answer is awaited (≤ 6 s).
          while [ $i -lt 60 ]; do
            state="$(sed -n 's/^CMCR:NOTICE://p' "$out" 2>/dev/null | head -n 1)"
            [ -n "$state" ] && break
            if ! kill -0 "$pid" 2>/dev/null; then
              wait "$pid" 2>/dev/null; rc=$?
              state="$(sed -n 's/^CMCR:NOTICE://p' "$out" 2>/dev/null | head -n 1)"
              break
            fi
            sleep 0.1; i=$((i + 1))
          done
          if [ "$state" = shown ]; then
            CMCR_LAST="$CONSOLE_USER"
            scr_emit NOTIFIED "$CONSOLE_USER"
            return 0
          fi
          if [ "$state" = hidden ]; then detail="okno komunikatu nie pojawiło się na ekranie"
          elif [ -n "$rc" ]; then detail="osascript zakończył się kodem $rc"
          else
            # A hung osascript must not outlive the attempt (each cycle would leave one more behind).
            scr_kill_tree "$pid"; wait "$pid" 2>/dev/null
            detail="brak potwierdzenia wyświetlenia w ciągu 6 s"
          fi
          why="$(grep -v '^ *$' "$err" 2>/dev/null | head -n 1)"
          [ -n "$why" ] && detail="$detail: $why"
          scr_emit STATE notify "$CONSOLE_USER" "$detail"
          SCR_RC=\#(ScriptCode.observeNotNotified)
          return 1
        }
        scr_front() {
          local asn raw
          SCR_FRONT=""
          asn="$(scr_gui_user /usr/bin/lsappinfo front </dev/null 2>/dev/null)"
          case "$asn" in ASN:*) ;; *) return 0 ;; esac
          raw="$(scr_gui_user /usr/bin/lsappinfo info -only name "$asn" </dev/null 2>/dev/null)"
          SCR_FRONT="$(printf '%s\n' "$raw" | sed -n -e 's/^"LSDisplayName"="\(.*\)"[[:space:]]*$/\1/p' -e 's/^"\([^"]*\)" ASN:.*/\1/p' | head -n 1)"
        }
        # Sends one captured display: resized only when larger than requested, skipped when unchanged.
        scr_send() {
          local d="$1" n="$2" raw="$3" out hash size
          out="$raw"
          if [ -z "${SCR_DIM[$d]:-}" ] || [ $((SCR_N % 30)) = 0 ]; then
            SCR_DIM[$d]="$(sips -g pixelWidth -g pixelHeight "$raw" 2>/dev/null | awk '/pixel(Width|Height)/ { if ($2 > m) m = $2 } END { print m + 0 }')"
          fi
          if [ "${SCR_DIM[$d]:-0}" -gt "$CMCR_MAXSIZE" ]; then
            out="$SCR_DIR/out$d.jpg"
            sips -s format jpeg -s formatOptions "$CMCR_QUALITY" -Z "$CMCR_MAXSIZE" "$raw" --out "$out" >/dev/null 2>&1 || out="$raw"
          fi
          hash="$(md5 -q "$out" 2>/dev/null)"
          if [ "$SCR_FORCE" != 1 ] && [ -n "$hash" ] && [ "$hash" = "${SCR_HASH[$d]:-}" ]; then
            scr_emit SAME "$d" "$n" "$hash"; return 0
          fi
          SCR_HASH[$d]="$hash"
          size="$(wc -c < "$out" | tr -d ' ')"
          scr_emit FRAME "$d" "$n" "$size" "$hash"
          cat "$out" 2>/dev/null || exit 0
        }
        scr_capture() {
          local i n files f
          rm -f "$SCR_DIR"/raw*.jpg "$SCR_DIR"/out*.jpg 2>/dev/null
          case "$CMCR_DISPLAY" in
            main) scr_gui /usr/sbin/screencapture -x -C -m -t jpg "$SCR_DIR/raw1.jpg" ;;
            all) scr_gui /usr/sbin/screencapture -x -C -t jpg "$SCR_DIR/raw1.jpg" "$SCR_DIR/raw2.jpg" "$SCR_DIR/raw3.jpg" "$SCR_DIR/raw4.jpg" ;;
            *) scr_gui /usr/sbin/screencapture -x -C -D "$CMCR_DISPLAY" -t jpg "$SCR_DIR/raw$CMCR_DISPLAY.jpg" ;;
          esac </dev/null >/dev/null 2>"$SCR_DIR/err"
          files=""; n=0
          for i in 1 2 3 4 5 6 7 8 9; do
            if [ -s "$SCR_DIR/raw$i.jpg" ]; then files="$files $i"; n=$((n + 1)); fi
          done
          if [ $n = 0 ]; then
            scr_emit STATE capture "$CONSOLE_USER" "$(head -n 1 "$SCR_DIR/err" 2>/dev/null)"
            SCR_RC=\#(ScriptCode.captureFailed); return 1
          fi
          for f in $files; do scr_send "$f" "$n" "$SCR_DIR/raw$f.jpg"; done
          SCR_RC=0
        }
        # Applies one control line from the app; succeeds when a capture should follow right away.
        scr_command() {
          local v
          case "$1" in
            now) SCR_FORCE=1; return 0 ;;
            size\ *) v="${1#size }"
              case "$v" in ''|*[!0-9]*) return 1 ;; esac
              [ "$v" -ge 160 ] || return 1
              CMCR_MAXSIZE="$v"; SCR_FORCE=1; return 0 ;;
            interval\ *) v="${1#interval }"
              case "$v" in ''|*[!0-9]*) return 1 ;; esac
              [ "$v" -ge 1 ] && CMCR_INTERVAL="$v"; return 1 ;;
            display\ *) v="${1#display }"
              case "$v" in main|all|[1-9]) CMCR_DISPLAY="$v"; SCR_FORCE=1; return 0 ;; esac; return 1 ;;
            pause) SCR_PAUSED=1; return 1 ;;
            resume) SCR_PAUSED=0; SCR_FORCE=1; return 0 ;;
            quit) scr_emit BYE quit; exit 0 ;;
          esac
          return 1
        }
        # Waits for the next cycle while listening for commands; fails once the app has closed the stream.
        scr_wait() {
          local t rs line wait="$CMCR_INTERVAL" start=$SECONDS
          if [ "${SCR_FAILS:-0}" -ge 3 ]; then wait=$((CMCR_INTERVAL * 3)); fi
          while :; do
            if [ "$SCR_PAUSED" = 1 ]; then
              IFS= read -r line || return 1
              if scr_command "$line"; then return 0; fi
              start=$SECONDS; continue
            fi
            t=$((wait - (SECONDS - start)))
            [ "$t" -le 0 ] && return 0
            rs=$SECONDS
            if IFS= read -r -t "$t" line; then
              if scr_command "$line"; then return 0; fi
              wait="$CMCR_INTERVAL"
            else
              # bash 3.2 reports a timeout and end of input alike – only end of input returns early.
              [ $((SECONDS - rs)) -lt "$t" ] && return 1
              return 0
            fi
          done
        }
        scr_loop() {
          trap '' PIPE
          SCR_ME="$(id -u)"; SCR_N=0; SCR_START=$SECONDS; SCR_FORCE=1; SCR_PAUSED=0; SCR_RC=0; SCR_FAILS=0
          SCR_DIR="$CMCR_TMP/screen.$SCR_ME"
          mkdir -p "$SCR_DIR" 2>/dev/null
          if [ "${CMCR_SCREEN_ROLE:-}" = root ]; then trap 'rm -rf "$SCR_DIR"' EXIT; fi
          if [ "${CMCR_SCREEN_ROLE:-}" = root ]; then scr_emit HELLO root "$SCR_ME"; else scr_emit HELLO user "$SCR_ME"; fi
          while :; do
            if [ $((SECONDS - SCR_START)) -ge "$CMCR_MAXTIME" ]; then scr_emit BYE maxtime; return 0; fi
            scr_console
            SCR_FRONT=""
            if scr_allowed; then
              # Someone else is logged in: from now on the capture needs root (the caller re-executes the loop).
              if [ "${CMCR_SCREEN_ROLE:-}" != root ] && [ "$SCR_ME" != 0 ] && [ "$CONSOLE_UID" != "$SCR_ME" ]; then return 7; fi
              if scr_notify; then
                scr_front
                scr_emit INFO "$CONSOLE_USER" "$SCR_FRONT"
                if scr_capture; then SCR_FAILS=0; else SCR_FAILS=$((SCR_FAILS + 1)); fi
              else
                # Not told about the observation: neither the screen nor the frontmost app is read.
                scr_emit INFO "$CONSOLE_USER" ""
                SCR_FAILS=$((SCR_FAILS + 1))
              fi
            else
              scr_emit INFO "$CONSOLE_USER" ""
            fi
            SCR_N=$((SCR_N + 1))
            if [ "$CMCR_FRAMES" -gt 0 ] && [ "$SCR_N" -ge "$CMCR_FRAMES" ]; then return "$SCR_RC"; fi
            SCR_FORCE=0
            scr_wait || return 0
          done
        }
        # Re-executes the loop as root; a failing sudo is reported as such, not as a capture problem.
        scr_run_root() {
          local rc reason
          asroot /bin/bash --noprofile --norc -c 'CMCR_TMP="$1"; export CMCR_TMP; CMCR_SCREEN_ROLE=root; SCR_IN_SET=1; SCR_IN_SIZE="$2"; SCR_IN_INTERVAL="$3"; SCR_IN_DISPLAY="$4"; SCR_IN_LAST="$5"; source "$CMCR_TMP/lib.sh"; source "$CMCR_TMP/body.sh"' \
            cmcr "$CMCR_TMP" "$CMCR_MAXSIZE" "$CMCR_INTERVAL" "$CMCR_DISPLAY" "$CMCR_LAST" 2>"$CMCR_TMP/sudo.err"
          rc=$?
          case $rc in 0|3|4|5|\#(ScriptCode.observeNotNotified)) return $rc ;; esac
          if grep -qiE 'incorrect password|sorry, try again' "$CMCR_TMP/sudo.err" 2>/dev/null; then reason=sudo-wrong
          elif [ $rc = 91 ] || grep -qiE 'Brak hasła|password is required|no password was provided|terminal is required' "$CMCR_TMP/sudo.err" 2>/dev/null; then reason=sudo-missing
          elif grep -qiE 'not in the sudoers|not allowed to' "$CMCR_TMP/sudo.err" 2>/dev/null; then reason=sudo-denied
          else
            scr_emit STATE error "$CONSOLE_USER" "$(head -n 1 "$CMCR_TMP/sudo.err" 2>/dev/null) (kod $rc)"
            return 1
          fi
          scr_emit STATE "$reason" "$CONSOLE_USER"
          return \#(ScriptCode.captureSudoFailed)
        }

        if [ "${CMCR_SCREEN_ROLE:-}" = root ]; then
          scr_loop; exit $?
        fi
        scr_loop; RC=$?
        if [ $RC = 7 ]; then scr_run_root; exit $?; fi
        exit $RC
        """#)
    }

    static let observeNoticeTitle = "Podgląd ekranu"
    static let observeNoticeText = "Administrator rozpoczął podgląd Twojego ekranu."

    /// The observation notice: a panel in the top right corner of every display for `seconds`, drawn by
    /// `osascript -l JavaScript` in the observed user's session. It never takes the keyboard (non-activating
    /// panel of an accessory app, so macOS 14+ cooperative activation does not matter), ignores the mouse,
    /// shows over full-screen apps and needs no Notification Center permission. It prints
    /// `CMCR:NOTICE:shown` once the panel is on screen (`CMCR:NOTICE:hidden` otherwise) and quits by itself
    /// – the timer that ends it is set up before anything is reported. `--dry-run` builds the panels
    /// without showing them.
    static func observeNoticeJXA(title: String = observeNoticeTitle, text: String = observeNoticeText,
                                 seconds: Int = 8) -> String {
        """
        ObjC.import('Cocoa');
        function say(s) {
          $.NSFileHandle.fileHandleWithStandardOutput.writeData($(s + '\\n').dataUsingEncoding($.NSUTF8StringEncoding));
        }
        function run(argv) {
          var dry = argv.indexOf('--dry-run') >= 0;
          var app = $.NSApplication.sharedApplication;
          app.setActivationPolicy(1);
          var screens = $.NSScreen.screens;
          var panels = [];
          for (var i = 0; i < screens.count; i++) {
            var vf = screens.objectAtIndex(i).visibleFrame;
            var w = 420, h = 96, pad = 16;
            var rect = {origin: {x: vf.origin.x + vf.size.width - w - pad, y: vf.origin.y + vf.size.height - h - pad},
                        size: {width: w, height: h}};
            var p = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer(rect, 128, 2, false);
            p.setLevel(1001);
            p.setOpaque(false);
            p.setHasShadow(true);
            p.setIgnoresMouseEvents(true);
            p.setHidesOnDeactivate(false);
            p.setCollectionBehavior(1 | 16 | 64 | 256);
            p.setBackgroundColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(0.10, 0.12, 0.18, 0.96));
            var t = $.NSTextField.labelWithString(\(Scripts.jsLiteral(title)));
            t.setFont($.NSFont.boldSystemFontOfSize(16));
            t.setTextColor($.NSColor.whiteColor);
            t.setFrame({origin: {x: 18, y: h - 38}, size: {width: w - 36, height: 22}});
            p.contentView.addSubview(t);
            var m = $.NSTextField.wrappingLabelWithString(\(Scripts.jsLiteral(text)));
            m.setFont($.NSFont.systemFontOfSize(14));
            m.setTextColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(1.0, 1.0, 1.0, 0.88));
            m.setFrame({origin: {x: 18, y: 12}, size: {width: w - 36, height: h - 54}});
            p.contentView.addSubview(m);
            panels.push(p);
          }
          if (dry) { return 'panels=' + panels.length; }
          $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(\(max(2, seconds)), app, 'terminate:', null, false);
          var shown = false;
          for (var j = 0; j < panels.length; j++) {
            panels[j].orderFrontRegardless;
            if (panels[j].isVisible) { shown = true; }
          }
          say(shown ? 'CMCR:NOTICE:shown' : 'CMCR:NOTICE:hidden');
          if (!shown) { return; }
          app.run;
        }
        """
    }

    /// Single capture with the restrictions (kept for callers of the original API).
    static func screenshot(maxSize: Int, quality: Int, notify: Bool,
                           onlyStandard: Bool, allowedUsers: [String]) -> RemoteScript {
        screenCapture(ScreenCaptureOptions(maxSize: maxSize, quality: quality, notify: notify,
                                           onlyStandardAccounts: onlyStandard, allowedUsers: allowedUsers))
    }
}

/// One captured display.
public struct ScreenFrame: Sendable, Equatable {
    public var display: Int
    public var count: Int
    public var hash: String
    public var data: Data

    public init(display: Int, count: Int, hash: String, data: Data) {
        self.display = display
        self.count = count
        self.hash = hash
        self.data = data
    }
}

public extension Operations {
    struct Screenshot: Sendable {
        public var imageData: Data?
        public var user: String?
        public var message: String?
        public var frontApp: String?
        public var issue: ScreenIssue?
        /// Console user who got the observation notification during this capture.
        public var notifiedUser: String?
        /// Every captured display (`imageData` is the first one).
        public var frames: [ScreenFrame] = []
        public var privileged = false
    }

    /// Captures the screen of the logged-in user once, honouring the observation restrictions.
    static func screenshot(of host: Machine, maxSize: Int, settings appSettings: AppSettings, notify: Bool,
                           notifyUnless: String? = nil, display: ScreenDisplay = .main,
                           password: String?, sshSettings: SSHSettings,
                           handle: ProcessHandle? = nil) async -> Screenshot {
        let options = ScreenCaptureOptions(settings: appSettings, maxSize: maxSize, notify: notify,
                                           alreadyNotifiedUser: notifyUnless, display: display, frames: 1)
        let r = await SSH.run(Scripts.screenCapture(options), on: host, password: password, settings: sshSettings,
                              timeout: 45, handle: handle)
        return screenshot(from: r)
    }

    /// Interprets the output of a single-capture script run.
    static func screenshot(from r: CommandResult) -> Screenshot {
        var parser = ScreenStreamParser()
        var shot = Screenshot()
        for event in parser.feed(r.stdout) {
            switch event {
            case .hello(let privileged): shot.privileged = privileged
            case .info(let user, let front):
                shot.user = user
                shot.frontApp = front
            case .frame(let d, let n, let hash, let data):
                shot.frames.append(ScreenFrame(display: d, count: n, hash: hash, data: data))
            case .unchanged: break
            case .state(let issue): shot.issue = issue
            case .notified(let user): shot.notifiedUser = user
            case .bye: break
            }
        }
        shot.frames.sort { $0.display < $1.display }
        if let first = shot.frames.first(where: { !$0.data.isEmpty }), r.succeeded {
            shot.imageData = first.data
            shot.issue = nil
            return shot
        }
        if shot.issue == nil {
            if r.exitCode == ScriptCode.noConsoleUser && !r.timedOut && !r.cancelled {
                shot.issue = .noUser
            } else {
                let (reach, message) = SSH.diagnose(r)
                shot.issue = reach == .online && r.exitCode != 255 ? .other(message) : .connection(reach, message)
            }
        }
        shot.message = shot.issue?.message
        return shot
    }
}

/// A long-running capture session: one ssh connection (and at most one sudo) streaming frames until stopped.
///
/// Events and the exit are delivered on background queues. `send` and `stop` may be called from any thread.
public final class ScreenStream: @unchecked Sendable {
    public typealias EventHandler = @Sendable (ScreenEvent) -> Void
    public typealias ExitHandler = @Sendable (CommandResult) -> Void

    private let lock = NSLock()
    private let process = Process()
    private var stdinHandle: FileHandle?
    private var stderrTail = Data()
    private var stopping = false
    private var started = false

    public let host: Machine
    public let options: ScreenCaptureOptions

    public init(host: Machine, options: ScreenCaptureOptions) {
        self.host = host
        self.options = options
    }

    deinit {
        try? stdinHandle?.close()
        if started, process.isRunning { process.terminate() }
    }

    /// Only touched by the stdout handler, which FileHandle calls serially.
    private final class ParserBox: @unchecked Sendable {
        var value = ScreenStreamParser()
    }

    /// Starts ssh. `onExit` is called exactly once, also when ssh cannot be started.
    public func start(password: String?, settings: SSHSettings, onEvent: @escaping EventHandler,
                      onExit: @escaping ExitHandler) {
        var opts = options
        opts.frames = 0
        let args = SSH.options(settings, password: password)
            + ["-T", "-p", String(host.port), host.destination, Scripts.screenCapture(opts).remoteCommand()]
        process.executableURL = URL(fileURLWithPath: SSH.sshPath)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in SSH.environment(settings, password: password) { env[k] = v }
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        let eof = DispatchGroup()
        let parser = ParserBox()

        eof.enter()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                eof.leave()
                return
            }
            for e in parser.value.feed(d) { onEvent(e) }
        }
        eof.enter()
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                eof.leave()
                return
            }
            self?.appendStderr(d)
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.global().async {
                _ = eof.wait(timeout: .now() + 3)
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let stderr = self?.closeAndTakeStderr() ?? Data()
                let cancelled = self?.isStopping ?? true
                onExit(CommandResult(exitCode: p.terminationStatus, stderr: stderr, cancelled: cancelled))
            }
        }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let message = "Nie można uruchomić ssh: \(error.localizedDescription)"
            DispatchQueue.global().async { onExit(.failure(message)) }
            return
        }
        lock.lock()
        started = true
        stdinHandle = inPipe.fileHandleForWriting
        let alreadyStopping = stopping
        lock.unlock()
        // The remote wrapper reads the admin password from the first line; later lines are commands.
        write(Data(((password ?? "") + "\n").utf8))
        if alreadyStopping { stop() }
    }

    public func send(_ command: ScreenStreamCommand) {
        write(Data((command.line + "\n").utf8))
    }

    /// Ends the session gracefully (the remote loop sees end of input); ssh is terminated if it lingers.
    public func stop(grace: TimeInterval = 4) {
        lock.lock()
        stopping = true
        let h = stdinHandle
        stdinHandle = nil
        let wasStarted = started
        lock.unlock()
        try? h?.close()
        guard wasStarted else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    /// Terminates ssh immediately (e.g. a hung connection).
    public func kill() {
        lock.lock()
        stopping = true
        let h = stdinHandle
        stdinHandle = nil
        let wasStarted = started
        lock.unlock()
        try? h?.close()
        if wasStarted, process.isRunning { process.terminate() }
    }

    public var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let h = stdinHandle else { return }
        do {
            try h.write(contentsOf: data)
        } catch {
            try? h.close()
            stdinHandle = nil
        }
    }

    private func appendStderr(_ d: Data) {
        lock.lock()
        stderrTail.append(d)
        if stderrTail.count > 32_768 { stderrTail = Data(stderrTail.suffix(16_384)) }
        lock.unlock()
    }

    private func closeAndTakeStderr() -> Data {
        lock.lock()
        defer { lock.unlock() }
        try? stdinHandle?.close()
        stdinHandle = nil
        return stderrTail
    }
}
