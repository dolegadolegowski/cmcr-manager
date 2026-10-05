import Foundation

/// One column of the readiness matrix (Konfiguracja › Przygotowanie iMaców).
public enum ReadinessCheck: String, CaseIterable, Identifiable, Sendable {
    case ssh, sudo, folder, wol, vnc, screen, fda, filevault, setup

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ssh: return "SSH i klucz"
        case .sudo: return "sudo"
        case .folder: return "Folder ucznia"
        case .wol: return "Wake-on-LAN"
        case .vnc: return "Udostępnianie ekranu"
        case .screen: return "Nagrywanie ekranu"
        case .fda: return "Pełny dostęp do dysku"
        case .filevault: return "FileVault"
        case .setup: return "Konfiguracja"
        }
    }

    public var icon: String {
        switch self {
        case .ssh: return "key.horizontal"
        case .sudo: return "lock.shield"
        case .folder: return "folder"
        case .wol: return "dot.radiowaves.left.and.right"
        case .vnc: return "rectangle.on.rectangle"
        case .screen: return "record.circle"
        case .fda: return "externaldrive.badge.checkmark"
        case .filevault: return "lock.doc"
        case .setup: return "wrench.and.screwdriver"
        }
    }

    /// What the check means and why the app needs it (tooltips and the legend).
    public var explanation: String {
        switch self {
        case .ssh: return "Logowanie zdalne działa i klucz SSH tej aplikacji jest zainstalowany na koncie administratora (bez niego aplikacja loguje się hasłem)."
        case .sudo: return "Zapisane hasło administratora działa z sudo – potrzebne do instalacji, aktualizacji, podglądu ekranu ucznia i konfiguracji."
        case .folder: return "Folder współdzielony ucznia istnieje, należy do konta ucznia i można do niego zapisywać."
        case .wol: return "„Budź przy dostępie do sieci” – pozwala obudzić uśpionego iMaca z aplikacji."
        case .vnc: return "Udostępnianie ekranu (VNC) – opcjonalne, do pełnego zdalnego sterowania."
        case .screen: return "Uprawnienie „Nagrywanie ekranu” dla /usr/libexec/sshd-keygen-wrapper – bez niego podgląd ekranu pokazuje tylko tapetę. Nadaje się je ręcznie przy komputerze."
        case .fda: return "„Daj użytkownikom zdalnym pełny dostęp do dysku” – potrzebne do pobierania prac z Biurka i Dokumentów ucznia, czyszczenia folderów i podmiany aplikacji. Włącza się ręcznie przy komputerze."
        case .filevault: return "Z włączonym FileVault iMac po restarcie czeka na odblokowanie przy ekranie i jest niedostępny przez SSH."
        case .setup: return "Wersja skryptu konfiguracyjnego CMCR uruchomionego na tym iMacu."
        }
    }

    /// Steps that only a person at the iMac can complete (protected by macOS privacy controls).
    public var needsVisit: Bool { self == .screen || self == .fda }
}

public enum ReadinessState: String, Sendable, Comparable {
    case ok, off, unknown, manual, warning, problem

    private var rank: Int {
        switch self {
        case .ok: return 0
        case .off: return 1
        case .unknown: return 2
        case .manual: return 3
        case .warning: return 4
        case .problem: return 5
        }
    }

    public static func < (a: ReadinessState, b: ReadinessState) -> Bool { a.rank < b.rank }
}

public struct ReadinessItem: Sendable, Hashable {
    public var state: ReadinessState
    /// Short cell text, e.g. „OK”, „brak”, „ręcznie”.
    public var short: String
    /// Full explanation with the suggested fix.
    public var detail: String

    public init(_ state: ReadinessState, _ short: String, _ detail: String) {
        self.state = state
        self.short = short
        self.detail = detail
    }
}

