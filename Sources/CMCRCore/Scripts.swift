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

    public static func status() -> RemoteScript {
        RemoteScript(#"""
        IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
        echo "name=$(scutil --get ComputerName 2>/dev/null)"
        echo "os=$(sw_vers -productVersion 2>/dev/null)"
        echo "build=$(sw_vers -buildVersion 2>/dev/null)"
        echo "model=$(sysctl -n hw.model 2>/dev/null)"
        echo "chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
        echo "arch=$(uname -m)"
        echo "mem=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))"
        echo "console=$CONSOLE_USER"
        echo "boot=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*sec = ([0-9]+).*/\1/')"
        echo "disk=$(df -k / 2>/dev/null | awk 'NR==2{print $2" "$4}')"
        echo "ip=$(ipconfig getifaddr "${IF:-en0}" 2>/dev/null)"
        echo "mac=$(ifconfig "${IF:-en0}" 2>/dev/null | awk '/ether/{print $2; exit}')"
        echo "sshuser=$(id -un)"
        if is_admin_user "$(id -un)"; then echo "admin=yes"; else echo "admin=no"; fi
        if sudo -n true 2>/dev/null; then echo "sudo_nopass=yes"; else echo "sudo_nopass=no"; fi
        """#)
    }

    /// Verifies that sudo works with the stored password.
    public static func sudoTest() -> RemoteScript {
        RemoteScript(#"echo "sudo OK – działam jako: $(id -un) (uid $(id -u)), administrator: $CMCR_ADMIN_USER""#, asRoot: true)
    }

    // MARK: - SSH keys (README: "Distribute your SSH key")

    public static func distributeKey(_ publicKey: String) -> RemoteScript {
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteScript(#"""
        KEY=\#(shQuote(key))
        if [[ ! -d ~/.ssh ]]; then mkdir ~/.ssh; fi
        chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys
        if grep -qxF "$KEY" ~/.ssh/authorized_keys; then
          echo "Klucz był już zainstalowany."
        else
          echo "$KEY" >> ~/.ssh/authorized_keys
          echo "Klucz dodany do ~/.ssh/authorized_keys."
        fi
        chmod 600 ~/.ssh/authorized_keys
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
    public static func launchApp(_ app: String, arguments: String = "") -> RemoteScript {
        var openArgs = "-a \"$APP\""
        if !arguments.trimmingCharacters(in: .whitespaces).isEmpty {
            openArgs += " --args " + arguments
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

    /// Opens a URL or a file in the user's session (default application).
    public static func openURL(_ url: String) -> RemoteScript {
        RemoteScript(#"""
        TARGET=\#(shQuote(url))
        as_console_user /usr/bin/open "$TARGET" && echo "Otwarto: $TARGET"
        """#)
    }

    /// Quits an application by name (`Safari`) or bundle path in the console user's session.
    public static func quitApp(_ app: String, force: Bool) -> RemoteScript {
        let needle = app.hasSuffix(".app") && app.hasPrefix("/")
            ? app + "/Contents/MacOS/"
            : "/" + (app.hasSuffix(".app") ? String(app.dropLast(4)) : app) + ".app/Contents/MacOS/"
        return RemoteScript(#"""
        NEEDLE=\#(shQuote(needle))
        SIG=\#(force ? "KILL" : "TERM")
        if [ -z "$CONSOLE_USER" ]; then echo "Brak zalogowanego użytkownika."; exit 0; fi
        PIDS="$(ps -axww -o pid=,user=,comm= | awk -v u="$CONSOLE_USER" -v n="$NEEDLE" '$2 == u && index($0, n) > 0 {print $1}')"
        if [ -z "$PIDS" ]; then echo "Aplikacja nie jest uruchomiona."; exit 0; fi
        asroot kill -"$SIG" $PIDS && echo "Wysłano SIG$SIG do procesów: $(echo $PIDS)"
        """#)
    }

    public static func killProcess(_ pid: Int, force: Bool) -> RemoteScript {
        RemoteScript(#"""
        asroot kill -\#(force ? "KILL" : "TERM") \#(pid) && echo "Wysłano SIG\#(force ? "KILL" : "TERM") do PID \#(pid)."
        """#)
    }

    public static func uninstallApp(_ path: String) -> RemoteScript {
        RemoteScript(#"""
        APP=\#(shQuote(path))
        case "$APP" in
          /Applications/*.app|/Applications/*/*.app) ;;
          *) echo "Odinstalowywać można tylko aplikacje z /Applications." >&2; exit 2 ;;
        esac
        [ -e "$APP" ] || { echo "Nie znaleziono: $APP"; exit 0; }
        NAME="$(basename "$APP" .app)"
        PIDS="$(pgrep -f "/$NAME.app/Contents/MacOS/")"
        [ -n "$PIDS" ] && kill -KILL $PIDS 2>/dev/null
        rm -rf "$APP" && echo "Usunięto $APP"
        """#, asRoot: true)
    }

    // MARK: - Installing software

    /// Shell functions that install .pkg/.mpkg/.dmg/.zip/.app items (run as root).
    static let installLibrary = #"""
    cmcr_install_app_bundle() {
      local src="$1" name; name="$(basename "$src")"
      local dst="/Applications/$name"
      echo "→ Kopiowanie $name do /Applications"
      if [ -e "$dst" ]; then rm -rf "$dst.cmcr-old"; mv "$dst" "$dst.cmcr-old"; fi
      if ditto "$src" "$dst"; then
        rm -rf "$dst.cmcr-old"
        xattr -dr com.apple.quarantine "$dst" 2>/dev/null
        chown -R root:admin "$dst" 2>/dev/null
        echo "✔ Zainstalowano $name"
      else
        [ -e "$dst.cmcr-old" ] && { rm -rf "$dst"; mv "$dst.cmcr-old" "$dst"; }
        echo "✘ Nie udało się skopiować $name" >&2; return 1
      fi
    }
    cmcr_install_pkg() {
      echo "→ installer -pkg $(basename "$1")"
      installer -pkg "$1" -target / && echo "✔ Zainstalowano pakiet $(basename "$1")"
    }
    cmcr_install_dmg() {
      local mnt rc=0 found=0 p
      mnt="$(mktemp -d /tmp/cmcr-mnt.XXXXXX)"
      echo "→ Montowanie $(basename "$1")"
      if ! yes | hdiutil attach "$1" -nobrowse -noverify -noautoopen -mountpoint "$mnt" >/dev/null; then
        echo "✘ Nie można zamontować obrazu dysku" >&2; rmdir "$mnt"; return 1
      fi
      for p in "$mnt"/*.pkg "$mnt"/*.mpkg; do
        [ -e "$p" ] || continue; found=1; cmcr_install_pkg "$p" || rc=1
      done
      if [ $found = 0 ]; then
        for p in "$mnt"/*.app; do [ -e "$p" ] || continue; found=1; cmcr_install_app_bundle "$p" || rc=1; done
      fi
      hdiutil detach "$mnt" -quiet || hdiutil detach "$mnt" -force -quiet
      rmdir "$mnt" 2>/dev/null
      if [ $found = 0 ]; then echo "✘ W obrazie nie ma pliku .pkg ani .app" >&2; return 1; fi
      return $rc
    }
    cmcr_install_dir() {
      local found=0 rc=0 item
      while IFS= read -r -d '' item; do
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
        NAME="$(basename "${URL%%\?*}")"
        [ -n "$NAME" ] && [ "$NAME" != "/" ] || NAME="download"
        F="$CMCR_TMP/$NAME"
        echo "→ Pobieranie $URL"
        curl -fL --retry 2 --connect-timeout 20 -o "$F" "$URL" || { echo "✘ Pobieranie nie powiodło się" >&2; exit 2; }
        cmcr_install_item "$F"
        """#, asRoot: true)
    }

    public static func brew(_ arguments: String) -> RemoteScript {
        RemoteScript(#"""
        if ! command -v brew >/dev/null 2>&1; then
          echo "Homebrew nie jest zainstalowany (użyj „Zainstaluj Homebrew”)." >&2; exit 2
        fi
        export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 NONINTERACTIVE=1
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

    public static func unityInstallModules(version: String, modules: [String]) -> RemoteScript {
        unityHub(["install-modules", "--version", version] + modules.flatMap { ["-m", $0] })
    }

    public static func androidSDK(unityVersion: String, apiLevels: [String]) -> RemoteScript {
        let packages = ["platform-tools"] + apiLevels.map { "platforms;android-\($0)" }
        return RemoteScript(#"""
        BASE="/Applications/Unity/Hub/Editor/"\#(shQuote(unityVersion))"/PlaybackEngines/AndroidPlayer"
        SDKM="$(ls -d "$BASE"/SDK/cmdline-tools/*/bin/sdkmanager 2>/dev/null | tail -1)"
        if [ -z "$SDKM" ]; then echo "Nie znaleziono sdkmanager w $BASE/SDK/cmdline-tools – zainstaluj moduł Android w Unity." >&2; exit 2; fi
        for J in "$BASE/OpenJDK" "$BASE/OpenJDK/Contents/Home"; do
          if [ -x "$J/bin/java" ]; then export JAVA_HOME="$J"; break; fi
        done
        echo "→ $SDKM ${JAVA_HOME:+(JAVA_HOME=$JAVA_HOME)}"
        yes | "$SDKM" \#(packages.map(shQuote).joined(separator: " "))
        """#)
    }

    // MARK: - Software updates

    public static func listUpdates() -> RemoteScript {
        RemoteScript("softwareupdate --list 2>&1")
    }

    public static func installUpdates(restart: Bool, recommendedOnly: Bool, downloadOnly: Bool) -> RemoteScript {
        var args = [downloadOnly ? "--download" : "--install"]
        args.append(recommendedOnly ? "--recommended" : "--all")
        if !downloadOnly {
            args.append("--agree-to-license")
            if restart { args.append("--restart") }
        }
        let joined = args.joined(separator: " ")
        return RemoteScript(#"""
        echo "→ softwareupdate \#(joined)"
        if [ "$(uname -m)" = "arm64" ] && [ -n "$CMCR_PW" ]; then
          # Apple Silicon requires an owner's credentials for OS updates.
          printf '%s\n' "$CMCR_PW" | softwareupdate \#(joined) --user "$CMCR_ADMIN_USER" --stdinpass 2>&1
        else
          softwareupdate \#(joined) 2>&1
        fi
        """#, asRoot: true)
    }

    public static func updateHistory() -> RemoteScript {
        RemoteScript("softwareupdate --history 2>&1 | head -n 40")
    }

    public static func masUpgrade() -> RemoteScript {
        RemoteScript(#"""
        if ! command -v mas >/dev/null 2>&1; then
          echo "Brak narzędzia mas (App Store CLI). Zainstaluj: brew install mas" >&2; exit 2
        fi
        mas outdated; mas upgrade
        """#)
    }

    // MARK: - Files (cmcr-push / cmcr-pull)

    /// Moves an uploaded archive into its destination, fixing owner and permissions (cmcr-push `chmod 777`).
    public static func pushFinalize(remoteTar: String, destination: String, owner: String, mode: String,
                                    asRoot: Bool) -> RemoteScript {
        RemoteScript(#"""
        TAR=\#(shQuote(remoteTar)); DEST=\#(shQuote(destination)); OWNER=\#(shQuote(owner)); MODE=\#(shQuote(mode))
        DEST="${DEST//\{console\}/$CONSOLE_USER}"; OWNER="${OWNER//\{console\}/$CONSOLE_USER}"
        DEST="${DEST/#\~/$HOME}"
        STAGE="$CMCR_TMP/stage"; mkdir -p "$STAGE"
        tar -xf "$TAR" --no-same-owner -C "$STAGE"; X=$?
        rm -f "$TAR"
        [ $X = 0 ] || { echo "✘ Nie udało się rozpakować przesłanych plików" >&2; exit 2; }
        mkdir -p "$DEST" || { echo "✘ Nie można utworzyć $DEST" >&2; exit 2; }
        ditto "$STAGE" "$DEST" || { echo "✘ Kopiowanie do $DEST nie powiodło się" >&2; exit 2; }
        for item in "$STAGE"/* "$STAGE"/.[!.]*; do
          [ -e "$item" ] || continue
          n="$(basename "$item")"
          if [ -n "$OWNER" ]; then chown -R "$OWNER" "$DEST/$n" || echo "⚠︎ chown $OWNER nie powiódł się dla $n" >&2; fi
          if [ -n "$MODE" ]; then chmod -R "$MODE" "$DEST/$n" || echo "⚠︎ chmod $MODE nie powiódł się dla $n" >&2; fi
          echo "✔ $DEST/$n"
        done
        echo "---"
        ls -l "$DEST"
        """#, asRoot: asRoot)
    }

    /// Streams a remote folder as tar to stdout (cmcr-pull transport).
    public static func pullArchive(source: String, asRoot: Bool) -> RemoteScript {
        RemoteScript(#"""
        SRC=\#(shQuote(source))
        SRC="${SRC//\{console\}/$CONSOLE_USER}"; SRC="${SRC/#\~/$HOME}"
        [ -d "$SRC" ] || { echo "Brak folderu: $SRC" >&2; exit 2; }
        echo "remote: ls -l $SRC" >&2
        ls -l "$SRC" >&2
        cd "$SRC" && COPYFILE_DISABLE=1 tar -cf - .
        """#, asRoot: asRoot)
    }

    public static func cleanFolder(_ path: String) -> RemoteScript {
        RemoteScript(#"""
        DIR=\#(shQuote(path))
        DIR="${DIR//\{console\}/$CONSOLE_USER}"
        while [ "${DIR%/}" != "$DIR" ]; do DIR="${DIR%/}"; done
        case "$DIR" in *..*|*/./*) echo "Odmowa: ścieżka nie może zawierać .. ani ./" >&2; exit 2 ;; esac
        # Only folders inside an account (/Users/<account>/…), temporary folders or external volumes.
        case "$DIR" in
          /Users/*/?*|/tmp/?*|/private/tmp/?*|/Volumes/*/?*) ;;
          *) echo "Odmowa: czyszczenie dozwolone tylko w podfolderach /Users/<konto>/…, /tmp lub /Volumes (podano: $DIR)" >&2; exit 2 ;;
        esac
        [ -d "$DIR" ] || { echo "Brak folderu: $DIR"; exit 0; }
        find "$DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + && echo "Wyczyszczono $DIR"
        ls -la "$DIR"
        """#, asRoot: true)
    }

    public static func listFolder(_ path: String, asRoot: Bool) -> RemoteScript {
        RemoteScript(#"""
        DIR=\#(shQuote(path)); DIR="${DIR//\{console\}/$CONSOLE_USER}"
        ls -la "$DIR"
        """#, asRoot: asRoot)
    }

    /// README "Prepare files moving" on the remote side: shared folder writable by everyone.
    public static func prepareSharedFolder(_ path: String, owner: String) -> RemoteScript {
        RemoteScript(#"""
        DIR=\#(shQuote(path)); OWNER=\#(shQuote(owner))
        mkdir -p "$DIR" && chown "$OWNER" "$DIR" && chmod 777 "$DIR" && ls -ld "$DIR"
        """#, asRoot: true)
    }

    // MARK: - Session & power

    public static func message(title: String, text: String, asDialog: Bool) -> RemoteScript {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let apple = asDialog
            ? "display dialog \"\(esc(text))\" with title \"\(esc(title))\" buttons {\"OK\"} default button \"OK\" with icon note giving up after 900"
            : "display notification \"\(esc(text))\" with title \"\(esc(title))\""
        let b64 = Data(apple.utf8).base64EncodedString()
        return RemoteScript(#"""
        if [ -z "$CONSOLE_USER" ]; then echo "Brak zalogowanego użytkownika." >&2; exit \#(ScriptCode.noConsoleUser); fi
        # The AppleScript travels on stdin; osascript is detached so the dialog does not block the job.
        echo \#(b64) | base64 -D | as_console_user /bin/sh -c 'S="$(cat)"; /usr/bin/osascript -e "$S" </dev/null >/dev/null 2>&1 &' \
          && echo "Wiadomość wysłana do $CONSOLE_USER."
        """#)
    }

    public static func logoutUser() -> RemoteScript {
        RemoteScript(#"""
        if [ -z "$CONSOLE_USER" ]; then echo "Nikt nie jest zalogowany."; exit 0; fi
        launchctl bootout "gui/$CONSOLE_UID" && echo "Wylogowano $CONSOLE_USER."
        """#, asRoot: true)
    }

    public static func power(_ action: PowerAction) -> RemoteScript {
        switch action {
        case .restart: return RemoteScript("echo 'Ponowne uruchamianie za 2 s…'; nohup /bin/sh -c 'sleep 2; shutdown -r now' </dev/null >/dev/null 2>&1 &", asRoot: true)
        case .shutdown: return RemoteScript("echo 'Wyłączanie za 2 s…'; nohup /bin/sh -c 'sleep 2; shutdown -h now' </dev/null >/dev/null 2>&1 &", asRoot: true)
        case .sleep: return RemoteScript("echo 'Usypianie…'; nohup /bin/sh -c 'sleep 1; pmset sleepnow' </dev/null >/dev/null 2>&1 &", asRoot: true)
        case .displaySleep: return RemoteScript("pmset displaysleepnow && echo 'Ekran uśpiony.'")
        }
    }

    // MARK: - Remote setup

    public static func enableScreenSharing() -> RemoteScript {
        RemoteScript(#"""
        launchctl enable system/com.apple.screensharing 2>/dev/null
        launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null
        if launchctl print system/com.apple.screensharing >/dev/null 2>&1; then
          echo "Usługa Udostępniania ekranu jest załadowana."
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
