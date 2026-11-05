import Foundation

// CMCR Screen Agent on the iMac (docs/screen-agent.md): the shell shared by the preview, the readiness check and
// the agent's own operations, and the scripts that install, remove, query and ask for the permission.

public extension Scripts {
    /// The agent's files on the iMac. Needs `R` (the test-only `CMCR_SETUP_ROOT_PREFIX`, empty on a real iMac) to be
    /// set first; every value is `$R`-prefixed, so the e2e tests never touch the real system folders.
    static let screenAgentShellPaths = #"""
    CMCR_AGENT_DIR="$R"\#(shQuote(ScreenAgentInfo.installDir))
    CMCR_AGENT_APP="$R"\#(shQuote(ScreenAgentInfo.appPath))
    CMCR_AGENT_EXE="$R"\#(shQuote(ScreenAgentInfo.executablePath))
    CMCR_AGENT_PLIST="$R"\#(shQuote(ScreenAgentInfo.plistPath))
    CMCR_AGENT_RUN="$R"\#(shQuote(ScreenAgentInfo.runDir))
    CMCR_AGENT_SOCKET=\#(shQuote(ScreenAgentInfo.socketName))
    CMCR_AGENT_SHOTS="$R"\#(shQuote(ScreenAgentInfo.shotsDir))
    CMCR_AGENT_LABEL=\#(shQuote(ScreenAgentInfo.label))
    """#

    /// Shell functions around the agent (after `screenAgentShellPaths`):
    /// - `cmcr_agent_version` – installed version, empty when the agent is not installed;
    /// - `cmcr_agent_loaded UID` – launchd has the agent in that GUI session;
    /// - `cmcr_agent_pid UID` – the pid launchd reports for the running agent of that session (empty: not running);
    /// - `cmcr_agent_client UID CMD…` – `cmcr-screen-agent client UID CMD… --pid <that pid>`: the client accepts only
    ///   the process launchd started; without a running agent it answers `ERR unreachable` (code 10) by itself;
    /// - `cmcr_agent_rundir_ok UID` – `run/<uid>` is a real folder of that account with mode 0700;
    /// - `cmcr_agent_rundir UID` – the agent's own folder `run/<uid>` (owner uid, 0700) in the root-only `run` (0755),
    ///   made before every `bootstrap`/`kickstart` of that account's agent;
    /// - `cmcr_agent_wait UID SECONDS` – waits until the agent of that session answers `ping`;
    /// - `cmcr_agent_revive UID [SECONDS]` – `bootstrap` (not loaded) or `kickstart -k` (loaded), then waits;
    /// - `cmcr_agent_timed SECONDS CMD…` – runs CMD, stopped after SECONDS;
    /// - `cmcr_agent_ping UID` – one `ping`: the line in `CMCR_AGENT_LINE`, the client's code in `CMCR_AGENT_RC`;
    /// - `cmcr_agent_fresh UID` – after a ping that said `perm=denied`: the agent started anew and asked again (macOS
    ///   keeps the Screen Recording decision for the lifetime of a process);
    /// - `cmcr_agent_probe UID` – `agent_loaded`, `agent_ping`, `agent_ping_rc` lines (`ScreenAgentStatus.parse`),
    ///   with a fresh permission state.
    ///
    /// Talking to another account's agent and anything in its `gui/<uid>` domain needs root (or that account).
    static let screenAgentShellFunctions = #"""
    cmcr_agent_version() {
      [ -x "$CMCR_AGENT_EXE" ] || return 0
      /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CMCR_AGENT_APP/Contents/Info.plist" 2>/dev/null
    }
    cmcr_agent_loaded() { launchctl print "gui/$1/$CMCR_AGENT_LABEL" >/dev/null 2>&1; }
    # The "pid = N" line of the service itself (one tab deep; nested sections are indented further).
    cmcr_agent_pid() {
      launchctl print "gui/$1/$CMCR_AGENT_LABEL" 2>/dev/null \
        | awk -F' = ' '$1 == "\tpid" && $2 ~ /^[0-9]+$/ { print $2; exit }'
    }
    # Loaded without a process (or not loaded at all) is an agent that does not answer, like the client's code 10.
    cmcr_agent_nopid() {
      echo "ERR unreachable usługa nie działa w sesji użytkownika (launchd nie podaje jej procesu)"
      return \#(ScreenAgentInfo.ClientCode.unreachable)
    }
    cmcr_agent_client() {
      local uid="$1" pid
      shift
      pid="$(cmcr_agent_pid "$uid")"
      [ -n "$pid" ] || { cmcr_agent_nopid; return; }
      "$CMCR_AGENT_EXE" client "$uid" "$@" --pid "$pid"
    }
    # The folder is as the agent needs it: a real folder (not a link) of that account, closed to others.
    cmcr_agent_rundir_ok() {
      local d="$CMCR_AGENT_RUN/$1"
      [ ! -L "$d" ] && [ -d "$d" ] && [ "$(stat -f %u "$d" 2>/dev/null)" = "$1" ] && [ "$(stat -f %Lp "$d" 2>/dev/null)" = 700 ]
    }
    # Only root can make the folder; anything else at that name – a file, a link, a folder of another account, left
    # by an older version or planted before run/ was root-only – is removed first (the entry itself, never what a
    # link points to). Nobody but root can add or remove entries in run/ afterwards.
    cmcr_agent_rundir() {
      local d="$CMCR_AGENT_RUN/$1" g
      mkdir -p "$CMCR_AGENT_RUN" 2>/dev/null
      chown root:wheel "$CMCR_AGENT_RUN" 2>/dev/null && chmod 755 "$CMCR_AGENT_RUN" 2>/dev/null
      if [ -L "$d" ] || { [ -e "$d" ] && { [ ! -d "$d" ] || [ "$(stat -f %u "$d" 2>/dev/null)" != "$1" ]; }; }; then
        rm -rf "$d" 2>/dev/null
      fi
      if [ ! -d "$d" ]; then
        g="$(id -g "$1" 2>/dev/null)"
        { mkdir -m 700 "$d" && chown "$1:${g:-20}" "$d"; } 2>/dev/null || return 1
      fi
      chmod 700 "$d" 2>/dev/null
      return 0
    }
    # The socket alone proves nothing: a killed agent leaves its old one behind until launchd starts it again.
    cmcr_agent_wait() {
      local end=$((SECONDS + ${2:-5}))
      while :; do
        if cmcr_agent_client "$1" ping </dev/null >/dev/null 2>&1; then return 0; fi
        [ "$SECONDS" -ge "$end" ] && return 1
        sleep 0.3
      done
    }
    # A student can disable the agent in their own session (launchctl disable gui/<uid>/…): enabled again first.
    cmcr_agent_revive() {
      launchctl enable "gui/$1/$CMCR_AGENT_LABEL" >/dev/null 2>&1
      cmcr_agent_rundir "$1"
      if cmcr_agent_loaded "$1"; then
        launchctl kickstart -k "gui/$1/$CMCR_AGENT_LABEL" >/dev/null 2>&1
      else
        launchctl bootstrap "gui/$1" "$CMCR_AGENT_PLIST" >/dev/null 2>&1
      fi
      cmcr_agent_wait "$1" "${2:-5}"
    }
    cmcr_agent_timed() {
      local t="$1" p w rc
      shift
      "$@" </dev/null & p=$!
      ( sleep "$t"; kill "$p" 2>/dev/null ) </dev/null >/dev/null 2>&1 & w=$!
      wait "$p"; rc=$?
      kill "$w" 2>/dev/null
      return $rc
    }
    cmcr_agent_ping() {
      local out pid
      pid="$(cmcr_agent_pid "$1")"
      if [ -z "$pid" ]; then out="$(cmcr_agent_nopid)"; CMCR_AGENT_RC=$?
      else out="$(cmcr_agent_timed 15 "$CMCR_AGENT_EXE" client "$1" ping --pid "$pid" 2>&1)"; CMCR_AGENT_RC=$?; fi
      CMCR_AGENT_LINE="$(printf '%s\n' "$out" | grep -E '^(AGENT|ERR)( |$)' | head -n 1)"
      if [ -z "$CMCR_AGENT_LINE" ]; then
        if [ $CMCR_AGENT_RC -ge 128 ]; then CMCR_AGENT_LINE="ERR timeout brak odpowiedzi w ciągu 15 s"
        else CMCR_AGENT_LINE="ERR failed $(printf '%s\n' "$out" | grep -v '^ *$' | head -n 1)"; fi
      fi
      CMCR_AGENT_LINE="$(printf '%s' "$CMCR_AGENT_LINE" | tr '\r\n' '  ')"
      return $CMCR_AGENT_RC
    }
    # The agent never ends itself after a ping, so a permission granted at the computer since it started would stay
    # unseen: whoever needs the current state restarts it once (a fresh process reads the permission anew).
    cmcr_agent_fresh() {
      case "$CMCR_AGENT_LINE" in AGENT\ *perm=denied*) ;; *) return 0 ;; esac
      cmcr_agent_revive "$1" 10
      cmcr_agent_ping "$1"
    }
    cmcr_agent_probe() {
      if cmcr_agent_loaded "$1"; then echo "agent_loaded=1"; else echo "agent_loaded=0"; fi
      [ -x "$CMCR_AGENT_EXE" ] || return 0
      cmcr_agent_ping "$1"
      cmcr_agent_fresh "$1"
      echo "agent_ping=$CMCR_AGENT_LINE"
      echo "agent_ping_rc=$CMCR_AGENT_RC"
    }
    """#

    /// `declare` lines that carry `screenAgentShellPaths` and `screenAgentShellFunctions` into a script run as root
    /// through `asroot /bin/bash … file` (status and readiness write their root part to a file).
    static let screenAgentShellExport = """
    declare -p CMCR_AGENT_DIR CMCR_AGENT_APP CMCR_AGENT_EXE CMCR_AGENT_PLIST CMCR_AGENT_RUN CMCR_AGENT_SOCKET \\
      CMCR_AGENT_SHOTS CMCR_AGENT_LABEL
    declare -f cmcr_agent_version cmcr_agent_loaded cmcr_agent_pid cmcr_agent_nopid cmcr_agent_client cmcr_agent_rundir_ok cmcr_agent_rundir cmcr_agent_wait \\
      cmcr_agent_revive cmcr_agent_timed cmcr_agent_ping cmcr_agent_fresh cmcr_agent_probe
    """

    /// `cmcr_agent_plist` – prints the LaunchAgent (`ScreenAgentInfo.launchAgentPlist`) for the `$R`-prefixed
    /// executable, so a test install under `CMCR_SETUP_ROOT_PREFIX` starts its own copy.
    static var screenAgentPlistShell: String {
        let marker = "CMCR-AGENT-EXECUTABLE"
        let parts = ScreenAgentInfo.launchAgentPlist(executable: marker).components(separatedBy: marker)
        return """
        cmcr_agent_plist() {
          local e
          e="$(printf '%s' "$CMCR_AGENT_EXE" | sed -e 's/&/\\&amp;/g' -e 's/</\\&lt;/g' -e 's/>/\\&gt;/g')"
          printf '%s' \(parts.map(shQuote).joined(separator: " \"$e\" "))
        }
        """
    }

    private static var screenAgentShell: String {
        #"R="${CMCR_SETUP_ROOT_PREFIX:-}""# + "\n" + screenAgentShellPaths + "\n" + screenAgentShellFunctions
    }

    /// Installs or updates CMCR Screen Agent from an uploaded archive (`Operations.installScreenAgent`), as root.
    ///
    /// The same version with a valid signature stays untouched – with an ad-hoc signature every replaced file loses
    /// the Screen Recording permission – and is only started where it is not running. A valid newer version is never
    /// replaced by an older one (another teacher's newer CMCR Manager installed it): `CMCR:AGENT newer <installed>`,
    /// nothing changed. An older or invalid copy is replaced atomically (staged next to it, stopped in every GUI session
    /// first). Prints `CMCR:AGENT <installed|updated|unchanged> <version>` and `CMCR:AGENT-SESSION <account> <uid>
    /// <ping line or ERR …>` for every GUI session.
    static func installScreenAgent(remoteTar: String) -> RemoteScript {
        RemoteScript(screenAgentShell + "\n" + screenAgentPlistShell + "\n" + #"""
        TAR=\#(shQuote(remoteTar))
        NEXT=""; OLD=""; STOPPED=0; SESSIONS="$(cmcr_gui_sessions)"
        # Every session where the agent was stopped gets it back, also after a failed update.
        cmcr_agent_start_all() {
          local uid user
          while read -r uid user; do
            [ -n "$uid" ] || continue
            launchctl enable "gui/$uid/$CMCR_AGENT_LABEL" >/dev/null 2>&1
            cmcr_agent_loaded "$uid" && continue
            cmcr_agent_rundir "$uid"
            launchctl bootstrap "gui/$uid" "$CMCR_AGENT_PLIST" >/dev/null 2>&1
          done <<CMCR_AGENT_SESSIONS
        $SESSIONS
        CMCR_AGENT_SESSIONS
        }
        fail() {
          echo "✘ $1" >&2
          [ -n "$NEXT" ] && rm -rf "$NEXT"
          if [ -n "$OLD" ] && [ -e "$OLD" ]; then
            [ -e "$CMCR_AGENT_APP" ] || mv "$OLD" "$CMCR_AGENT_APP" 2>/dev/null
            rm -rf "$OLD"
          fi
          [ $STOPPED = 1 ] && [ -x "$CMCR_AGENT_EXE" ] && cmcr_agent_start_all
          exit 1
        }
        STAGE="$CMCR_TMP/agent"; mkdir -p "$STAGE"
        tar -xf "$TAR" --no-same-owner -C "$STAGE"; X=$?
        rm -f "$TAR"
        [ $X = 0 ] || fail "Nie udało się rozpakować przesłanej usługi podglądu."
        NEW="$STAGE/"\#(shQuote(ScreenAgentInfo.appName))
        { [ -d "$NEW" ] && [ ! -L "$NEW" ]; } || fail "W przesłanym archiwum nie ma \#(ScreenAgentInfo.appName)."
        ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW/Contents/Info.plist" 2>/dev/null)"
        VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NEW/Contents/Info.plist" 2>/dev/null)"
        [ "$ID" = "$CMCR_AGENT_LABEL" ] || fail "Przesłana aplikacja ma identyfikator „${ID}” zamiast $CMCR_AGENT_LABEL."
        case "$VER" in ''|*[!0-9.]*) fail "Przesłana usługa ma nieprawidłową wersję „${VER}”." ;; esac
        NEW_EXE="$NEW/Contents/MacOS/"\#(shQuote(ScreenAgentInfo.executableName))
        { [ -f "$NEW_EXE" ] && [ -x "$NEW_EXE" ] && [ ! -L "$NEW_EXE" ]; } || fail "W przesłanej usłudze brakuje pliku wykonywalnego."
        codesign --verify --strict "$NEW" 2>"$CMCR_TMP/codesign.err" \
          || fail "Podpis przesłanej usługi jest nieprawidłowy: $(grep -v '^ *$' "$CMCR_TMP/codesign.err" | tail -n 1)"
        # The designated requirement decides whether macOS keeps the Screen Recording permission for a new copy:
        # with an ad-hoc signature it names this very build (cdhash), with a stable identity it stays the same.
        cmcr_agent_dr() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p' | head -n 1; }
        NEW_DR="$(cmcr_agent_dr "$NEW")"

        # cmcr_agent_newer A B – version A is newer than B (numbers compared part by part, a missing part is 0).
        cmcr_agent_newer() {
          local IFS=. i x y
          local -a a b
          case "$1" in ''|*[!0-9.]*) return 1 ;; esac
          case "$2" in ''|*[!0-9.]*) return 0 ;; esac
          read -r -a a <<<"$1"; read -r -a b <<<"$2"
          for i in 0 1 2 3 4 5; do
            x="${a[i]:-0}"; y="${b[i]:-0}"; x=$((10#${x:-0})); y=$((10#${y:-0}))
            [ "$x" -gt "$y" ] && return 0
            [ "$x" -lt "$y" ] && return 1
          done
          return 1
        }

        OLD_VER="$(cmcr_agent_version)"
        OLD_OK=0
        if [ -n "$OLD_VER" ] && [ ! -L "$CMCR_AGENT_APP" ] && codesign --verify --strict "$CMCR_AGENT_APP" >/dev/null 2>&1; then
          OLD_OK=1
        fi
        # Never a downgrade: the older copy would replace the newer one (and with an ad-hoc signature take the Screen
        # Recording permission with it) every time an older CMCR Manager or cmcrctl sets the iMac up. Its sessions,
        # folders and LaunchAgent are the newer version's business – nothing is touched.
        if [ $OLD_OK = 1 ] && cmcr_agent_newer "$OLD_VER" "$VER"; then
          echo "CMCR:AGENT newer $OLD_VER"
          echo "⚠︎ Na iMacu jest nowsza usługa podglądu ekranu ($OLD_VER) niż w tej kopii CMCR Manager ($VER) – zostaje bez zmian, razem z uprawnieniem. Zaktualizuj CMCR Manager."
          exit 0
        fi
        APP_OK=0
        if [ $OLD_OK = 1 ] && [ "$OLD_VER" = "$VER" ]; then APP_OK=1; fi
        PL="$CMCR_TMP/agent.plist"
        cmcr_agent_plist > "$PL"
        plutil -lint "$PL" >/dev/null 2>&1 || fail "Nie udało się przygotować LaunchAgenta usługi."
        PLIST_OK=0
        if [ -f "$CMCR_AGENT_PLIST" ] && [ ! -L "$CMCR_AGENT_PLIST" ] && cmp -s "$PL" "$CMCR_AGENT_PLIST"; then PLIST_OK=1; fi
        if [ $APP_OK = 1 ] && [ $PLIST_OK = 1 ]; then STATE=unchanged
        elif [ -z "$OLD_VER" ] && [ ! -e "$CMCR_AGENT_APP" ] && [ ! -L "$CMCR_AGENT_APP" ]; then STATE=installed
        else STATE=updated; fi

        RESET=0
        if [ $STATE != unchanged ]; then
          mkdir -p "$CMCR_AGENT_DIR" && chown root:wheel "$CMCR_AGENT_DIR" && chmod 755 "$CMCR_AGENT_DIR" \
            || fail "Nie można utworzyć ${CMCR_AGENT_DIR#"$R"}."
          if [ $APP_OK = 0 ]; then
            # Staged next to the old copy (same volume, so the swap is a rename), owned by root and without
            # quarantine: launchd refuses a quarantined agent (macOS 27).
            NEXT="$CMCR_AGENT_DIR/.cmcr-agent-new.$$"
            rm -rf "$NEXT"
            ditto "$NEW" "$NEXT" || fail "Nie udało się skopiować usługi do ${CMCR_AGENT_DIR#"$R"}."
            chown -R root:wheel "$NEXT" && chmod -R go-w "$NEXT" || fail "Nie udało się ustawić właściciela usługi."
            xattr -dr com.apple.quarantine "$NEXT" 2>/dev/null
            codesign --verify --strict "$NEXT" >/dev/null 2>&1 || fail "Skopiowana usługa ma nieprawidłowy podpis."
            if [ -d "$CMCR_AGENT_APP" ] && [ "$(cmcr_agent_dr "$CMCR_AGENT_APP")" != "$NEW_DR" ]; then RESET=1; fi
            [ -z "$NEW_DR" ] && [ -e "$CMCR_AGENT_APP" ] && RESET=1
          fi
          STOPPED=1
          while read -r uid user; do
            [ -n "$uid" ] && launchctl bootout "gui/$uid/$CMCR_AGENT_LABEL" >/dev/null 2>&1
          done <<CMCR_AGENT_SESSIONS
        $SESSIONS
        CMCR_AGENT_SESSIONS
          if [ $APP_OK = 0 ]; then
            if [ -e "$CMCR_AGENT_APP" ] || [ -L "$CMCR_AGENT_APP" ]; then
              OLD="$CMCR_AGENT_DIR/.cmcr-agent-old.$$"
              rm -rf "$OLD"
              mv "$CMCR_AGENT_APP" "$OLD" || fail "Nie można odsunąć poprzedniej wersji usługi."
            fi
            mv "$NEXT" "$CMCR_AGENT_APP" || fail "Nie można podmienić usługi."
            NEXT=""
            [ -n "$OLD" ] && rm -rf "$OLD"
            OLD=""
          fi
          if [ $PLIST_OK = 0 ]; then
            D="$(dirname "$CMCR_AGENT_PLIST")"
            mkdir -p "$D" || fail "Nie można utworzyć ${D#"$R"}."
            NEWPL="$CMCR_AGENT_PLIST.cmcr-new.$$"
            if ! { cp "$PL" "$NEWPL" && chown root:wheel "$NEWPL" && chmod 644 "$NEWPL" && mv -f "$NEWPL" "$CMCR_AGENT_PLIST"; }; then
              rm -f "$NEWPL"; fail "Nie można zapisać ${CMCR_AGENT_PLIST#"$R"}."
            fi
          fi
        fi
        # Sockets: run/ is root's (0755) and every agent binds in its own run/<uid> (owner uid, 0700), which root makes
        # before it starts that account's agent – nobody can take another account's socket name. Entries of the older
        # layout (run/<uid>.sock in a run/ everyone could write) go. Screenshots: root only.
        mkdir -p "$CMCR_AGENT_RUN" "$CMCR_AGENT_SHOTS" && chown root:wheel "$CMCR_AGENT_RUN" "$CMCR_AGENT_SHOTS" \
          && chmod 755 "$CMCR_AGENT_RUN" && chmod 700 "$CMCR_AGENT_SHOTS" \
          || fail "Nie można przygotować folderów usługi w ${CMCR_AGENT_DIR#"$R"}."
        rm -rf "$CMCR_AGENT_RUN"/*.sock 2>/dev/null
        if [ $RESET = 1 ]; then
          # The old row would show the switch on while macOS refuses the new copy: cleared, so asking again works.
          tccutil reset ScreenCapture "$CMCR_AGENT_LABEL" >/dev/null 2>&1
        fi

        echo "CMCR:AGENT $STATE $VER"
        case $STATE in
          installed) echo "✔ Zainstalowano usługę podglądu ekranu $VER." ;;
          updated)
            if [ $APP_OK = 1 ]; then echo "✔ Usługa podglądu ekranu $VER: zaktualizowano ustawienia uruchamiania (aplikacja bez zmian)."
            else echo "✔ Zaktualizowano usługę podglądu ekranu ${OLD_VER:-?} → $VER."; fi ;;
          unchanged) echo "✔ Usługa podglądu ekranu $VER jest już zainstalowana – bez zmian (nadane uprawnienie zostaje)." ;;
        esac
        if [ $RESET = 1 ]; then
          echo "⚠︎ Nowa usługa ma inny podpis niż poprzednia (z podpisem ad-hoc tak jest przy każdej wersji): uprawnienie Nagrywanie ekranu trzeba nadać ponownie przy komputerze (Poproś o uprawnienie)."
        fi

        N=0
        while read -r uid user; do
          [ -n "$uid" ] || continue
          N=$((N + 1))
          launchctl enable "gui/$uid/$CMCR_AGENT_LABEL" >/dev/null 2>&1
          FRESH=0
          if ! cmcr_agent_loaded "$uid"; then
            cmcr_agent_rundir "$uid" || echo "⚠︎ $user: nie można przygotować folderu ${CMCR_AGENT_RUN#"$R"}/$uid."
            launchctl bootstrap "gui/$uid" "$CMCR_AGENT_PLIST" 2>"$CMCR_TMP/bootstrap.err" \
              || echo "⚠︎ $user: launchctl bootstrap: $(grep -v '^ *$' "$CMCR_TMP/bootstrap.err" | head -n 1)"
            FRESH=1
          fi
          # Asked until it answers (a starting agent needs a moment), then once more only if it stays silent (hung, or
          # stopped by the student: restarted) or – in a process older than this run – says it has no permission (a
          # fresh process reads the permission anew, so one granted at the computer meanwhile counts).
          END=$((SECONDS + 10))
          until cmcr_agent_ping "$uid" || [ "$CMCR_AGENT_RC" != \#(ScreenAgentInfo.ClientCode.unreachable) ] || [ $SECONDS -ge $END ]; do
            sleep 0.3
          done
          if [ "$CMCR_AGENT_RC" = \#(ScreenAgentInfo.ClientCode.unreachable) ]; then
            cmcr_agent_revive "$uid" 10
            cmcr_agent_ping "$uid"
            FRESH=1
          fi
          [ $FRESH = 1 ] || cmcr_agent_fresh "$uid"
          LINE="$CMCR_AGENT_LINE"
          [ -n "$LINE" ] || LINE="ERR failed brak odpowiedzi"
          echo "CMCR:AGENT-SESSION $user $uid $LINE"
          case "$LINE" in
            AGENT\ *perm=granted*) echo "✔ $user: usługa działa i ma uprawnienie Nagrywanie ekranu." ;;
            AGENT\ *) echo "☐ $user: usługa działa, ale nie ma jeszcze uprawnienia Nagrywanie ekranu – nadaje się je przy komputerze (Poproś o uprawnienie)." ;;
            *) echo "⚠︎ $user: usługa nie odpowiada (${LINE#ERR })." ;;
          esac
        done <<CMCR_AGENT_SESSIONS
        $SESSIONS
        CMCR_AGENT_SESSIONS
        [ $N -gt 0 ] || echo "– Nikt nie jest zalogowany – usługa uruchomi się sama przy następnym logowaniu."
        exit 0
        """#, asRoot: true)
    }

    /// Removes the agent: stopped in every GUI session, its LaunchAgent, app, sockets, screenshots and its Screen
    /// Recording entry. Prints `CMCR:AGENT removed <version>` (or `CMCR:AGENT absent -`).
    static func removeScreenAgent() -> RemoteScript {
        RemoteScript(screenAgentShell + "\n" + #"""
        OLD_VER="$(cmcr_agent_version)"
        PRESENT=0
        for p in "$CMCR_AGENT_APP" "$CMCR_AGENT_PLIST" "$CMCR_AGENT_RUN" "$CMCR_AGENT_SHOTS"; do
          { [ -e "$p" ] || [ -L "$p" ]; } && PRESENT=1
        done
        while read -r uid user; do
          [ -n "$uid" ] && launchctl bootout "gui/$uid/$CMCR_AGENT_LABEL" >/dev/null 2>&1
        done <<CMCR_AGENT_SESSIONS
        $(cmcr_gui_sessions)
        CMCR_AGENT_SESSIONS
        RC=0
        rm -f "$CMCR_AGENT_PLIST" || RC=1
        rm -rf "$CMCR_AGENT_APP" "$CMCR_AGENT_RUN" "$CMCR_AGENT_SHOTS" || RC=1
        rm -rf "$CMCR_AGENT_DIR"/.cmcr-agent-new.* "$CMCR_AGENT_DIR"/.cmcr-agent-old.* 2>/dev/null
        rmdir "$CMCR_AGENT_DIR" 2>/dev/null
        tccutil reset ScreenCapture "$CMCR_AGENT_LABEL" >/dev/null 2>&1
        if [ $RC != 0 ]; then echo "✘ Nie udało się usunąć wszystkich plików usługi podglądu." >&2; exit 1; fi
        if [ $PRESENT = 1 ]; then
          echo "CMCR:AGENT removed ${OLD_VER:--}"
          echo "✔ Usunięto usługę podglądu ekranu${OLD_VER:+ $OLD_VER} (z uprawnieniem Nagrywanie ekranu)."
        else
          echo "CMCR:AGENT absent -"
          echo "– Usługi podglądu ekranu nie było na tym iMacu."
        fi
        """#, asRoot: true)
    }

    /// Asks the agent in the session of the user at the screen to request the Screen Recording permission: macOS
    /// shows its dialog there and lists the agent in System Settings. Exit 3 when nobody is logged in, 9 when the
    /// agent is missing or does not answer. Prints `CMCR:AGENT-PERMISSION <granted|denied>`.
    static func requestScreenAgentPermission() -> RemoteScript {
        RemoteScript(screenAgentShell + "\n" + #"""
        if [ -z "$CONSOLE_UID" ]; then
          echo "Nikt nie jest zalogowany przy komputerze. Okno z prośbą o uprawnienie macOS pokazuje w sesji zalogowanego użytkownika – zaloguj się przy iMacu (na dowolne konto) i spróbuj ponownie." >&2
          exit \#(ScriptCode.noConsoleUser)
        fi
        if [ ! -x "$CMCR_AGENT_EXE" ]; then
          echo "Na tym iMacu nie ma usługi podglądu ekranu – najpierw ją zainstaluj (Konfiguracja › Przygotowanie iMaców)." >&2
          exit \#(ScriptCode.agentUnavailable)
        fi
        ask() { cmcr_agent_client "$CONSOLE_UID" request-permission </dev/null >"$CMCR_TMP/perm.out" 2>"$CMCR_TMP/perm.err"; }
        # An agent that has run without the permission for a while may not see one granted since: started anew first.
        cmcr_agent_ping "$CONSOLE_UID" && cmcr_agent_fresh "$CONSOLE_UID"
        ask; RC=$?
        if [ $RC = \#(ScreenAgentInfo.ClientCode.unreachable) ]; then cmcr_agent_revive "$CONSOLE_UID" 5; ask; RC=$?; fi
        WHY="$(sed -n 's/^ERR [^ ]* *//p' "$CMCR_TMP/perm.out" | head -n 1)"
        [ -n "$WHY" ] || WHY="$(grep -v '^ *$' "$CMCR_TMP/perm.err" 2>/dev/null | head -n 1)"
        case $RC in
          0) ;;
          \#(ScreenAgentInfo.ClientCode.unreachable))
            echo "Usługa podglądu nie odpowiada w sesji $CONSOLE_USER, także po ponownym uruchomieniu${WHY:+ ($WHY)}. Zainstaluj ją ponownie." >&2
            exit \#(ScriptCode.agentUnavailable) ;;
          \#(ScreenAgentInfo.ClientCode.untrusted))
            echo "Na gnieździe usługi podglądu odpowiada inny program niż zainstalowana usługa${WHY:+ ($WHY)} – nie poproszono o uprawnienie. Zainstaluj usługę ponownie." >&2
            exit \#(ScriptCode.agentUnavailable) ;;
          *) echo "Usługa podglądu nie poprosiła o uprawnienie${WHY:+: $WHY} (kod $RC)." >&2; exit 1 ;;
        esac
        STATE="$(sed -n 's/^PERMISSION \([a-z]*\).*/\1/p' "$CMCR_TMP/perm.out" | head -n 1)"
        case "$STATE" in
          granted)
            echo "CMCR:AGENT-PERMISSION granted"
            echo "✔ Usługa podglądu ma już uprawnienie Nagrywanie ekranu na tym iMacu (dla wszystkich kont)." ;;
          denied)
            echo "CMCR:AGENT-PERMISSION denied"
            echo "☐ Na ekranie iMaca (konto $CONSOLE_USER) macOS pokazał prośbę o uprawnienie. Przy komputerze: „Otwórz Ustawienia systemowe” › Prywatność i ochrona › Nagrywanie ekranu i dźwięku systemowego › włącz „\#(ScreenAgentInfo.displayName)” (potrzebne hasło administratora). Jeśli okno się nie pojawiło, włącz usługę na tej liście ręcznie. Uprawnienie wystarczy nadać raz – działa dla wszystkich kont na tym iMacu." ;;
          *) echo "Usługa podglądu nie potwierdziła prośby o uprawnienie." >&2; exit 1 ;;
        esac
        """#, asRoot: true)
    }

    /// What `Operations.screenAgentStatus` reports (key=value lines for `ScreenAgentStatus.parse`): `console`,
    /// `agent_installed`, `agent_version` and – from the console user's session, as root unless the admin is the one
    /// logged in – `agent_loaded`, `agent_ping`, `agent_ping_rc`. Without sudo only the first ones are printed.
    static func screenAgentStatus() -> RemoteScript {
        RemoteScript(screenAgentShell + "\n" + #"""
        printf 'console=%s\n' "$CONSOLE_USER"
        V="$(cmcr_agent_version)"
        if [ -n "$V" ]; then printf 'agent_installed=1\nagent_version=%s\n' "$V"; else echo "agent_installed=0"; fi
        [ -n "$CONSOLE_UID" ] || exit 0
        if [ "$(id -u)" = "$CONSOLE_UID" ] || [ "$(id -u)" -eq 0 ]; then cmcr_agent_probe "$CONSOLE_UID"; exit 0; fi
        { \#(screenAgentShellExport)
          echo 'cmcr_agent_probe "$1"'; } > "$CMCR_TMP/agent-status.sh"
        asroot /bin/bash --noprofile --norc "$CMCR_TMP/agent-status.sh" "$CONSOLE_UID"
        """#)
    }
}