/// Result of `Scripts.readiness` for one Mac.
public struct ReadinessReport: Sendable {
    /// Why a Mac could not be checked; decides which fix the SSH cell offers.
    public enum ConnectionFailure: String, Sendable {
        /// `hostKeyUnknown`: the Mac's key was never trusted (first contact) – see `HostTrust`.
        case hostKeyChanged, hostKeyUnknown, authFailed, offline, other
    }

    public var items: [ReadinessCheck: ReadinessItem]
    public var values: [String: String]
    public var checkedAt: Date
    /// Set only for a Mac that could not be reached.
    public var connectionFailure: ConnectionFailure?

    public var consoleUser: String? { values["console"].flatMap { $0.isEmpty ? nil : $0 } }
    public var setupVersion: String? { values["setup"].flatMap { $0.isEmpty || $0 == "none" ? nil : $0 } }

    public subscript(_ check: ReadinessCheck) -> ReadinessItem {
        items[check] ?? ReadinessItem(.unknown, "?", "Brak danych.")
    }

    /// Problems the setup script fixes remotely („Skonfiguruj zaznaczone”).
    public var fixableBySetup: [ReadinessCheck] {
        [ReadinessCheck.ssh, .folder, .wol, .setup].filter { [.problem, .warning].contains(self[$0].state) }
    }

    public var needsVisit: [ReadinessCheck] {
        ReadinessCheck.allCases.filter { self[$0].state == .manual }
    }

    public var isReady: Bool {
        ReadinessCheck.allCases.allSatisfy { [.ok, .off].contains(self[$0].state) }
    }

    /// Report for a Mac that could not be reached: only the SSH cell says why.
    public static func unreachable(_ message: String, date: Date = Date()) -> ReadinessReport {
        var items: [ReadinessCheck: ReadinessItem] = [:]
        for c in ReadinessCheck.allCases {
            items[c] = ReadinessItem(.unknown, "–", "Nie sprawdzono – brak połączenia z komputerem.")
        }
        items[.ssh] = ReadinessItem(.problem, "brak połączenia", message)
        return ReadinessReport(items: items, values: [:], checkedAt: date, connectionFailure: .other)
    }

    /// Report for a failed readiness run, classified from ssh's error output.
    public static func unreachable(_ result: CommandResult, date: Date = Date()) -> ReadinessReport {
        let (reachability, message) = SSH.diagnose(result)
        let failure: ConnectionFailure
        let short: String
        if let refusal = result.started ? nil : HostTrust.refusal(result) {
            failure = refusal == .changed ? .hostKeyChanged : .hostKeyUnknown
            short = refusal == .changed ? "zmieniony klucz" : "niezaufany klucz"
        } else {
            switch reachability {
            case .authFailed: failure = .authFailed; short = "odmowa dostępu"
            case .offline: failure = .offline; short = "nie odpowiada"
            default: failure = .other; short = "brak połączenia"
            }
        }
        var report = unreachable(message, date: date)
        report.items[.ssh]?.short = short
        report.connectionFailure = failure
        return report
    }

    /// macOS 15+ asks the logged-in user again from time to time whether the remote session may keep
    /// recording the screen (replayd's "bypass the system private window picker" alert). It appears on the
    /// student's screen and in the preview; the app cannot answer it.
    public static let screenCaptureAlertNote = "Od macOS 15 system co jakiś czas (zwykle raz w miesiącu, na niektórych Macach przy każdym nowym połączeniu) pokazuje osobie przy komputerze okno, że „sshd-session” / „sshd-keygen-wrapper” chce mieć dostęp do ekranu z pominięciem systemowego wyboru okien. Okno widać też w podglądzie. Podgląd działa dalej po zezwoleniu (po angielsku „Allow For One Month”); po odmowie albo „Otwórz Ustawienia systemowe” pokazuje tylko tapetę, dopóki ktoś nie zezwoli przy komputerze."

