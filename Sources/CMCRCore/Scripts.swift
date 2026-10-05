import Foundation

/// Exit codes used by scripts to report well-known conditions back to the app.
public enum ScriptCode {
    public static let noConsoleUser: Int32 = 3
    public static let observeDenied: Int32 = 4
    public static let captureFailed: Int32 = 5
}

/// Builders for every remote operation. All user-provided values are embedded with `shQuote`.
public enum Scripts {

    // MARK: - Status / inventory

    /// Status and inventory as `key=value` lines (see `HostStatus` for the accessors). Every probe is
    /// read-only, needs no sudo and triggers no privacy (TCC) prompt.
    /// `checkSudo` adds `sudo_nopass=` – off by default, because `sudo -n` writes a sudo log entry on every
    /// periodic refresh.
    public static func status(checkSudo: Bool = false) -> RemoteScript {
        RemoteScript(#"""
        IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
        echo "name=$(scutil --get ComputerName 2>/dev/null)"
        echo "lhn=$(scutil --get LocalHostName 2>/dev/null)"
        sw_vers 2>/dev/null | awk -F':[ \t]*' '$1=="ProductVersion"{print "os="$2} $1=="BuildVersion"{print "build="$2}'
        sysctl hw.model machdep.cpu.brand_string hw.memsize kern.boottime vm.loadavg 2>/dev/null | awk '
          /^hw\.model:/ {sub(/^[^:]*: /, ""); print "model=" $0}
          /^machdep\.cpu\.brand_string:/ {sub(/^[^:]*: /, ""); print "chip=" $0}
          /^hw\.memsize:/ {printf "mem=%d\n", $2 / 1073741824}
          /^kern\.boottime:/ {if (match($0, /sec = [0-9]+/)) print "boot=" substr($0, RSTART + 6, RLENGTH - 6)}
          /^vm\.loadavg:/ {print "load=" $3 " " $4 " " $5}'
        echo "arch=$(uname -m)"
        echo "serial=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/{print $4; exit}')"
        echo "console=$CONSOLE_USER"
        echo "disk=$(df -k / 2>/dev/null | awk 'NR==2{print $2" "$4}')"
        echo "ip=$(ipconfig getifaddr "${IF:-en0}" 2>/dev/null)"
        echo "mac=$(ifconfig "${IF:-en0}" 2>/dev/null | awk '/ether/{print $2; exit}')"
        # All hardware ports (device:MAC) and the MAC of the wired port, which Wake-on-LAN needs.
        networksetup -listallhardwareports 2>/dev/null | awk '
          /^Hardware Port:/ {p = substr($0, 16)}
          /^Device:/ {d = $2}
          /^Ethernet Address:/ {
            m = $3
            if (m == "" || m == "N/A" || d ~ /^bridge/) next
            all = all (all == "" ? "" : ",") d ":" m
            if (p == "Ethernet") { if (e1 == "") e1 = m }
            else if (p ~ /Ethernet|LAN/ && p !~ /Bridge|^Ethernet Adapter \(/ && e2 == "") e2 = m
          }
          END {print "macs=" all; print "mac_ethernet=" (e1 != "" ? e1 : e2)}'
        case "$(fdesetup isactive 2>/dev/null)" in true) echo "filevault=on" ;; false) echo "filevault=off" ;; esac
        case "$(csrutil status 2>/dev/null)" in *enabled*) echo "sip=on" ;; *disabled*) echo "sip=off" ;; esac
        case "$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)" in
          *"State = 0"*) echo "firewall=off" ;; *"State = 1"*) echo "firewall=on" ;; *"State = 2"*) echo "firewall=blockall" ;;
        esac
        pmset -g 2>/dev/null | awk '$1=="womp"||$1=="autorestart"||$1=="sleep"||$1=="displaysleep"{print $1 "=" $2}'
        echo "power_schedule=$(pmset -g sched 2>/dev/null | awk '/^Repeating power events/{r=1; next} /^[^ \t]/{r=0} r{sub(/^[ \t]+/, ""); printf "%s%s", (n++ ? "; " : ""), $0}')"
        last -1 -y -t console 2>/dev/null | awk '$2 == "console" && NF >= 7 {
          split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mo, " ")
          for (i = 1; i <= 12; i++) if (mo[i] == $4) m = i
          print "last_user=" $1; printf "last_login=%s-%02d-%02d %s\n", $6, m, $5, $7; exit}'
        UE=""; for d in /Applications/Unity/Hub/Editor/*/; do [ -d "$d" ] && UE="$UE${UE:+,}$(basename "$d")"; done
        echo "unity=$UE"
        if command -v brew >/dev/null 2>&1; then echo "brew=yes"; else echo "brew=no"; fi
        SJ="/Library/Application Support/CMCR/setup.json"
        if [ -r "$SJ" ]; then
          echo "setup_version=$(plutil -extract version raw -o - "$SJ" 2>/dev/null)"
          echo "setup_result=$(plutil -extract result raw -o - "$SJ" 2>/dev/null)"
          echo "setup_time=$(plutil -extract timestamp raw -o - "$SJ" 2>/dev/null)"
          echo "setup_todo=$(plutil -extract todo_count raw -o - "$SJ" 2>/dev/null)"
        fi
        # Listing this folder needs Full Disk Access ("Pełny dostęp do dysku dla zdalnych użytkowników");
        # a denial is silent, macOS never asks.
        if ls "/Library/Application Support/com.apple.TCC/" >/dev/null 2>&1; then echo "fda=yes"; else echo "fda=no"; fi
        echo "sshuser=$(id -un)"
        if is_admin_user "$(id -un)"; then echo "admin=yes"; else echo "admin=no"; fi
        if [ \#(checkSudo ? 1 : 0) = 1 ]; then
          if sudo -n true 2>/dev/null; then echo "sudo_nopass=yes"; else echo "sudo_nopass=no"; fi
        fi
        exit 0
        """#)
    }

    /// Verifies that sudo works with the stored password.
    public static func sudoTest() -> RemoteScript {
        RemoteScript(#"echo "sudo OK – działam jako: $(id -un) (uid $(id -u)), administrator: $CMCR_ADMIN_USER""#, asRoot: true)
    }

    // MARK: - SSH keys (README: "Distribute your SSH key")

    /// Appends the public key to the admin's `authorized_keys` (`authorizedKeys` is for tests).
    public static func distributeKey(_ publicKey: String,
                                     authorizedKeys: String = "~/.ssh/authorized_keys") -> RemoteScript {
        let key = publicKey.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return RemoteScript(#"""
        KEY=\#(shQuote(key)); AK=\#(shQuote(authorizedKeys))
        AK="${AK/#\~/$HOME}"; DIR="$(dirname "$AK")"
        case "$KEY" in ssh-*|ecdsa-*|sk-*) ;; *) echo "✘ To nie wygląda na klucz publiczny SSH." >&2; exit 2 ;; esac
        [ -d "$DIR" ] || mkdir -p "$DIR" || exit 2
        chmod 700 "$DIR"
        touch "$AK" || exit 2
        # A last line without a newline would glue the new key onto it and break both keys.
        if [ -s "$AK" ] && [ -n "$(tail -c 1 "$AK")" ]; then echo >> "$AK"; fi
        BLOB="$(printf '%s\n' "$KEY" | awk '{print $2}')"
        if awk -v b="$BLOB" '$2 == b || $3 == b {f = 1} END {exit !f}' "$AK"; then
          echo "Klucz był już zainstalowany."
        else
          printf '%s\n' "$KEY" >> "$AK" || exit 2
          echo "Klucz dodany do $AK."
        fi
        chmod 600 "$AK"
        """#)
    }

    // MARK: - Screen preview (view only)

    public static func screenshot(maxSize: Int, quality: Int, notify: Bool,
                                  onlyStandard: Bool, allowedUsers: [String]) -> RemoteScript {
        RemoteScript(#"""
        MAXSIZE=\#(max(320, maxSize))
        QUALITY=\#(min(100, max(10, quality)))
        ALLOWED=\#(shQuote(allowedUsers.joined(separator: ",")))
        if [ -z "$CONSOLE_USER" ]; then echo "CMCR:NO_USER" >&2; exit \#(ScriptCode.noConsoleUser); fi
        if [ -n "$ALLOWED" ]; then
          case ",$ALLOWED," in *",$CONSOLE_USER,"*) ;; *) echo "CMCR:DENIED:$CONSOLE_USER" >&2; exit \#(ScriptCode.observeDenied) ;; esac
        fi
        if [ \#(onlyStandard ? 1 : 0) = 1 ] && is_admin_user "$CONSOLE_USER"; then
          echo "CMCR:ADMIN:$CONSOLE_USER" >&2; exit \#(ScriptCode.observeDenied)
        fi
        if [ \#(notify ? 1 : 0) = 1 ]; then
          as_console_user /usr/bin/osascript -e 'display notification "Administrator rozpoczął podgląd Twojego ekranu." with title "Podgląd ekranu"' </dev/null >/dev/null 2>&1 || true
        fi
        RAW="$CMCR_TMP/screen.png"; OUT="$CMCR_TMP/screen.jpg"
        if [ "$(id -u)" = "$CONSOLE_UID" ]; then
          /usr/sbin/screencapture -x -m -C -t png "$RAW" </dev/null >/dev/null 2>&1
        fi
        if [ ! -s "$RAW" ]; then
          asroot launchctl asuser "$CONSOLE_UID" /usr/sbin/screencapture -x -m -C -t png "$RAW" </dev/null >/dev/null 2>"$CMCR_TMP/err"
        fi
        if [ ! -s "$RAW" ]; then echo "CMCR:CAPTURE_FAILED $(cat "$CMCR_TMP/err" 2>/dev/null)" >&2; exit \#(ScriptCode.captureFailed); fi
        echo "CMCR:USER:$CONSOLE_USER" >&2
        if ! sips -s format jpeg -s formatOptions "$QUALITY" -Z "$MAXSIZE" "$RAW" --out "$OUT" >/dev/null 2>&1; then OUT="$RAW"; fi
        cat "$OUT"
        """#)
    }

    // MARK: - Applications

    public static func runningApps() -> RemoteScript {
        RemoteScript(#"""
        echo "USER:$CONSOLE_USER"
        [ -z "$CONSOLE_USER" ] && exit 0
        ps -axww -o pid=,user=,comm= | awk -v u="$CONSOLE_USER" '$2 == u'
        """#)
    }

    public static func installedApps() -> RemoteScript {
        RemoteScript(#"""
        for d in /Applications /Applications/Utilities /System/Applications /System/Applications/Utilities ${CONSOLE_USER:+"/Users/$CONSOLE_USER/Applications"}; do
          for a in "$d"/*.app; do [ -e "$a" ] && echo "$a"; done
        done
        exit 0
        """#)
    }

    /// Starts an application (name like `Safari`, or a full `/Applications/X.app` path) in the user's session.
    /// `arguments` is split like a shell command line (quotes and backslashes group words) and every word is
    /// passed literally. `open --args` is ignored by an app that is already running, so with arguments a new
    /// instance is started (`open -n`) unless `newInstance` says otherwise.
    public static func launchApp(_ app: String, arguments: String = "", newInstance: Bool? = nil) -> RemoteScript {
        launchApp(app, argumentList: splitArguments(arguments), newInstance: newInstance)
    }

    public static func launchApp(_ app: String, argumentList: [String], newInstance: Bool? = nil) -> RemoteScript {
        var openArgs = (newInstance ?? !argumentList.isEmpty) ? "-n -a \"$APP\"" : "-a \"$APP\""
        if !argumentList.isEmpty {
            openArgs += " --args " + argumentList.map(shQuote).joined(separator: " ")
        }
        return RemoteScript(#"""
        APP=\#(shQuote(app))
        if [ -z "$CONSOLE_USER" ]; then echo "Brak zalogowanego użytkownika – nie ma gdzie uruchomić aplikacji." >&2; exit \#(ScriptCode.noConsoleUser); fi
        if as_console_user /usr/bin/open \#(openArgs); then
          echo "Uruchomiono „$APP” dla użytkownika $CONSOLE_USER."
        else
          echo "Nie udało się uruchomić „$APP”." >&2; exit 1
        fi
        """#)
    }

    /// Splits a command line into words like a POSIX shell, without any expansion: whitespace separates,
    /// '…' is literal, "…" and \ escape. `a "b c" 'd e'\ f` → ["a", "b c", "d e f"].
    public static func splitArguments(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped {
                // Inside "…" a backslash only escapes " \ $ and `, as in the shell.
                if quote == "\"" && !"\"\\$`".contains(ch) { current.append("\\") }
                current.append(ch); escaped = false; inWord = true
                continue
            }
            switch (quote, ch) {
            case (nil, "\\"), ("\"", "\\"):
                escaped = true; inWord = true
            case (nil, "'"), (nil, "\""):
                quote = ch; inWord = true
            case ("'", "'"), ("\"", "\""):
                quote = nil
            case (nil, _) where ch.isWhitespace:
                if inWord { words.append(current); current = ""; inWord = false }
            default:
                current.append(ch); inWord = true
            }
        }
        if escaped { current.append("\\") }
        if inWord { words.append(current) }
        return words
    }

    /// Opens a URL or a file in the user's session (default application).
    public static func openURL(_ url: String) -> RemoteScript {
        RemoteScript(#"""
        TARGET=\#(shQuote(url))
        as_console_user /usr/bin/open "$TARGET" && echo "Otwarto: $TARGET"
        """#)
    }

    /// Quits an application by name (`Safari`) or bundle path in the console user's session.
    ///
    /// Without `force` the app gets the standard `quit` Apple Event, exactly like ⌘Q: it may ask the student
    /// to save documents. `quit` (like `activate`/`open`) is exempt from the Automation (TCC) consent, so no
    /// privacy prompt appears; the event is sent from the user's own session with `as_console_user` and
    /// without waiting for a reply. If the app is still running after `wait` seconds it is left alone, or
    /// gets SIGTERM when `terminateIfRunning` is set. Processes without a bundle identifier (no Info.plist)
    /// cannot receive Apple Events and get SIGTERM. `force` sends SIGKILL immediately.
    public static func quitApp(_ app: String, force: Bool, terminateIfRunning: Bool = false,
                               wait: Int = 10) -> RemoteScript {
        let needle = app.hasSuffix(".app") && app.hasPrefix("/")
            ? app + "/Contents/MacOS/"
            : "/" + (app.hasSuffix(".app") ? String(app.dropLast(4)) : app) + ".app/Contents/MacOS/"
        let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        return RemoteScript(#"""
        NEEDLE=\#(shQuote(needle)); NAME=\#(shQuote(name))
        FORCE=\#(force ? 1 : 0); FALLBACK=\#(terminateIfRunning ? 1 : 0); WAIT=\#(max(1, wait))
        if [ -z "$CONSOLE_USER" ]; then echo "Brak zalogowanego użytkownika."; exit 0; fi
        app_pids() { ps -axww -o pid=,user=,comm= | awk -v u="$CONSOLE_USER" -v n="$NEEDLE" '$2 == u && index($0, n) > 0 {print $1}'; }
        PIDS="$(app_pids)"
        if [ -z "$PIDS" ]; then echo "Aplikacja nie jest uruchomiona."; exit 0; fi
        if [ $FORCE = 1 ]; then
          asroot kill -KILL $PIDS && echo "Wymuszono zamknięcie $NAME (SIGKILL, procesy: $(echo $PIDS))."
          exit
        fi
        EXE="$(ps -o comm= -p "$(echo "$PIDS" | head -1)" 2>/dev/null)"
        BID=""
        case "$EXE" in
          *.app/Contents/MacOS/*) BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${EXE%%.app/Contents/MacOS/*}.app/Contents/Info.plist" 2>/dev/null)" ;;
        esac
        if [ -n "$BID" ]; then
          as_console_user /usr/bin/osascript -e 'on run argv' -e 'set b to item 1 of argv' -e 'try' \
            -e 'if application id b is running then' -e 'ignoring application responses' \
            -e 'tell application id b to quit' -e 'end ignoring' -e 'end if' -e 'end try' -e 'end run' \
            "$BID" </dev/null >/dev/null 2>"$CMCR_TMP/quit.err"
          RC=$?
          if [ $RC = 91 ] || [ $RC = 3 ] || grep -qiE 'password|Sorry, try again' "$CMCR_TMP/quit.err"; then
            cat "$CMCR_TMP/quit.err" >&2; exit $RC
          fi
          echo "→ Wysłano polecenie „Zakończ” do $NAME ($BID)."
          i=0
          while [ $i -lt $((WAIT * 2)) ]; do
            sleep 0.5; i=$((i + 1))
            PIDS="$(app_pids)"; [ -z "$PIDS" ] && break
          done
          if [ -z "$PIDS" ]; then echo "✔ Zamknięto $NAME."; exit 0; fi
        elif [ $FALLBACK = 0 ]; then
          echo "→ $NAME nie przyjmuje polecenia „Zakończ” (brak identyfikatora aplikacji) – wysyłam SIGTERM."
          FALLBACK=1
        fi
        if [ $FALLBACK = 1 ]; then
          asroot kill -TERM $PIDS && echo "Wysłano SIGTERM do procesów: $(echo $PIDS)"
          sleep 1
          if [ -z "$(app_pids)" ]; then echo "✔ Zamknięto $NAME."; exit 0; fi
          echo "⚠︎ $NAME nadal działa – użyj „Wymuś zamknięcie”." >&2; exit 1
        fi
        echo "⚠︎ $NAME nadal działa (np. pyta ucznia o zapisanie dokumentu) – poczekaj albo użyj „Wymuś zamknięcie”." >&2
        exit 1
        """#)
    }

    public static func killProcess(_ pid: Int, force: Bool) -> RemoteScript {
        RemoteScript(#"""
        asroot kill -\#(force ? "KILL" : "TERM") \#(pid) && echo "Wysłano SIG\#(force ? "KILL" : "TERM") do PID \#(pid)."
        """#)
    }

    /// Removes an application bundle from /Applications (or `$CMCR_APPS_DIR`, used by the tests).
    public static func uninstallApp(_ path: String) -> RemoteScript {
        RemoteScript(#"""
        APP=\#(shQuote(path)); APPS="${CMCR_APPS_DIR:-/Applications}"
        while [ "${APP%/}" != "$APP" ]; do APP="${APP%/}"; done
        case "$APP/" in */../*|*/./*|*//*) echo "Odmowa: niepoprawna ścieżka $APP" >&2; exit 2 ;; esac
        case "$APP" in
          "$APPS"/*.app/*) echo "Odmowa: $APP leży wewnątrz innej aplikacji." >&2; exit 2 ;;
          "$APPS"/*.app) ;;
          *) echo "Odinstalowywać można tylko aplikacje z $APPS." >&2; exit 2 ;;
        esac
        [ -e "$APP" ] || [ -L "$APP" ] || { echo "Nie znaleziono: $APP"; exit 0; }
        PARENT="$(cmcr_realdir "$(dirname "$APP")")"; RAPPS="$(cmcr_realdir "$APPS")"
        case "$PARENT/" in "$RAPPS"/*) ;; *) echo "Odmowa: $APP wskazuje poza $APPS ($PARENT)." >&2; exit 2 ;; esac
        NAME="$(basename "$APP" .app)"
        PIDS="$(ps -axww -o pid=,comm= | awk -v n="/$NAME.app/Contents/MacOS/" 'index($0, n) > 0 {print $1}')"
        [ -n "$PIDS" ] && kill -KILL $PIDS 2>/dev/null
        if rm -rf "$APP" 2>"$CMCR_TMP/rm.err" && [ ! -e "$APP" ]; then
          echo "Usunięto $APP"
        else
          echo "✘ Nie udało się usunąć $APP: $(head -1 "$CMCR_TMP/rm.err")" >&2
          echo "  macOS chroni aplikacje: włącz „Pełny dostęp do dysku dla zdalnych użytkowników” (Ustawienia systemowe › Ogólne › Udostępnianie › Zdalne logowanie)." >&2
          exit 1
        fi
        """#, asRoot: true)
    }

    // MARK: - Installing software

    /// Shell functions that install .pkg/.mpkg/.dmg/.zip/.app items (run as root). Applications go to
    /// `$CMCR_APPS_DIR` (default /Applications; real sudo resets the environment, so only the tests use it).
    static let installLibrary = #"""
    CMCR_APPS="${CMCR_APPS_DIR:-/Applications}"
    cmcr_fda_hint() {
      echo "  Wskazówka: jeśli aplikacja nie jest uruchomiona, włącz „Pełny dostęp do dysku dla zdalnych użytkowników” (Ustawienia systemowe › Ogólne › Udostępnianie › Zdalne logowanie) – bez tego macOS nie pozwala podmieniać aplikacji." >&2
    }
    cmcr_skip_uninstaller() {
      case "$(basename "$1")" in *[Uu]ninstall*) echo "↷ Pomijam $(basename "$1")"; return 0 ;; esac
      return 1
    }
    # Copies the new bundle next to the old one and swaps them, so no stale files of the old version survive
    # (a merged bundle has a broken code signature) and the app is never half-copied.
    cmcr_install_app_bundle() {
      local src="$1" name; name="$(basename "$src")"
      local dst="$CMCR_APPS/$name" new="$CMCR_APPS/.$name.cmcr-new" old="$CMCR_APPS/.$name.cmcr-old"
      echo "→ Kopiowanie $name do $CMCR_APPS"
      rm -rf "$new" "$old" 2>/dev/null
      if ! ditto "$src" "$new"; then rm -rf "$new"; echo "✘ Nie udało się skopiować $name" >&2; return 1; fi
      xattr -dr com.apple.quarantine "$new" 2>/dev/null
      chown -R root:admin "$new" 2>/dev/null
      if [ -e "$dst" ] || [ -L "$dst" ]; then
        if ! mv "$dst" "$old" 2>/dev/null; then
          rm -rf "$new"; echo "✘ Nie można zastąpić $dst" >&2; cmcr_fda_hint; return 1
        fi
      fi
      if ! mv "$new" "$dst"; then
        [ -e "$old" ] && mv "$old" "$dst"
        rm -rf "$new"; echo "✘ Nie udało się zainstalować $name" >&2; return 1
      fi
      if [ -e "$old" ] && ! rm -rf "$old" 2>/dev/null; then
        echo "⚠︎ Nie usunięto poprzedniej wersji ($old)" >&2; cmcr_fda_hint
      fi
      echo "✔ Zainstalowano $name"
    }
    cmcr_install_pkg() {
      echo "→ installer -pkg $(basename "$1")"
      installer -pkg "$1" -target / && echo "✔ Zainstalowano pakiet $(basename "$1")"
    }
    cmcr_install_dmg() {
      local base mnt rc=0 found=0 p
      base="$(mktemp -d /tmp/cmcr-mnt.XXXXXX)" || return 1
      echo "→ Montowanie $(basename "$1")"
      # PAGER=cat + yes: images with a licence agreement would otherwise wait for "Agree Y/N?".
      # -mountrandom also copes with images that contain several volumes.
      if ! yes | PAGER=cat hdiutil attach "$1" -readonly -nobrowse -noverify -noautoopen -mountrandom "$base" >/dev/null; then
        echo "✘ Nie można zamontować obrazu dysku" >&2; rmdir "$base" 2>/dev/null; return 1
      fi
      for mnt in "$base"/*; do
        for p in "$mnt"/*.pkg "$mnt"/*.mpkg; do
          [ -e "$p" ] || continue
          cmcr_skip_uninstaller "$p" && continue
          found=1; cmcr_install_pkg "$p" || rc=1
        done
      done
      if [ $found = 0 ]; then
        for mnt in "$base"/*; do
          for p in "$mnt"/*.app; do
            [ -e "$p" ] || continue
            cmcr_skip_uninstaller "$p" && continue
            found=1; cmcr_install_app_bundle "$p" || rc=1
          done
        done
      fi
      for mnt in "$base"/*; do
        [ -d "$mnt" ] || continue
        hdiutil detach "$mnt" -quiet 2>/dev/null || hdiutil detach "$mnt" -force -quiet 2>/dev/null
        rmdir "$mnt" 2>/dev/null
      done
      rmdir "$base" 2>/dev/null
      if [ $found = 0 ]; then echo "✘ W obrazie nie ma pliku .pkg ani .app" >&2; return 1; fi
      return $rc
    }
    cmcr_install_dir() {
      local found=0 rc=0 item
      while IFS= read -r -d '' item; do
        cmcr_skip_uninstaller "$item" && continue
        found=1; cmcr_install_item "$item" || rc=1
      done < <(find "$1" -mindepth 1 -maxdepth 2 -name '__MACOSX' -prune -o \( -name '*.app' -o -name '*.pkg' -o -name '*.mpkg' -o -name '*.dmg' \) -prune -print0)
      if [ $found = 0 ]; then echo "✘ Nie znaleziono instalatora (.pkg/.dmg/.app) w $(basename "$1")" >&2; return 1; fi
      return $rc
    }
    cmcr_install_item() {
      local f="$1"
      case "$f" in
        *.pkg|*.mpkg) cmcr_install_pkg "$f" ;;
        *.dmg) cmcr_install_dmg "$f" ;;
        *.app) cmcr_install_app_bundle "$f" ;;
        *.zip)
          local d; d="$(mktemp -d "$CMCR_TMP/zip.XXXXXX")"
          echo "→ Rozpakowywanie $(basename "$f")"
          ditto -x -k "$f" "$d" && cmcr_install_dir "$d" ;;
        *)
          if [ -d "$f" ]; then cmcr_install_dir "$f"
          elif xar -tf "$f" >/dev/null 2>&1; then mv "$f" "$f.pkg"; cmcr_install_pkg "$f.pkg"
          elif hdiutil imageinfo "$f" >/dev/null 2>&1; then mv "$f" "$f.dmg"; cmcr_install_dmg "$f.dmg"
          elif unzip -tq "$f" >/dev/null 2>&1; then mv "$f" "$f.zip"; cmcr_install_item "$f.zip"
          else echo "✘ Nieobsługiwany typ pliku: $(basename "$f")" >&2; return 1
          fi ;;
      esac
    }
    """#

    /// Installs everything contained in an uploaded payload archive.
    public static func installPayload(remoteTar: String) -> RemoteScript {
        RemoteScript(installLibrary + "\n" + #"""
        TAR=\#(shQuote(remoteTar))
        STAGE="$CMCR_TMP/payload"; mkdir -p "$STAGE"
        tar -xf "$TAR" --no-same-owner -C "$STAGE"; X=$?
        rm -f "$TAR"
        [ $X = 0 ] || { echo "✘ Nie udało się rozpakować przesłanych plików" >&2; exit 2; }
        RC=0
        for item in "$STAGE"/*; do
          [ -e "$item" ] || continue
          cmcr_install_item "$item" || RC=1
        done
        exit $RC
        """#, asRoot: true)
    }

    /// Downloads an installer on the target Mac and installs it.
    public static func installFromURL(_ url: String) -> RemoteScript {
        RemoteScript(installLibrary + "\n" + #"""
        URL=\#(shQuote(url))
        NAME="$(basename "${URL%%[?#]*}")"
        case "$NAME" in ""|/|.|..|*:*) NAME="download" ;; esac
        mkdir -p "$CMCR_TMP/dl"; F="$CMCR_TMP/dl/$NAME"
        echo "→ Pobieranie $URL"
        curl -fL --retry 2 --connect-timeout 20 -o "$F" "$URL" || { echo "✘ Pobieranie nie powiodło się" >&2; exit 2; }
        cmcr_install_item "$F"
        """#, asRoot: true)
    }

    /// Runs Homebrew as the admin. `arguments` is shell text (e.g. `install oracle-jdk`).
    public static func brew(_ arguments: String) -> RemoteScript {
        RemoteScript(#"""
        if ! command -v brew >/dev/null 2>&1; then
          echo "Homebrew nie jest zainstalowany (użyj „Zainstaluj Homebrew”)." >&2; exit 2
        fi
        export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1
        with_askpass brew \#(arguments)
        """#)
    }

    public static func installHomebrew() -> RemoteScript {
        RemoteScript(#"""
        if command -v brew >/dev/null 2>&1; then echo "Homebrew już jest: $(brew --version | head -1)"; exit 0; fi
        with_askpass env NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        """#)
    }

    // MARK: - Unity Hub / Android SDK (notes.md)

    static let unityHubPath = "/Applications/Unity Hub.app/Contents/MacOS/Unity Hub"

    public static func unityHub(_ arguments: [String]) -> RemoteScript {
        RemoteScript(#"""
        HUB=\#(shQuote(unityHubPath))
        if [ ! -x "$HUB" ]; then echo "Brak Unity Hub w /Applications (zainstaluj np. brew install --cask unity-hub)." >&2; exit 2; fi
        "$HUB" -- --headless \#(arguments.map(shQuote).joined(separator: " "))
        """#)
    }

    /// Installs an editor for the Mac's own architecture (Unity Hub defaults to Intel, which runs under
    /// Rosetta on Apple Silicon) together with the child modules of the selected modules – for `android`
    /// that is the Android SDK & NDK Tools and OpenJDK, without which `sdkmanager` does not exist.
    public static func unityInstallEditor(version: String, modules: [String], changeset: String = "") -> RemoteScript {
        var args = ["install", "--version", version]
        if !changeset.isEmpty { args += ["--changeset", changeset] }
        let mods = modules.flatMap { ["-m", $0] } + (modules.isEmpty ? [] : ["--childModules"])
        return RemoteScript(#"""
        HUB=\#(shQuote(unityHubPath))
        if [ ! -x "$HUB" ]; then echo "Brak Unity Hub w /Applications (zainstaluj np. brew install --cask unity-hub)." >&2; exit 2; fi
        ARCH=x86_64; [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && ARCH=arm64
        echo "→ Unity Hub: \#(args.joined(separator: " ")) (architektura $ARCH)"
        "$HUB" -- --headless \#(args.map(shQuote).joined(separator: " ")) --architecture "$ARCH" \#(mods.map(shQuote).joined(separator: " "))
        """#)
    }

    public static func unityInstallModules(version: String, modules: [String]) -> RemoteScript {
        unityHub(["install-modules", "--version", version] + modules.flatMap { ["-m", $0] } + ["--childModules"])
    }

    public static func androidSDK(unityVersion: String, apiLevels: [String]) -> RemoteScript {
        let packages = ["platform-tools"] + apiLevels.map { "platforms;android-\($0)" }
        return RemoteScript(#"""
        BASE="/Applications/Unity/Hub/Editor/"\#(shQuote(unityVersion))"/PlaybackEngines/AndroidPlayer"
        SDKM="$BASE/SDK/cmdline-tools/latest/bin/sdkmanager"
        if [ ! -x "$SDKM" ]; then
          L="$(ls -d "$BASE"/SDK/cmdline-tools/*/bin/sdkmanager 2>/dev/null)"
          SDKM="$(printf '%s\n' "$L" | sort -V 2>/dev/null | tail -1)"
          [ -n "$SDKM" ] || SDKM="$(printf '%s\n' "$L" | tail -1)"
        fi
        if [ ! -x "$SDKM" ]; then
          echo "Nie znaleziono sdkmanager w $BASE/SDK/cmdline-tools – zainstaluj moduł Android razem z modułami podrzędnymi (przyciski „Zainstaluj edytor” / „Dodaj moduły” robią to automatycznie)." >&2; exit 2
        fi
        for J in "$BASE/OpenJDK" "$BASE/OpenJDK/Contents/Home"; do
          if [ -x "$J/bin/java" ]; then export JAVA_HOME="$J"; break; fi
        done
        echo "→ $SDKM ${JAVA_HOME:+(JAVA_HOME=$JAVA_HOME)}"
        yes | "$SDKM" --sdk_root="$BASE/SDK" \#(packages.map(shQuote).joined(separator: " "))
        """#)
    }

    // MARK: - Software updates

    public static func listUpdates() -> RemoteScript {
        RemoteScript("softwareupdate --list 2>&1")
    }

    /// Installs (or downloads) the updates offered by `softwareupdate --list`, label by label. Upgrades to a
    /// new major macOS version are skipped unless `allowMajorUpgrade` is set – `--all` would install them too.
    public static func installUpdates(restart: Bool, recommendedOnly: Bool, downloadOnly: Bool,
                                      allowMajorUpgrade: Bool = false) -> RemoteScript {
        RemoteScript(#"""
        RESTART=\#(restart ? 1 : 0); REC=\#(recommendedOnly ? 1 : 0); DL=\#(downloadOnly ? 1 : 0); MAJOR=\#(allowMajorUpgrade ? 1 : 0)
        CUR="$(sw_vers -productVersion 2>/dev/null)"; CUR="${CUR%%.*}"
        echo "→ softwareupdate --list"
        softwareupdate --list > "$CMCR_TMP/updates" 2>&1
        LABELS=(); SKIPPED=""; LABEL=""
        while IFS= read -r line; do
          case "$line" in
            "* Label: "*) LABEL="${line#\* Label: }" ;;
            *"Title: "*)
              [ -n "$LABEL" ] || continue
              TITLE="${line#*Title: }"; TITLE="${TITLE%%,*}"
              VER="$(printf '%s\n' "$line" | sed -n 's/.*Version: \([^,]*\),.*/\1/p')"
              OK=1
              if [ $REC = 1 ]; then case "$line" in *"Recommended: YES"*) ;; *) OK=0 ;; esac; fi
              case "$TITLE" in
                macOS*) if [ $MAJOR = 0 ] && [ -n "$CUR" ] && [ -n "$VER" ] && [ "${VER%%.*}" != "$CUR" ]; then
                          OK=0; SKIPPED="$SKIPPED${SKIPPED:+, }$TITLE"
                        fi ;;
              esac
              [ $OK = 1 ] && LABELS+=("$LABEL")
              LABEL="" ;;
          esac
        done < "$CMCR_TMP/updates"
        if [ -n "$SKIPPED" ]; then
          echo "↷ Pominięto przejście na nową wersję systemu: $SKIPPED (wymaga zaznaczenia „Pozwól na nową wersję macOS”)."
        fi
        if [ ${#LABELS[@]} -eq 0 ]; then echo "✔ Brak aktualizacji do zainstalowania."; exit 0; fi
        if [ $DL = 1 ]; then ARGS=(--download); else ARGS=(--install); fi
        ARGS+=("${LABELS[@]}")
        if [ $DL = 0 ]; then ARGS+=(--agree-to-license); [ $RESTART = 1 ] && ARGS+=(--restart); fi
        printf '→ %s\n' "${LABELS[@]}"
        if [ "$(uname -m)" = "arm64" ] && [ -n "$CMCR_PW" ]; then
          # Apple Silicon requires the credentials of a volume owner (Secure Token) for OS updates.
          GUID="$(dscl . -read "/Users/$CMCR_ADMIN_USER" GeneratedUID 2>/dev/null | awk '{print $2}')"
          if [ -n "$GUID" ]; then
            VO="$(diskutil apfs listUsers / 2>/dev/null | awk -v g="$GUID" 'index($0, g) {f = 1; next} /^[|]? *\+--/ {f = 0} f && /Volume Owner:/ {print $3; exit}')"
            if [ "$VO" = "No" ]; then
              echo "⚠︎ Konto $CMCR_ADMIN_USER nie jest właścicielem woluminu (brak Secure Token) – aktualizacja macOS może się nie udać. Użyj konta administratora z Secure Token." >&2
            fi
          fi
          printf '%s\n' "$CMCR_PW" | softwareupdate "${ARGS[@]}" --user "$CMCR_ADMIN_USER" --stdinpass 2>&1
        else
          softwareupdate "${ARGS[@]}" 2>&1
        fi
        """#, asRoot: true)
    }

    public static func updateHistory() -> RemoteScript {
        RemoteScript("softwareupdate --history 2>&1 | head -n 40")
    }

    /// mas ≥ 4 runs sudo itself; `with_askpass` supplies the askpass and DISPLAY sudo needs without a tty.
    /// Updates apps bought with the Apple ID signed into the App Store on the admin account.
    public static func masUpgrade() -> RemoteScript {
        RemoteScript(#"""
        if ! command -v mas >/dev/null 2>&1; then
          echo "Brak narzędzia mas (App Store CLI). Zainstaluj: brew install mas" >&2; exit 2
        fi
        mas outdated
        with_askpass mas upgrade
        """#)
    }

    // MARK: - Files (cmcr-push / cmcr-pull)

    /// Numeric chmod modes as used by the presets (cmcr-push: 777) applied with `chmod -R` would make folders
    /// unopenable (644, 700) or every plain file executable (755, 777). They are translated to symbolic
    /// modes with `X`: folders keep execute (search) wherever read is allowed, files only when they were
    /// already executable. 644 → files 644 / folders 755, 700 → 600 / 700, 777 → 666 / 777.
    /// Other values are returned unchanged.
    public static func dirSafeMode(_ mode: String) -> String {
        var digits = mode.trimmingCharacters(in: .whitespaces)
        if digits.count == 4, digits.hasPrefix("0") { digits.removeFirst() }
        guard digits.count == 3, digits.allSatisfy({ ("0"..."7").contains($0) }) else { return mode }
        return zip(["u", "g", "o"], digits).map { who, ch -> String in
            let d = Int(String(ch))!
            var p = ""
            if d & 4 != 0 { p += "r" }
            if d & 2 != 0 { p += "w" }
            if d & 5 != 0 { p += "X" }
            return "\(who)=\(p)"
        }.joined(separator: ",")
    }

    /// Moves an uploaded archive into its destination and fixes owner and permissions (cmcr-push).
    ///
    /// - The archive is unpacked into a hidden folder inside the destination, then each item is renamed into
    ///   place: no second copy, and a file or `.app` bundle replaces the old one as a whole (a merged bundle
    ///   has stale files and a broken signature). Existing folders are merged, like `scp -r`.
    /// - An empty `owner` as root means "like the destination folder", so pushed files never stay root-owned.
    /// - `{console}` with nobody logged in stops with code 3; a missing home folder is never created.
    public static func pushFinalize(remoteTar: String, destination: String, owner: String, mode: String,
                                    asRoot: Bool) -> RemoteScript {
        RemoteScript(#"""
        TAR=\#(shQuote(remoteTar)); DEST=\#(shQuote(destination)); OWNER=\#(shQuote(owner)); MODE=\#(shQuote(dirSafeMode(mode)))
        cmcr_on_exit 'rm -f "$TAR"'
        cmcr_require_console "$DEST" "$OWNER"
        DEST="${DEST//\{console\}/$CONSOLE_USER}"; OWNER="${OWNER//\{console\}/$CONSOLE_USER}"
        DEST="${DEST/#\~/$HOME}"
        while [ "${DEST%/}" != "$DEST" ]; do DEST="${DEST%/}"; done
        case "$DEST" in /?*) ;; *) echo "✘ Folder docelowy musi być pełną ścieżką (np. /Users/student/Desktop): „$DEST”" >&2; exit 2 ;; esac
        case "$DEST/" in */../*|*/./*|*//*) echo "✘ Niepoprawna ścieżka docelowa: $DEST" >&2; exit 2 ;; esac
        case "$MODE" in *[!0-7ugoarwxXst=+,-]*) echo "✘ Niepoprawne uprawnienia: $MODE" >&2; exit 2 ;; esac
        P="$DEST"
        while [ ! -e "$P" ] && [ ! -L "$P" ]; do P="$(dirname "$P")"; done
        [ -d "$P" ] || { echo "✘ $P nie jest folderem" >&2; exit 2; }
        if [ "$P" != "$DEST" ]; then
          case "$P" in
            /|/Users|/Volumes|/private|/private/var|/System|/System/Volumes|/System/Volumes/Data)
              echo "✘ Folder $(dirname "$DEST") nie istnieje na tym Macu (np. konto bez katalogu domowego) – nie tworzę go." >&2; exit 2 ;;
          esac
        fi
        if [ -z "$OWNER" ] && [ "$EUID" -eq 0 ]; then
          OWNER="$(stat -f '%Su:%Sg' "$P")"
          echo "→ Właściciel jak w folderze docelowym: $OWNER"
        fi
        if [ "$P" != "$DEST" ]; then
          mkdir -p "$DEST" || { echo "✘ Nie można utworzyć $DEST" >&2; exit 2; }
          if [ -n "$OWNER" ]; then
            D="$DEST"; while [ "$D" != "$P" ]; do chown "$OWNER" "$D" 2>/dev/null; D="$(dirname "$D")"; done
          fi
        fi
        [ -d "$DEST" ] || { echo "✘ $DEST nie jest folderem" >&2; exit 2; }
        STAGE="$(mktemp -d "$DEST/.cmcr-push.XXXXXX")" || { echo "✘ Brak prawa zapisu w $DEST" >&2; exit 2; }
        cmcr_on_exit 'rm -rf "$STAGE"'
        tar -xf "$TAR" --no-same-owner -C "$STAGE"; X=$?
        rm -f "$TAR"
        [ $X = 0 ] || { echo "✘ Nie udało się rozpakować przesłanych plików" >&2; exit 2; }
        RC=0; DONE=()
        for item in "$STAGE"/* "$STAGE"/.[!.]* "$STAGE"/..?*; do
          [ -e "$item" ] || [ -L "$item" ] || continue
          n="$(basename "$item")"; t="$DEST/$n"
          if [ -d "$item" ] && [ ! -L "$item" ] && [ -d "$t" ] && [ ! -L "$t" ] && [ "${n%.app}" = "$n" ]; then
            ditto "$item" "$t" || { echo "✘ Kopiowanie $n do $DEST nie powiodło się" >&2; RC=1; continue; }
          else
            if [ -e "$t" ] || [ -L "$t" ]; then
              if ! mv "$t" "$STAGE/.cmcr-old-$n" 2>/dev/null; then
                echo "✘ Nie można zastąpić $t" >&2
                case "$n" in *.app) echo "  Jeśli aplikacja nie jest uruchomiona: włącz „Pełny dostęp do dysku dla zdalnych użytkowników” (Ustawienia systemowe › Ogólne › Udostępnianie › Zdalne logowanie)." >&2 ;; esac
                RC=1; continue
              fi
            fi
            if ! mv "$item" "$t"; then
              mv "$STAGE/.cmcr-old-$n" "$t" 2>/dev/null
              echo "✘ Nie można zapisać $t" >&2; RC=1; continue
            fi
          fi
          if [ -n "$OWNER" ]; then chown -R "$OWNER" "$t" || echo "⚠︎ chown $OWNER nie powiódł się dla $n" >&2; fi
          if [ -n "$MODE" ]; then chmod -R "$MODE" "$t" || echo "⚠︎ chmod $MODE nie powiódł się dla $n" >&2; fi
          case "$n" in *.app) xattr -dr com.apple.quarantine "$t" 2>/dev/null ;; esac
          DONE+=("$t")
          echo "✔ $t"
        done
        rm -rf "$STAGE"
        if [ ${#DONE[@]} -gt 0 ]; then echo "---"; ls -ld "${DONE[@]}"; fi
        exit $RC
        """#, asRoot: asRoot)
    }

    /// Streams a remote folder as tar to stdout (cmcr-pull transport).
    public static func pullArchive(source: String, asRoot: Bool) -> RemoteScript {
        RemoteScript(#"""
        SRC=\#(shQuote(source))
        cmcr_require_console "$SRC"
        SRC="${SRC//\{console\}/$CONSOLE_USER}"; SRC="${SRC/#\~/$HOME}"
        [ -d "$SRC" ] || { echo "Brak folderu: $SRC" >&2; exit 2; }
        echo "remote: ls -l $SRC" >&2
        ls -l "$SRC" >&2
        cd "$SRC" && COPYFILE_DISABLE=1 tar -cf - .
        """#, asRoot: asRoot)
    }

    /// Empties a folder inside a user account, /tmp or an external volume. The path is resolved first
    /// (`/Volumes/Macintosh HD` is a link to `/`), and Library, hidden folders (e.g. `.ssh`) and the
    /// administrator's home are refused. `dryRun` only lists what would be removed.
    public static func cleanFolder(_ path: String, dryRun: Bool = false) -> RemoteScript {
        RemoteScript(#"""
        DIR=\#(shQuote(path)); DRY=\#(dryRun ? 1 : 0)
        cmcr_require_console "$DIR"
        DIR="${DIR//\{console\}/$CONSOLE_USER}"
        while [ "${DIR%/}" != "$DIR" ]; do DIR="${DIR%/}"; done
        case "$DIR/" in */../*|*/./*|*//*) echo "Odmowa: ścieżka nie może zawierać . , .. ani //" >&2; exit 2 ;; esac
        case "$DIR" in /?*) ;; *) echo "Odmowa: podaj pełną ścieżkę (podano: $DIR)" >&2; exit 2 ;; esac
        [ -d "$DIR" ] || { echo "Brak folderu: $DIR"; exit 0; }
        REAL="$(cmcr_realdir "$DIR")"
        [ -n "$REAL" ] || { echo "Odmowa: nie można otworzyć $DIR" >&2; exit 2; }
        case "$REAL" in
          /Users/?*/?*|/private/tmp/?*|/Volumes/?*/?*) ;;
          *) echo "Odmowa: czyszczenie dozwolone tylko w podfolderach /Users/<konto>/…, /tmp lub /Volumes/<dysk>/… (podano: $DIR → $REAL)" >&2; exit 2 ;;
        esac
        case "$REAL" in
          /Users/*)
            REL="${REAL#/Users/}"; ACCT="${REL%%/*}"; SUB="${REL#*/}"
            if [ "$ACCT" = "$CMCR_ADMIN_USER" ]; then echo "Odmowa: folder domowy administratora ($REAL) jest chroniony." >&2; exit 2; fi
            case "$SUB" in
              Library|Library/*|.*) echo "Odmowa: $REAL to folder systemowy konta (Library lub ukryty)." >&2; exit 2 ;;
            esac ;;
        esac
        if [ $DRY = 1 ]; then
          echo "Do usunięcia z $REAL:"; find "$REAL" -mindepth 1 -maxdepth 1 -print; exit 0
        fi
        if find "$REAL" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; then
          echo "Wyczyszczono $REAL"
        else
          echo "⚠︎ Nie wszystko udało się usunąć. Foldery Biurko/Dokumenty wymagają „Pełnego dostępu do dysku dla zdalnych użytkowników”." >&2
          RC=1
        fi
        ls -la "$REAL"
        exit ${RC:-0}
        """#, asRoot: true)
    }

    public static func listFolder(_ path: String, asRoot: Bool) -> RemoteScript {
        RemoteScript(#"""
        DIR=\#(shQuote(path))
        cmcr_require_console "$DIR"
        DIR="${DIR//\{console\}/$CONSOLE_USER}"
        ls -la "$DIR"
        """#, asRoot: asRoot)
    }

    /// README "Prepare files moving" on the remote side: shared folder writable by everyone. A missing home
    /// folder of the account is not created (macOS builds it from the template at the first login).
    public static func prepareSharedFolder(_ path: String, owner: String) -> RemoteScript {
        RemoteScript(#"""
        DIR=\#(shQuote(path)); OWNER=\#(shQuote(owner))
        U="${OWNER%%:*}"
        while [ "${DIR%/}" != "$DIR" ]; do DIR="${DIR%/}"; done
        case "$DIR" in /?*) ;; *) echo "✘ Podaj pełną ścieżkę folderu (podano: $DIR)" >&2; exit 2 ;; esac
        case "$DIR/" in */../*|*/./*|*//*) echo "✘ Niepoprawna ścieżka: $DIR" >&2; exit 2 ;; esac
        id "$U" >/dev/null 2>&1 || { echo "✘ Konto $U nie istnieje na tym Macu." >&2; exit 2; }
        H="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk 'NR == 1 {print $2}')"
        if [ -n "$H" ] && [ ! -d "$H" ]; then
          case "$DIR/" in
            "$H"/*) echo "✘ Konto $U nie ma jeszcze katalogu domowego ($H). Zaloguj się raz na to konto przy komputerze (albo wykonaj: sudo createhomedir -c -u $U) i powtórz." >&2; exit 2 ;;
          esac
        fi
        P="$DIR"; while [ ! -e "$P" ]; do P="$(dirname "$P")"; done
        if [ "$P" != "$DIR" ]; then
          case "$P" in /|/Users|/Volumes) echo "✘ Folder $(dirname "$DIR") nie istnieje – nie tworzę go." >&2; exit 2 ;; esac
        fi
        mkdir -p "$DIR" && chown "$OWNER" "$DIR" && chmod 777 "$DIR" && ls -ld "$DIR"
        """#, asRoot: true)
    }

    // MARK: - Session & power

    public static func message(title: String, text: String, asDialog: Bool) -> RemoteScript {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        // `activate` (osascript itself – no Apple Event to another app, so no Automation prompt) brings the
        // dialog to the front instead of behind a full-screen app.
        let apple = asDialog
            ? "activate\ndisplay dialog \"\(esc(text))\" with title \"\(esc(title))\" buttons {\"OK\"} default button \"OK\" with icon note giving up after 900"
            : "display notification \"\(esc(text))\" with title \"\(esc(title))\""
        let b64 = Data(apple.utf8).base64EncodedString()
        return RemoteScript(#"""
        if [ -z "$CONSOLE_USER" ]; then echo "Brak zalogowanego użytkownika." >&2; exit \#(ScriptCode.noConsoleUser); fi
        # The AppleScript travels on stdin; osascript is detached so the dialog does not block the job.
        echo \#(b64) | base64 -D | as_console_user /bin/sh -c 'S="$(cat)"; /usr/bin/osascript -e "$S" </dev/null >/dev/null 2>&1 &' \
          && echo "Wiadomość wysłana do $CONSOLE_USER."
        """#)
    }

    /// `force` ends the session at once (`launchctl bootout`, unsaved work is lost). Otherwise loginwindow is
    /// asked to log out (like  › Wyloguj without the confirmation): apps may ask to save and can cancel;
    /// the script waits up to `wait` seconds for the session to end.
    public static func logoutUser(force: Bool = true, wait: Int = 30) -> RemoteScript {
        if force {
            return RemoteScript(#"""
            if [ -z "$CONSOLE_USER" ]; then echo "Nikt nie jest zalogowany."; exit 0; fi
            launchctl bootout "gui/$CONSOLE_UID" && echo "Wylogowano $CONSOLE_USER."
            """#, asRoot: true)
        }
        return RemoteScript(#"""
        if [ -z "$CONSOLE_USER" ]; then echo "Nikt nie jest zalogowany."; exit 0; fi
        WHO="$CONSOLE_USER"; WAIT=\#(max(1, wait))
        as_console_user /usr/bin/osascript -e 'ignoring application responses' \
          -e 'tell application "loginwindow" to «event aevtrlgo»' -e 'end ignoring' </dev/null >/dev/null 2>&1 &
        P=$!
        echo "→ Poproszono o wylogowanie $WHO (aplikacje mogą zapytać o zapisanie zmian)."
        i=0
        while [ $i -lt $((WAIT * 2)) ]; do
          sleep 0.5; i=$((i + 1))
          if [ "$(stat -f%Su /dev/console 2>/dev/null)" != "$WHO" ]; then echo "✔ Wylogowano $WHO."; exit 0; fi
        done
        kill $P 2>/dev/null
        echo "⚠︎ $WHO jest nadal zalogowany (np. aplikacja czeka na zapisanie dokumentu) – użyj „Wyloguj natychmiast”." >&2
        exit 1
        """#)
    }

    /// Power actions run detached (the SSH session ends first). A FileVault Mac restarted with `shutdown`
    /// stops at the unlock screen – unreachable over SSH until someone types a password – so a restart uses
    /// `fdesetup authrestart` when the stored password belongs to a FileVault-enabled admin.
    public static func power(_ action: PowerAction) -> RemoteScript {
        switch action {
        case .restart:
            return RemoteScript(#"""
            if [ "$(fdesetup isactive 2>/dev/null)" = "true" ]; then
              if [ -n "$CMCR_PW" ] && [ "$(fdesetup supportsauthrestart 2>/dev/null)" = "true" ] \
                && fdesetup list 2>/dev/null | grep -q "^$CMCR_ADMIN_USER,"; then
                xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
                echo "FileVault: ponowne uruchamianie z jednorazowym odblokowaniem dysku (fdesetup authrestart) za 2 s…"
                printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Username</key><string>%s</string><key>Password</key><string>%s</string></dict></plist>\n' \
                  "$(xml "$CMCR_ADMIN_USER")" "$(xml "$CMCR_PW")" \
                  | ( trap '' HUP; sleep 2; fdesetup authrestart -inputplist ) >/dev/null 2>&1 &
                exit 0
              fi
              echo "⚠︎ FileVault jest włączony: po restarcie iMac zatrzyma się na ekranie odblokowania – ktoś musi wpisać hasło przy komputerze (do tego czasu SSH i Wake-on-LAN nie działają)." >&2
              if [ -z "$CMCR_PW" ]; then
                echo "  Zapisz hasło administratora w Konfiguracji, aby restartować z odblokowaniem (fdesetup authrestart)." >&2
              else
                echo "  Konto $CMCR_ADMIN_USER nie może odblokować FileVault (brak na liście fdesetup list)." >&2
              fi
            fi
            echo 'Ponowne uruchamianie za 2 s…'
            ( trap '' HUP; sleep 2; shutdown -r now ) </dev/null >/dev/null 2>&1 &
            """#, asRoot: true)
        case .shutdown:
            return RemoteScript(#"""
            if [ "$(fdesetup isactive 2>/dev/null)" = "true" ]; then
              echo "⚠︎ FileVault jest włączony: po włączeniu iMac poczeka na odblokowanie hasłem przy komputerze." >&2
            fi
            echo 'Wyłączanie za 2 s…'
            ( trap '' HUP; sleep 2; shutdown -h now ) </dev/null >/dev/null 2>&1 &
            """#, asRoot: true)
        case .sleep:
            return RemoteScript(#"""
            echo 'Usypianie…'
            ( trap '' HUP; sleep 1; pmset sleepnow ) </dev/null >/dev/null 2>&1 &
            """#, asRoot: true)
        case .displaySleep:
            return RemoteScript("pmset displaysleepnow && echo 'Ekran uśpiony.'")
        }
    }

    // MARK: - Remote setup

    /// Turning the service on from the command line usually gives observe-only VNC; full control has to be
    /// enabled once at the Mac (or by MDM), so the message says so instead of promising remote control.
    public static func enableScreenSharing() -> RemoteScript {
        RemoteScript(#"""
        launchctl enable system/com.apple.screensharing 2>/dev/null
        launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null
        if launchctl print system/com.apple.screensharing >/dev/null 2>&1; then
          echo "Usługa Udostępniania ekranu działa."
          echo "Uwaga: włączona zdalnie zwykle pozwala tylko na podgląd. Pełne sterowanie włącz raz przy komputerze: Ustawienia systemowe › Ogólne › Udostępnianie › Udostępnianie ekranu."
        else
          echo "Nie udało się włączyć usługi – włącz ją ręcznie: Ustawienia systemowe › Ogólne › Udostępnianie › Udostępnianie ekranu." >&2; exit 1
        fi
        """#, asRoot: true)
    }

    public static func enableWakeOnLAN() -> RemoteScript {
        RemoteScript("pmset -a womp 1 && pmset -g | grep -i womp", asRoot: true)
    }
}

public enum PowerAction: String, CaseIterable, Sendable {
    case restart, shutdown, sleep, displaySleep

    public var label: String {
        switch self {
        case .restart: return "Uruchom ponownie"
        case .shutdown: return "Wyłącz"
        case .sleep: return "Uśpij komputer"
        case .displaySleep: return "Uśpij ekran"
        }
    }
}
