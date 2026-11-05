import Foundation

// Screen preview (view only): the remote capture script, its line/frame protocol and both transports –
// a single capture over `SSH.run` (CLI, "save screenshot") and a long-lived stream used by the app.

public extension ScriptCode {
    /// The capture needs sudo (only root may ask another account's screen agent) and sudo failed: no stored password,
    /// a wrong one, or no rights.
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
                  interval: interval ?? settings.screenshotInterval, notify: notify ?? true,
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
    /// CMCR Screen Agent is not installed on this iMac (docs/screen-agent.md).
    case agentMissing
    /// The agent is installed but did not answer in the user's session, even after launchd restarted it (detail).
    case agentDown(String)
    /// Something other than the installed agent answered on its socket – no image is taken from it (detail).
    case agentUntrusted(String)
    /// The agent has no Screen Recording permission on this iMac yet.
    case agentPermission
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
        case .captureFailed: return "Zrzut ekranu nieudany"
        case .agentMissing: return "Brak usługi podglądu"
        case .agentDown: return "Usługa podglądu nie odpowiada"
        case .agentUntrusted: return "Niezaufana usługa podglądu"
        case .agentPermission: return "Brak uprawnienia do nagrywania ekranu"
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
            return "Konto, którym łączy się aplikacja, nie może używać sudo (nie jest administratorem tego iMaca)."
        case .captureFailed(let detail):
            let base = "Usługa podglądu nie zrobiła zrzutu ekranu."
            return detail.isEmpty ? base : "\(base) (\(detail))"
        case .agentMissing:
            return "Na tym iMacu nie ma usługi podglądu ekranu (\(ScreenAgentInfo.displayName)). Zainstaluj ją: Konfiguracja › Przygotowanie iMaców › Szybkie naprawy › Zainstaluj usługę podglądu (albo Skonfiguruj zaznaczone)."
        case .agentDown(let detail):
            let base = "Usługa podglądu (\(ScreenAgentInfo.displayName)) nie odpowiada w sesji zalogowanego użytkownika, także po ponownym uruchomieniu. Zainstaluj ją ponownie w Konfiguracja › Przygotowanie iMaców."
            return detail.isEmpty ? base : "\(base) (\(detail))"
        case .agentUntrusted(let detail):
            let base = "Na gnieździe usługi podglądu odpowiada inny program niż zainstalowana usługa – obraz nie jest pobierany. Zainstaluj usługę ponownie w Konfiguracja › Przygotowanie iMaców."
            return detail.isEmpty ? base : "\(base) (\(detail))"
        case .agentPermission:
            return "Usługa podglądu nie ma jeszcze uprawnienia do nagrywania ekranu. Przy tym iMacu: Ustawienia systemowe › Prywatność i ochrona › Nagrywanie ekranu i dźwięku systemowego › włącz „\(ScreenAgentInfo.displayName)”. Konfiguracja › Przygotowanie iMaców › „Poproś o uprawnienie” dodaje usługę do tej listy i pokazuje okno macOS przy komputerze."
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
        case .agentMissing, .agentDown: return "puzzlepiece.extension"
        case .agentUntrusted: return "exclamationmark.shield"
        case .agentPermission: return "rectangle.dashed.badge.record"
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
        case .captureFailed, .agentPermission: return ScriptCode.captureFailed
        case .agentMissing, .agentDown, .agentUntrusted: return ScriptCode.agentUnavailable
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
        case "agent-missing": self = .agentMissing
        case "agent-down": self = .agentDown(detail)
        case "agent-untrusted": self = .agentUntrusted(detail)
        case "agent-perm": self = .agentPermission
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
    /// The notice is on the screen of `user`; `session` identifies the login (what `alreadyNotifiedUser` takes).
    case notified(user: String, session: String)
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
            // An older script sends only the account; it then stands for the session too.
            return optional(2).map { .notified(user: $0, session: optional(3) ?? $0) }
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
    /// The picture comes from CMCR Screen Agent (docs/screen-agent.md), which runs in the user's GUI session and is
    /// the process macOS gives the Screen Recording permission to; this script only asks it (`cmcr-screen-agent client
    /// <uid> notice|capture …`) and streams the file it saved. It runs unprivileged when the SSH account is the one
    /// logged in at the screen (and its agent's folder `run/<uid>` exists); otherwise the loop is re-executed once as
    /// root (only root may talk to another account's agent, restart it and make its folder), so a whole stream costs a
    /// single sudo. The console user is re-read on every cycle; a user
    /// who has not been told yet in this login session is notified once before the first capture.
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
        SCR_NOTICE_T=\#(Data(observeNoticeTitle.utf8).base64EncodedString())
        SCR_NOTICE_X=\#(Data(observeNoticeText.utf8).base64EncodedString())
        R="${CMCR_SETUP_ROOT_PREFIX:-}"
        \#(screenAgentShellPaths)
        \#(screenAgentShellFunctions)
        \#(screenCaptureApprovalShell)
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
        scr_allowed() {
          # Nobody at the screen: whoever logs in next is told again (AUDIT ZAJ-04).
          if [ -z "$CONSOLE_USER" ]; then CMCR_LAST=""; scr_emit STATE nouser; SCR_RC=\#(ScriptCode.noConsoleUser); return 1; fi
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
        # One command for the agent in the console user's session (`client <uid> …`): its answer is in
        # $SCR_DIR/agent.out, the exit code in SCR_AGENT_RC and its own words in SCR_AGENT_ERR. The client talks only to
        # the process launchd runs for that session (--pid). An agent that does not answer (code 10: not running, no
        # socket, refused, no answer in time) is loaded or restarted by launchd and asked once more; it keeps the screen
        # untouched until it is asked.
        scr_agent() {
          local again=0
          while :; do
            cmcr_agent_client "$CONSOLE_UID" "$@" </dev/null >"$SCR_DIR/agent.out" 2>"$SCR_DIR/agent.err"
            SCR_AGENT_RC=$?
            [ "$SCR_AGENT_RC" = \#(ScreenAgentInfo.ClientCode.unreachable) ] && [ $again = 0 ] || break
            again=1
            cmcr_agent_revive "$CONSOLE_UID" 5
          done
          SCR_AGENT_CODE="$(sed -n 's/^ERR \([^ ]*\).*/\1/p' "$SCR_DIR/agent.out" 2>/dev/null | head -n 1)"
          SCR_AGENT_ERR="$(sed -n 's/^ERR [^ ]* *//p' "$SCR_DIR/agent.out" 2>/dev/null | head -n 1)"
          [ -n "$SCR_AGENT_ERR" ] || SCR_AGENT_ERR="$(grep -v '^ *$' "$SCR_DIR/agent.err" 2>/dev/null | head -n 1)"
          return "$SCR_AGENT_RC"
        }
        # What a failed agent command (notice or capture) means for the app; always fails.
        scr_agent_failed() {
          local detail="$SCR_AGENT_ERR"
          case "$SCR_AGENT_CODE" in
            asleep) detail="ekran jest uśpiony" ;;
            notconsole) detail="sesja użytkownika nie jest na pierwszym planie (szybkie przełączanie użytkowników)" ;;
            nodisplay) detail="brak ekranu" ;;
          esac
          [ -n "$detail" ] || detail="usługa podglądu zakończyła się kodem $SCR_AGENT_RC"
          case "$SCR_AGENT_RC" in
            \#(ScreenAgentInfo.ClientCode.unreachable)) scr_emit STATE agent-down "$CONSOLE_USER" "$SCR_AGENT_ERR"; SCR_RC=\#(ScriptCode.agentUnavailable) ;;
            \#(ScreenAgentInfo.ClientCode.untrusted)) scr_emit STATE agent-untrusted "$CONSOLE_USER" "$SCR_AGENT_ERR"; SCR_RC=\#(ScriptCode.agentUnavailable) ;;
            \#(ScreenAgentInfo.ClientCode.noPermission)) scr_emit STATE agent-perm "$CONSOLE_USER" "$SCR_AGENT_ERR"; SCR_RC=\#(ScriptCode.captureFailed) ;;
            \#(ScreenAgentInfo.ClientCode.locked))
              # Nobody sees a notice on a locked screen, and no image is taken without one (AUDIT ZAJ-05).
              scr_emit STATE notify "$CONSOLE_USER" "ekran jest zablokowany – komunikat zostanie pokazany po jego odblokowaniu"
              SCR_RC=\#(ScriptCode.observeNotNotified) ;;
            *)
              if [ "$1" = notice ]; then scr_emit STATE notify "$CONSOLE_USER" "$detail"; SCR_RC=\#(ScriptCode.observeNotNotified)
              else scr_emit STATE capture "$CONSOLE_USER" "$detail"; SCR_RC=\#(ScriptCode.captureFailed); fi ;;
          esac
          return 1
        }
        # The login session at the screen: the account and its loginwindow process, which macOS starts anew for
        # every login. Logging out and in again – also to the same shared student account – is someone new at
        # the screen, who is told again (AUDIT ZAJ-04).
        scr_session() {
          local p=""
          [ -n "$CONSOLE_UID" ] && p="$(pgrep -u "$CONSOLE_UID" -x loginwindow 2>/dev/null | head -n 1)"
          SCR_SESSION="$CONSOLE_USER${p:+#$p}"
        }
        # Tells a user who was not told yet that the screen is being viewed: the agent shows a small panel in the top
        # right corner of every display for a few seconds (no Notification Center permission, Focus does not hide it)
        # and confirms it is on screen. Without that confirmation the user counts as not notified: nothing is
        # captured (STATE notify) and the next cycle tries again.
        scr_notify() {
          local state detail
          [ "$CMCR_NOTIFY" = 1 ] || return 0
          scr_session
          [ "$SCR_SESSION" = "$CMCR_LAST" ] && return 0
          # A screen covered by the attention-mode lock hides the panel: nobody could read it (AUDIT ZAJ-05).
          # The overlay counts only in the session at the screen (it runs as that user): the auto-unlock timer of
          # lockScreen (root) carries the tag too and outlives a logout, and a lock left in a session in the
          # background covers nothing here (AUDIT REV-08).
          if pgrep -x LockScreen >/dev/null 2>&1 \
             || { [ -n "$CONSOLE_UID" ] && pgrep -u "$CONSOLE_UID" -f "CMCR_ATT""ENTION" >/dev/null 2>&1; }; then
            scr_emit STATE notify "$CONSOLE_USER" "ekran jest zablokowany w trybie uwagi – komunikat zostanie pokazany po odblokowaniu"
            SCR_RC=\#(ScriptCode.observeNotNotified)
            return 1
          fi
          scr_agent notice "$SCR_NOTICE_T" "$SCR_NOTICE_X" || { scr_agent_failed notice; return 1; }
          state="$(sed -n 's/^NOTICE \([a-z]*\).*/\1/p' "$SCR_DIR/agent.out" 2>/dev/null | head -n 1)"
          case "$state" in
            shown)
              CMCR_LAST="$SCR_SESSION"
              scr_emit NOTIFIED "$CONSOLE_USER" "$SCR_SESSION"
              return 0 ;;
            locked) detail="ekran jest zablokowany lub uśpiony – komunikat zostanie pokazany po jego odblokowaniu" ;;
            hidden) detail="okno komunikatu nie pojawiło się na ekranie" ;;
            *) detail="usługa podglądu nie potwierdziła wyświetlenia komunikatu" ;;
          esac
          scr_emit STATE notify "$CONSOLE_USER" "$detail"
          SCR_RC=\#(ScriptCode.observeNotNotified)
          return 1
        }
        # Sends one display the agent saved, skipped when unchanged. The agent's JPEG already has the requested size
        # and quality. Read once into a private copy: another preview of the same account (the app and cmcrctl at
        # once) may replace the agent's file meanwhile, and the hash must belong to the bytes sent.
        scr_send() {
          local d="$1" n="$2" src="$3" out="$SCR_DIR/out$1.jpg" hash size
          { [ -f "$src" ] && [ ! -L "$src" ] && cat "$src" > "$out" 2>/dev/null && [ -s "$out" ]; } || return 1
          hash="$(md5 -q "$out" 2>/dev/null)"
          if [ "$SCR_FORCE" != 1 ] && [ -n "$hash" ] && [ "$hash" = "${SCR_HASH[$d]:-}" ]; then
            scr_emit SAME "$d" "$n" "$hash"; return 0
          fi
          SCR_HASH[$d]="$hash"
          size="$(wc -c < "$out" | tr -d ' ')"
          scr_emit FRAME "$d" "$n" "$size" "$hash"
          cat "$out" 2>/dev/null || exit 0
        }
        # macOS 15+: replayd's remembered consent for the agent is renewed before the first capture of every account
        # (and hourly), so the person at the screen never gets the "…requesting to bypass the system private window
        # picker" alert (cmcr_sc_approval, the CMCR-REPLAYD block of setup/cmcr-imac-setup.sh). Best effort: without
        # Full Disk Access for remote users the file cannot be written and the capture goes on as before.
        scr_approval() {
          local h
          if [ "${SCR_APPROVED_FOR-x}" = "$CONSOLE_USER" ] && [ $((SECONDS - SCR_APPROVED_AT)) -lt 3600 ]; then return 0; fi
          SCR_APPROVED_FOR="$CONSOLE_USER"; SCR_APPROVED_AT=$SECONDS
          [ -n "${SCR_OS:-}" ] || SCR_OS="$(sw_vers -productVersion 2>/dev/null)"
          h="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -n 1)"
          SCR_APPROVAL="$(cmcr_sc_approval "$CONSOLE_USER" "${h:+${CMCR_SETUP_ROOT_PREFIX:-}$h}" "$SCR_OS" </dev/null 2>/dev/null)"
        }
        # One capture by the agent: `FRONT <app>`, then `SHOT <n> <width> <height> <bytes> <file>` per display, each
        # file replacing the previous capture of that display. Reports INFO (with the frontmost app) and the frames.
        scr_capture() {
          local line tag d w h b f front="" n=0 sent=0 i
          scr_approval
          if ! scr_agent capture "$CMCR_MAXSIZE" "$CMCR_QUALITY" "$CMCR_DISPLAY"; then
            scr_emit INFO "$CONSOLE_USER" ""
            scr_agent_failed capture
            return 1
          fi
          while IFS= read -r line; do
            case "$line" in
              FRONT) front="" ;;
              FRONT\ *) front="${line#FRONT }" ;;
              SHOT\ *)
                read -r tag d w h b f <<<"$line"
                case "$d" in [1-9]) ;; *) continue ;; esac
                [ -n "$f" ] || continue
                SCR_SHOT_D[$n]="$d"; SCR_SHOT_F[$n]="$f"; n=$((n + 1)) ;;
            esac
          done < "$SCR_DIR/agent.out"
          scr_emit INFO "$CONSOLE_USER" "$front"
          i=0
          while [ $i -lt $n ]; do
            scr_send "${SCR_SHOT_D[$i]}" "$n" "${SCR_SHOT_F[$i]}" && sent=$((sent + 1))
            i=$((i + 1))
          done
          if [ $sent = 0 ]; then
            scr_emit STATE capture "$CONSOLE_USER" "usługa podglądu nie zapisała zrzutu ekranu"
            SCR_RC=\#(ScriptCode.captureFailed); return 1
          fi
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
            if scr_allowed; then
              if [ ! -x "$CMCR_AGENT_EXE" ]; then
                # Nothing on this iMac can take the picture; no sudo is spent on finding that out.
                scr_emit INFO "$CONSOLE_USER" ""
                scr_emit STATE agent-missing "$CONSOLE_USER"
                SCR_RC=\#(ScriptCode.agentUnavailable); SCR_FAILS=$((SCR_FAILS + 1))
              else
                # Someone else is logged in: from now on the agent is asked as root (the caller re-executes the loop).
                # So too when the agent's own folder is missing or not as it should be (an account that logged in after
                # the install, something left at its name): only root can make it, and the agent cannot start without it.
                if [ "${CMCR_SCREEN_ROLE:-}" != root ] && [ "$SCR_ME" != 0 ] \
                   && { [ "$CONSOLE_UID" != "$SCR_ME" ] || ! cmcr_agent_rundir_ok "$CONSOLE_UID"; }; then return 7; fi
                if scr_notify; then
                  if scr_capture; then SCR_FAILS=0; else SCR_FAILS=$((SCR_FAILS + 1)); fi
                else
                  # Not told about the observation: neither the screen nor the frontmost app is read.
                  scr_emit INFO "$CONSOLE_USER" ""
                  SCR_FAILS=$((SCR_FAILS + 1))
                fi
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
          case $rc in 0|3|4|5|\#(ScriptCode.observeNotNotified)|\#(ScriptCode.agentUnavailable)) return $rc ;; esac
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

    /// The notice the agent shows to an observed user before the first capture of their login session.
    static let observeNoticeTitle = "Podgląd ekranu"
    static let observeNoticeText = "Administrator rozpoczął podgląd Twojego ekranu."

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
        /// Their login session, to pass as `alreadyNotifiedUser` to the next capture.
        public var notifiedSession: String?
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
        // Room for one sudo and, at worst, an agent that launchd has to start again before the notice and the capture.
        let r = await SSH.run(Scripts.screenCapture(options), on: host, password: password, settings: sshSettings,
                              timeout: 60, handle: handle)
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
            case .notified(let user, let session):
                shot.notifiedUser = user
                shot.notifiedSession = session
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
        if let refused = SSH.refusal(for: host) {
            onExit(refused)
            return
        }
        var opts = options
        opts.frames = 0
        let args = SSH.options(settings, password: password)
            + ["-T", "-p", String(host.port), "--", host.destination, Scripts.screenCapture(opts).remoteCommand()]
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
        // The wrapper's start and end markers (and ssh's noise about shared connections) are not the script's message.
        return SSHNoise.filter(stderrTail)
    }
}