    public static func parse(_ text: String, student: String, sharedFolder: String,
                             expectedVersion: String = SetupScript.version, date: Date = Date()) -> ReadinessReport {
        let v = Parsers.keyValues(text)
        var items: [ReadinessCheck: ReadinessItem] = [:]
        let sudoWorks = ["root", "nopasswd", "ok"].contains(v["sudo"] ?? "")

        switch v["key"] {
        case "ok": items[.ssh] = ReadinessItem(.ok, "klucz", "Połączenie działa, klucz SSH aplikacji jest zainstalowany.")
        case "missing": items[.ssh] = ReadinessItem(.warning, "hasło",
            "Połączenie działa, ale klucz SSH tej aplikacji nie jest zainstalowany – logowanie hasłem. Napraw: „Skonfiguruj zaznaczone” albo „Roześlij klucz SSH”.")
        default: items[.ssh] = ReadinessItem(.ok, "połączono",
            "Połączenie działa. Na tym Macu nie ma jeszcze klucza SSH aplikacji (Dostęp i hasła › Wygeneruj nowy klucz), więc nie sprawdzono, czy jest zainstalowany.")
        }

        switch v["sudo"] {
        case "root", "ok": items[.sudo] = ReadinessItem(.ok, "OK", "sudo działa z zapisanym hasłem administratora.")
        case "nopasswd": items[.sudo] = ReadinessItem(.ok, "bez hasła", "sudo działa bez hasła (reguła NOPASSWD na tym iMacu).")
        case "nopassword": items[.sudo] = ReadinessItem(.unknown, "brak hasła",
            "Nie zapisano hasła administratora – zapisz je w Konfiguracja › Dostęp i hasła. Bez sudo nie da się sprawdzić uprawnień nagrywania ekranu ani skonfigurować iMaca.")
        case "notadmin": items[.sudo] = ReadinessItem(.problem, "nie admin",
            "Konto \(v["admin"] ?? "SSH") nie jest administratorem tego iMaca – aplikacja potrzebuje konta z uprawnieniami administratora.")
        case "badpassword": items[.sudo] = ReadinessItem(.problem, "złe hasło",
            "sudo odrzuciło zapisane hasło administratora. Popraw je w Konfiguracja › Dostęp i hasła (wspólne lub własne hasło komputera).")
        default: items[.sudo] = ReadinessItem(.problem, "błąd", "sudo nie działa: \(v["sudo_error"].flatMap { $0.isEmpty ? nil : $0 } ?? "nieznany błąd").")
        }

        let folder = v["folder"] ?? ""
        if folder == "ok" {
            items[.folder] = ReadinessItem(.ok, "OK", "\(sharedFolder) należy do \(student) i jest zapisywalny.")
        } else if folder == "missing" {
            items[.folder] = ReadinessItem(.problem, "brak", "Brak folderu \(sharedFolder). Napraw: „Skonfiguruj zaznaczone”.")
        } else if folder == "nohome" {
            items[.folder] = ReadinessItem(.manual, "ręcznie",
                "Uczeń „\(student)” jeszcze nigdy nie zalogował się na tym iMacu, więc nie ma folderu domowego (tworzy go macOS przy pierwszym logowaniu). Zaloguj się raz na konto ucznia przy komputerze, a potem użyj „Skonfiguruj zaznaczone”.")
        } else if folder == "nostudent" {
            items[.folder] = ReadinessItem(.problem, "brak konta",
                "Na tym iMacu nie ma konta ucznia „\(student)”. Utwórz je w Ustawieniach (Użytkownicy i grupy) albo popraw nazwę w Konfiguracja › Ustawienia.")
        } else if folder.hasPrefix("perm") {
            let p = folder.split(separator: " ")
            let owner = p.count > 1 ? String(p[1]) : "?", mode = p.count > 2 ? String(p[2]) : "?"
            items[.folder] = ReadinessItem(.warning, "uprawnienia",
                "\(sharedFolder): właściciel \(owner), uprawnienia \(mode) – uczeń może nie móc zapisywać. Napraw: „Skonfiguruj zaznaczone”.")
        } else {
            items[.folder] = ReadinessItem(.unknown, "?", "Nie udało się sprawdzić folderu \(sharedFolder).")
        }

        switch v["wol"] {
        case "on": items[.wol] = ReadinessItem(.ok, "włączony", "„Budź przy dostępie do sieci” jest włączone.")
        case "off": items[.wol] = ReadinessItem(.problem, "wyłączony", "Wake-on-LAN jest wyłączony – aplikacja nie obudzi tego iMaca. Napraw: „Skonfiguruj zaznaczone”.")
        default: items[.wol] = ReadinessItem(.unknown, "n/d", "Ten komputer nie obsługuje budzenia przez sieć.")
        }

        if v["vnc"] == "on" {
            items[.vnc] = ReadinessItem(.ok, "włączone", "Udostępnianie ekranu działa. Jeśli połączenie pokazuje czarny ekran, wyłącz i włącz je raz w Ustawieniach przy komputerze.")
        } else {
            items[.vnc] = ReadinessItem(.off, "wyłączone", "Udostępnianie ekranu (VNC) jest wyłączone – opcjonalne. Włączysz je opcją w „Skonfiguruj zaznaczone”.")
        }

        let tccReadable = v["tcc"] == "readable"
        // The preflight runs through the same process chain as the preview (launchctl asuser from the SSH
        // session), so it is right whichever SSH binary macOS holds responsible (sshd-keygen-wrapper, or
        // sshd-session since OpenSSH 9.8). The TCC.db rows are only the fallback.
        let screenGranted: Bool?
        if let p = v["screen_preflight"], p == "true" || p == "false" {
            screenGranted = p == "true"
        } else if tccReadable, let t = v["tcc_screen"], !t.isEmpty {
            screenGranted = t == "2"
        } else {
            screenGranted = nil
        }
        let osMajor = Int((v["os"] ?? "").split(separator: ".").first ?? "") ?? 0
        let alertNote = osMajor >= 15 ? " " + ReadinessReport.screenCaptureAlertNote : ""
        switch screenGranted {
        case true?: items[.screen] = ReadinessItem(.ok, "zezwolono",
            "Sesje SSH mają uprawnienie „Nagrywanie ekranu” – podgląd ekranu działa.\(alertNote)")
        case false?: items[.screen] = ReadinessItem(.manual, "ręcznie",
            "Sesje SSH nie mają uprawnienia „Nagrywanie ekranu” (/usr/libexec/sshd-keygen-wrapper, w nowszych macOS także /usr/libexec/sshd-session) – podgląd pokaże tylko tapetę. Trzeba je nadać przy komputerze (Otwórz instrukcję).\(alertNote)")
        case nil:
            let why: String
            if !sudoWorks && v["console"].map({ $0 != v["admin"] }) ?? true {
                why = "Do sprawdzenia potrzebne jest działające sudo (zapisane hasło administratora)."
            } else if (v["console"] ?? "").isEmpty {
                why = "Nikt nie jest zalogowany przy komputerze – sprawdzę, gdy ktoś się zaloguje."
            } else {
                why = "Nie udało się sprawdzić uprawnienia."
            }
            items[.screen] = ReadinessItem(.unknown, "?", why)
        }

        let fdaGranted = v["fda"] == "yes" || v["fda_root"] == "yes" || (tccReadable && v["tcc_fda"] == "2")
        items[.fda] = fdaGranted
            ? ReadinessItem(.ok, "włączony", "Sesje SSH mają pełny dostęp do dysku.")
            : ReadinessItem(.manual, "ręcznie",
                "„Daj użytkownikom zdalnym pełny dostęp do dysku” jest wyłączone – pobieranie prac z Biurka/Dokumentów ucznia i podmiana aplikacji mogą się nie udać. Włącza się to przy komputerze (Otwórz instrukcję).")

        switch v["filevault"] {
        case "off": items[.filevault] = ReadinessItem(.ok, "wyłączony", "Po restarcie iMac od razu jest dostępny przez SSH.")
        case "on": items[.filevault] = ReadinessItem(.warning, "włączony",
            "FileVault jest włączony: po restarcie iMac czeka na odblokowanie przy ekranie i do tego czasu jest niedostępny przez SSH.")
        default: items[.filevault] = ReadinessItem(.unknown, "?", "Nie udało się odczytać stanu FileVault.")
        }

        if let ver = v["setup"], !ver.isEmpty, ver != "none" {
            let when = v["setup_time"].flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            let order = SetupScript.compareVersions(ver, expectedVersion)
            if order == .orderedAscending {
                items[.setup] = ReadinessItem(.warning, "v\(ver)",
                    "Skonfigurowano starszą wersją skryptu (\(ver))\(when); aktualna to \(expectedVersion). Uruchom „Skonfiguruj zaznaczone” ponownie.")
            } else if v["setup_result"] == "fail" {
                items[.setup] = ReadinessItem(.warning, "błędy",
                    "Ostatnie uruchomienie skryptu \(ver)\(when) zgłosiło błędy – zobacz raport i uruchom ponownie.")
            } else if order == .orderedDescending {
                items[.setup] = ReadinessItem(.ok, "v\(ver)",
                    "Skonfigurowano nowszą wersją skryptu (\(ver))\(when) niż ta aplikacja (\(expectedVersion)) – zaktualizuj CMCR Manager, zanim uruchomisz konfigurację ponownie.")
            } else {
                items[.setup] = ReadinessItem(.ok, "v\(ver)", "Skonfigurowano skryptem CMCR \(ver)\(when).")
            }
        } else {
            items[.setup] = ReadinessItem(.problem, "nie",
                "Skrypt konfiguracyjny nie był uruchamiany na tym iMacu. Użyj „Skonfiguruj zaznaczone” albo zapisz skrypt i uruchom go przy komputerze.")
        }
        return ReadinessReport(items: items, values: v, checkedAt: date)
    }
}

public extension Scripts {
    /// Root quick fix for the student folder. Unlike a plain `mkdir -p` it never creates a missing home folder
    /// (it would belong to root and the student could not log in) and lets the student create missing folders
    /// inside their own home.
    static func createStudentFolder(_ path: String, owner: String) -> RemoteScript {
        RemoteScript(#"""
        R="${CMCR_SETUP_ROOT_PREFIX:-}"
        DIR="$R"\#(shQuote(path)); OWNER=\#(shQuote(owner))
        dscl . -read "/Users/$OWNER" UniqueID >/dev/null 2>&1 || { echo "Na tym iMacu nie ma konta ucznia „${OWNER}”." >&2; exit 1; }
        case "$DIR" in
          "$R"/Users/?*/*) TOP="${DIR#"$R"/Users/}"; TOP="$R/Users/${TOP%%/*}" ;;
          *) echo "Folder ucznia musi leżeć w /Users/<konto>/…" >&2; exit 2 ;;
        esac
        if [ ! -d "$TOP" ]; then
          echo "Folder ${TOP#"$R"} nie istnieje – zaloguj się raz na konto ucznia przy komputerze i spróbuj ponownie." >&2
          exit 1
        fi
        if [ ! -d "$DIR" ]; then
          A="$(dirname "$DIR")"
          while [ ! -d "$A" ] && [ "$A" != / ]; do A="$(dirname "$A")"; done
          # As the student when the folder above is theirs (their own permissions); otherwise as root below.
          if [ "$(stat -f %Su "$A" 2>/dev/null)" = "$OWNER" ] && [ "$(id -un)" != "$OWNER" ]; then
            sudo -u "$OWNER" /bin/mkdir -p "$DIR" || exit 1
          fi
        fi
        [ -L "$DIR" ] && { echo "${DIR#"$R"} jest dowiązaniem – przerwano." >&2; exit 1; }
        # chown/chmod from inside the folder, reached (and created) one folder at a time: never through a link the
        # student planted on the way (cmcr_pin_create).
        cmcr_pin_create "$DIR" || { [ $? = 2 ] || echo "Nie można utworzyć ani otworzyć ${DIR#"$R"}" >&2; exit 1; }
        chown "$OWNER" . && chmod 777 . && ls -ld "$DIR"
        """#, asRoot: true)
    }

    /// Cheap read-only readiness check (key=value lines for `ReadinessReport.parse`).
    ///
    /// Runs as the admin user; a single sudo call (only when a password or NOPASSWD rule exists) adds the
    /// checks that need root. Nothing here triggers a privacy prompt: Screen Recording is read with
    /// CGPreflightScreenCaptureAccess (or from TCC.db when Full Disk Access allows reading it).
    static func readiness(student: String, sharedFolder: String, publicKey: String?) -> RemoteScript {
        let keyBlob = publicKey.flatMap { key -> String? in
            let parts = key.split(separator: " ")
            return parts.count >= 2 ? String(parts[1]) : nil
        } ?? ""
        return RemoteScript(#"""
        R="${CMCR_SETUP_ROOT_PREFIX:-}"
        STUDENT=\#(shQuote(student)); SHARED=\#(shQuote(sharedFolder)); KEYBLOB=\#(shQuote(keyBlob))
        kv() { printf '%s=%s\n' "$1" "$2"; }
        # CGPreflightScreenCaptureAccess reports the Screen Recording grant without asking for it.
        JXA='ObjC.import("CoreGraphics"); ObjC.bindFunction("CGPreflightScreenCaptureAccess", ["bool", []]); $.CGPreflightScreenCaptureAccess()'
        preflight() {
          osascript -l JavaScript -e "$JXA" </dev/null 2>/dev/null & local p=$!
          ( sleep 10; kill "$p" 2>/dev/null ) </dev/null >/dev/null 2>&1 & local w=$!
          wait "$p"; kill "$w" 2>/dev/null
        }
        kv os "$(sw_vers -productVersion 2>/dev/null)"
        kv admin "$(id -un)"
        kv console "$CONSOLE_USER"
        kv lhn "$(scutil --get LocalHostName 2>/dev/null)"

        AK="$R$HOME/.ssh/authorized_keys"
        if [ -z "$KEYBLOB" ]; then kv key nolocal
        elif [ -f "$AK" ] && grep -qF -- "$KEYBLOB" "$AK" 2>/dev/null; then kv key ok
        else kv key missing; fi

        folder_state() { # folder_state STUDENT FOLDER
          if ! dscl . -read "/Users/$1" UniqueID >/dev/null 2>&1; then echo nostudent; return; fi
          if [ ! -d "$2" ]; then
            local h; h="$(dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -n 1)"
            case "$2" in "$R$h"/*) [ -n "$h" ] && [ ! -d "$R$h" ] && { echo nohome; return; } ;; esac
            echo missing; return
          fi
          local o m
          o="$(stat -f %Su "$2" 2>/dev/null)"; m="$(stat -f %Lp "$2" 2>/dev/null)"
          if [ "$o" = "$1" ] && { [ "$m" = 777 ] || ls -led "$2" 2>/dev/null | grep -q "user:$1 allow"; }; then
            echo ok
          else
            echo "perm $o $m"
          fi
        }
        SHOME="$(dscl . -read "/Users/$STUDENT" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -n 1)"
        # Repeated as root below: a student home closed to the admin (mode 700) hides the folder.
        kv folder "$(folder_state "$STUDENT" "$R$SHARED")"

        W="$(pmset -g 2>/dev/null | awk '$1=="womp"{print $2; exit}')"
        case "$W" in 1) kv wol on ;; 0) kv wol off ;; *) kv wol unsupported ;; esac
        if launchctl print system/com.apple.screensharing >/dev/null 2>&1; then kv vnc on; else kv vnc off; fi
        case "$(fdesetup status 2>/dev/null)" in
          *"FileVault is On"*) kv filevault on ;;
          *"FileVault is Off"*) kv filevault off ;;
          *) kv filevault unknown ;;
        esac
        # The system TCC folder can only be listed by a session with Full Disk Access.
        if ls "$R/Library/Application Support/com.apple.TCC/" >/dev/null 2>&1; then kv fda yes; else kv fda no; fi

        MK="$R/Library/Application Support/CMCR/setup.json"
        if [ -f "$MK" ]; then
          kv setup "$(plutil -extract version raw -o - "$MK" 2>/dev/null)"
          kv setup_result "$(plutil -extract result raw -o - "$MK" 2>/dev/null)"
          kv setup_time "$(plutil -extract timestamp raw -o - "$MK" 2>/dev/null)"
        else
          kv setup none
        fi

        if [ -n "$CONSOLE_UID" ] && [ "$(id -u)" = "$CONSOLE_UID" ]; then kv screen_preflight "$(preflight)"; fi

        if [ "$(id -u)" -eq 0 ]; then SUDO=root
        elif ! is_admin_user "$(id -un)"; then SUDO=notadmin
        elif sudo -n true 2>/dev/null; then SUDO=nopasswd
        elif [ -z "$CMCR_PW" ]; then SUDO=nopassword
        else SUDO=ok; fi
        if [ "$SUDO" = notadmin ] || [ "$SUDO" = nopassword ]; then
          kv sudo "$SUDO"
          exit 0
        fi
        { declare -f folder_state; cat <<'CMCR_READINESS_ROOT'
        R="$1"; SHOME="$2"; CUID="$3"
        echo "root=ok"
        echo "folder=$(folder_state "$5" "$6")"
        DB="$R/Library/Application Support/com.apple.TCC/TCC.db"
        # The SSH session's grant: sshd-keygen-wrapper, or sshd-session (path or bundle id) since OpenSSH 9.8.
        tcc() { sqlite3 -readonly "$DB" "SELECT IFNULL(MAX(auth_value),-1) FROM access WHERE service='$1' AND (client LIKE '%sshd-keygen-wrapper' OR client LIKE '%sshd-session');" 2>/dev/null; }
        F="$(tcc kTCCServiceSystemPolicyAllFiles)"
        if [ -n "$F" ]; then
          echo "tcc=readable"; echo "tcc_fda=$F"; echo "tcc_screen=$(tcc kTCCServiceScreenCapture)"
        fi
        if [ -n "$SHOME" ] && [ -d "$R$SHOME/Desktop" ]; then
          if ls "$R$SHOME/Desktop" >/dev/null 2>&1; then echo "fda_root=yes"; else echo "fda_root=no"; fi
        fi
        if [ -n "$CUID" ]; then
          # Same responsible process as the screen preview (launchctl asuser from the SSH session); never prompts.
          SP="$(launchctl asuser "$CUID" osascript -l JavaScript -e "$4" </dev/null 2>/dev/null & p=$!
                ( sleep 10; kill "$p" 2>/dev/null ) </dev/null >/dev/null 2>&1 & w=$!
                wait "$p"; kill "$w" 2>/dev/null)"
          echo "screen_preflight=$SP"
        fi
        CMCR_READINESS_ROOT
        } > "$CMCR_TMP/readiness-root.sh"
        ROOTOUT="$(asroot /bin/bash --noprofile --norc "$CMCR_TMP/readiness-root.sh" "$R" "$SHOME" "$CONSOLE_UID" "$JXA" \
          "$STUDENT" "$R$SHARED" 2>"$CMCR_TMP/readiness.err")"
        if printf '%s\n' "$ROOTOUT" | grep -qx 'root=ok'; then
          kv sudo "$SUDO"
          printf '%s\n' "$ROOTOUT" | grep -v '^root='
        else
          ERR="$(grep -v '^ *$' "$CMCR_TMP/readiness.err" 2>/dev/null | head -n 1)"
          case "$ERR" in
            *"incorrect password"*|*"Sorry, try again"*|*"no password was provided"*) kv sudo badpassword ;;
            *) kv sudo error; kv sudo_error "$ERR" ;;
          esac
        fi
        """#)
    }
}
