import Foundation

/// Remote scripts for macOS software updates (`softwareupdate`).
///
/// An install or download runs detached from the SSH session (`cmcr_su_runner`): its output goes only to a log in
/// `/Library/Application Support/CMCR/softwareupdate` (a 0755 folder of root), with the run's state beside it. The
/// session merely follows that log (`cmcr_su_follow`). A lost connection – keepalive on a network saturated by a dozen
/// downloads, Wi‑Fi, the admin's Mac asleep, the iMac restarting to install – therefore neither stops nor blocks
/// softwareupdate, and `followUpdate` picks the same run up again from a new session (`Operations.installUpdates`).
///
/// What macOS requires, as far as Apple documents it (Platform Deployment guide): on a Mac with Apple silicon only a
/// volume owner (an account with a Secure Token) can authorise installing a macOS update – from the command line with
/// `--user`/`--stdinpass`, otherwise in System Settings or through MDM/DDM with a bootstrap token. A downloaded or
/// prepared update is installed only by softwareupdate's own restart (`--restart`): an ordinary restart boots the old
/// system. With a user logged in, softwareupdate queues the installation for after a logout and then restarts – an app
/// that refuses to quit (unsaved work) holds the restart back.
///
/// `$CMCR_SU_STATE_DIR` and `$CMCR_SU_RESTART_WAIT` exist for the tests only: real sudo resets the environment.
public extension Scripts {

    static func listUpdates() -> RemoteScript {
        RemoteScript("softwareupdate --list 2>&1")
    }

    /// Exit code of a run whose update installed but whose restart did not come (see `cmcr_su_await_restart`).
    static let updateNotRestartedCode: Int32 = 6
    /// Exit code of an install refused because a run that does less (a download, an install without restart) is going on.
    static let updateBusyCode: Int32 = 7
    /// The line (`CMCR:SU-RUN <id>`) by which the install and follow scripts name the run they follow – the new one, or
    /// the one already going that they joined. `Operations` removes it from the output.
    static let updateRunMarker = "CMCR:SU-RUN "

    /// The state of update runs on the Mac, shared by the install, follow and stop scripts.
    ///
    /// Files in `$CMCR_SU_DIR`: `state` (`key=value` lines: run, boot, started, mode, restart, from, phase, rc,
    /// needs_restart, os_update, finished and one `label=` per update), `runner` (`run pid boot` of the detached runner) and
    /// `softwareupdate.log` (the run's whole output; the previous run's is kept as `softwareupdate.log.1`).
    static let updateRunFunctions = #"""
    CMCR_SU_DIR="${CMCR_SU_STATE_DIR:-/Library/Application Support/CMCR/softwareupdate}"
    CMCR_SU_STATE="$CMCR_SU_DIR/state"; CMCR_SU_PIDF="$CMCR_SU_DIR/runner"; CMCR_SU_LOG="$CMCR_SU_DIR/softwareupdate.log"
    CMCR_SU_OFF=0
    # The run's state and log are trusted, so their folder must be root's own real folder (only root writes there).
    cmcr_su_dir() {
      if [ -L "$CMCR_SU_DIR" ] || { [ -e "$CMCR_SU_DIR" ] && { [ ! -d "$CMCR_SU_DIR" ] || [ ! -O "$CMCR_SU_DIR" ]; }; }; then
        echo "✘ $CMCR_SU_DIR nie jest zwykłym folderem konta root – usuń go i spróbuj ponownie." >&2; return 1
      fi
      mkdir -p "$CMCR_SU_DIR" 2>/dev/null && chmod 755 "$CMCR_SU_DIR" 2>/dev/null
      if [ ! -d "$CMCR_SU_DIR" ] || [ -L "$CMCR_SU_DIR" ] || [ ! -O "$CMCR_SU_DIR" ]; then
        echo "✘ Nie udało się utworzyć folderu $CMCR_SU_DIR." >&2; return 1
      fi
    }
    cmcr_su_get() { sed -n "s/^$1=//p" "$CMCR_SU_STATE" 2>/dev/null | head -n 1; }
    # cmcr_su_put KEY=VALUE… – sets those keys of the state (all lines of a key are replaced; the file is renamed into place).
    cmcr_su_put() {
      local kv keys=""
      for kv in "$@"; do keys="$keys${keys:+|}${kv%%=*}"; done
      { grep -Ev "^($keys)=" "$CMCR_SU_STATE" 2>/dev/null; printf '%s\n' "$@"; } > "$CMCR_SU_STATE.new" \
        && mv -f "$CMCR_SU_STATE.new" "$CMCR_SU_STATE"
    }
    cmcr_boot() { sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p'; }
    cmcr_os() { printf '%s (%s)\n' "$(sw_vers -productVersion 2>/dev/null)" "$(sw_vers -buildVersion 2>/dev/null)"; }
    cmcr_su_when() { date -r "${1:-0}" '+%d.%m %H:%M' 2>/dev/null; }
    # The pid of run $1's runner while it is running in this boot of the Mac.
    cmcr_su_runner_pid() {
      local r p b
      [ -f "$CMCR_SU_PIDF" ] || return 1
      read -r r p b < "$CMCR_SU_PIDF" || return 1
      [ -n "$1" ] && [ "$r" = "$1" ] && [ "$b" = "$(cmcr_boot)" ] || return 1
      case "$p" in ''|*[!0-9]*) return 1 ;; esac
      case "$(ps -o comm= -p "$p" 2>/dev/null)" in *bash*) printf '%s\n' "$p" ;; *) return 1 ;; esac
    }
    cmcr_su_active() {
      case "$(cmcr_su_get phase)" in ''|done|cancelled) return 1 ;; esac
      cmcr_su_runner_pid "$(cmcr_su_get run)" >/dev/null
    }
    # The run's updates: "→ label" for an install (the app takes them off its list), "↓ label" for a download.
    cmcr_su_labels() {
      if [ "$(cmcr_su_get mode)" = download ]; then sed -n 's/^label=/↓ /p' "$CMCR_SU_STATE" 2>/dev/null
      else sed -n 's/^label=/→ /p' "$CMCR_SU_STATE" 2>/dev/null; fi
    }
    # What a run does: 0 download, 1 install, 2 install with restart (cmcr_su_level MODE RESTART).
    cmcr_su_level() { if [ "$1" = download ]; then echo 0; elif [ "$2" = 1 ]; then echo 2; else echo 1; fi; }
    # Stops run $1 (softwareupdate and the session that started it: one process group) and marks it cancelled.
    # Returns 0 when stopped, 1 when something is still running, 2 when it was not running.
    cmcr_su_stop() {
      local p g my i=0
      p="$(cmcr_su_runner_pid "$1")" || return 2
      g="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')"; my="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
      case "$g" in ''|0|1|*[!0-9]*|"$my") g="" ;; esac
      if [ -n "$g" ]; then kill -TERM -- "-$g" 2>/dev/null; else kill -TERM "$p" 2>/dev/null; fi
      while cmcr_su_runner_pid "$1" >/dev/null && [ $i -lt 8 ]; do sleep 0.2; i=$((i + 1)); done
      if cmcr_su_runner_pid "$1" >/dev/null; then
        if [ -n "$g" ]; then kill -KILL -- "-$g" 2>/dev/null; else kill -KILL "$p" 2>/dev/null; fi
        sleep 0.3
      fi
      cmcr_su_runner_pid "$1" >/dev/null && return 1
      [ "$(cmcr_su_get run)" = "$1" ] && cmcr_su_put phase=cancelled "finished=$(date +%s)"
      return 0
    }
    # Accounts with a GUI session (at the screen or in the background), comma-separated.
    cmcr_su_logged_in() { cmcr_gui_sessions | awk 'NF {print $2}' | paste -sd, - | sed 's/,/, /g'; }
    cmcr_su_size() {
      local s; s="$(stat -f %z "$CMCR_SU_LOG" 2>/dev/null)"
      case "$s" in ''|*[!0-9]*) echo 0 ;; *) echo "$s" ;; esac
    }
    # What the log got since $CMCR_SU_OFF, as written (progress lines included).
    cmcr_su_print_new() {
      local size; size="$(cmcr_su_size)"
      [ "$size" -gt "$CMCR_SU_OFF" ] || return 0
      tail -c +"$((CMCR_SU_OFF + 1))" "$CMCR_SU_LOG" 2>/dev/null | head -c "$((size - CMCR_SU_OFF))"
      CMCR_SU_OFF=$size
    }
    # cmcr_su_replay [N] – the log so far (its last N lines), each run of progress lines ("Downloading: 41.15%") as its last
    # one; without the "→ …" and "↓ …" lines, which cmcr_su_labels shows.
    cmcr_su_replay() {
      local size; size="$(cmcr_su_size)"
      head -c "$size" "$CMCR_SU_LOG" 2>/dev/null | tr '\r' '\n' \
        | awk 'NF == 0 || /^(→|↓) / {next} /^[[:space:]]*[A-Za-z][A-Za-z ]*: *[0-9.]+%[[:space:]]*$/ {p = $0; next}
               {if (p != "") print p; p = ""; print} END {if (p != "") print p}' \
        | if [ -n "${1:-}" ]; then tail -n "$1"; else cat; fi
      CMCR_SU_OFF=$size
    }
    # Waits (30 s at most) until the state is run $1's: its launcher writes it before anything else.
    cmcr_su_wait_run() {
      local i=0
      while [ "$(cmcr_su_get run)" != "$1" ]; do
        i=$((i + 1))
        if [ $i -gt 30 ]; then
          echo "✘ Nie ma na komputerze śladu tej instalacji – nie wystartowała albo zastąpiła ją późniejsza." >&2; return 1
        fi
        sleep 1
      done
    }
    # cmcr_su_follow RUN – streams run RUN's log from $CMCR_SU_OFF on until the run ends, then reports how it ended.
    cmcr_su_follow() {
      cmcr_su_wait_run "$1" || return 1
      while :; do
        case "$(cmcr_su_get phase)" in done|cancelled) cmcr_su_print_new; break ;; esac
        if ! cmcr_su_runner_pid "$1" >/dev/null; then sleep 1; cmcr_su_print_new; break; fi
        cmcr_su_print_new
        sleep 2
      done
      cmcr_su_outcome
    }
    # How the run in the state ended; returns its code. An install that needs a restart ends with the Mac restarting
    # (this session ends with it): back up, the system version tells whether the update was installed.
    cmcr_su_outcome() {
      local phase rc mode needs from now
      phase="$(cmcr_su_get phase)"; rc="$(cmcr_su_get rc)"; mode="$(cmcr_su_get mode)"
      needs="$(cmcr_su_get needs_restart)"; from="$(cmcr_su_get from)"
      if [ "$(cmcr_su_get boot)" != "$(cmcr_boot)" ]; then
        now="$(cmcr_os)"
        if [ "$mode" = install ] && [ "$needs" = 1 ] && [ "$(cmcr_su_get os_update)" != 0 ]; then
          if [ "$now" != "$from" ]; then
            echo "✔ Komputer uruchomił się ponownie z nowym systemem: macOS $now; wcześniej macOS $from."; return 0
          fi
          echo "✘ Komputer uruchomił się ponownie, ale system się nie zmienił (macOS $now) – aktualizacja nie została zainstalowana. Zwykły restart nie instaluje pobranej aktualizacji: uruchom „Zainstaluj aktualizacje” z restartem jeszcze raz." >&2
          return 1
        fi
        if [ "$phase" != done ]; then
          echo "✘ Komputer uruchomił się ponownie ($(cmcr_su_when "$(cmcr_boot)")) przed końcem instalacji – sprawdź Historię instalacji albo uruchom instalację jeszcze raz." >&2; return 1
        fi
        if [ "$mode" = install ] && [ "$needs" = 1 ] && [ "$rc" = 0 ]; then
          echo "✔ Zainstalowano; komputer uruchomił się ponownie ($(cmcr_su_when "$(cmcr_boot)"))."; return 0
        fi
      fi
      case "$phase" in
        done) ;;
        cancelled) echo "✘ Instalację przerwano." >&2; return 130 ;;
        *) echo "✘ Instalacja została przerwana na komputerze – softwareupdate zakończył się bez wyniku (zatrzymany proces)." >&2; return 1 ;;
      esac
      case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
      [ "$rc" = 0 ] || return "$rc"
      if [ "$mode" = install ] && [ "$(cmcr_su_get restart)" = 1 ] && [ "$needs" = 1 ]; then
        cmcr_su_await_restart; return $?
      fi
      return 0
    }
    # softwareupdate ended without an error and has queued the installation: it installs after a logout and restarts the
    # Mac. Waits for that restart (which ends this session); when it does not come, says what holds it back.
    # Only what is left of the wait counts: followed again later, a run that finished long ago is reported at once.
    cmcr_su_await_restart() {
      local wait="${CMCR_SU_RESTART_WAIT:-300}" fin left who
      fin="$(cmcr_su_get finished)"; case "$fin" in ''|*[!0-9]*) fin="$(date +%s)" ;; esac
      left=$(( wait - ($(date +%s) - fin) ))
      if [ "$left" -gt 0 ]; then
        echo "… Instalacja zlecona – czekam, aż komputer uruchomi się ponownie (do $(( (left + 59) / 60 )) min)."
        while [ "$left" -gt 0 ]; do sleep 1; left=$((left - 1)); done
      fi
      who="$(cmcr_su_logged_in)"
      if [ -n "$who" ]; then
        echo "✘ Aktualizacja czeka na wylogowanie: komputer nie uruchomił się ponownie od $(cmcr_su_when "$fin"), a zalogowany jest: $who. macOS instaluje ją dopiero po wylogowaniu, które najczęściej wstrzymuje aplikacja z niezapisaną pracą. Wyloguj użytkownika (Sesja i zasilanie › Wyloguj natychmiast…) – macOS powinien wtedy sam zainstalować aktualizację i uruchomić komputer ponownie; jeśli nie, uruchom instalację jeszcze raz." >&2
      else
        echo "✘ softwareupdate zakończył pracę bez błędu, ale komputer nie uruchomił się ponownie od $(cmcr_su_when "$fin"), choć nikt nie jest zalogowany. Zwykły restart nie zainstaluje tej aktualizacji – uruchom „Zainstaluj aktualizacje” z restartem jeszcze raz; jeśli to się powtarza, zainstaluj ją przy komputerze (Ustawienia systemowe › Ogólne › Uaktualnienia, hasło właściciela woluminu) i sprawdź /var/log/install.log." >&2
      fi
      return \#(updateNotRestartedCode)
    }
    """#

    /// The part of an install that runs detached (`cmcr_su_install`, in a subshell of `cmcr_su_runner`): picks the
    /// labels offered by `softwareupdate --list`, checks what Apple silicon requires and runs softwareupdate. Upgrades to a
    /// new major macOS are skipped unless allowed (`--all` would install them too), and of several macOS versions only
    /// the newest is installed – softwareupdate would otherwise download and install the intermediate ones first. With
    /// `restart`, when a selected update needs one (`Action: restart`), the FileVault unlock is armed first
    /// (`cmcr_arm_authrestart`), so the Mac does not stop at the unlock screen after updating.
    static let updateInstallFunctions = #"""
    # cmcr_ver_newer A B – whether version A is newer than B (numbers compared part by part, "26.1 (a)" = 26.1).
    cmcr_ver_newer() {
      awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, /[^0-9]+/); m = split(b, y, /[^0-9]+/)
        for (i = 1; i <= (n > m ? n : m); i++) { p = x[i] + 0; q = y[i] + 0; if (p != q) exit !(p > q) }
        exit 1 }'
    }
    # "Yes" or "No": whether the admin account is a volume owner of the system volume (empty when it cannot tell).
    # listUsers names only the volume's cryptographic users: an account without a Secure Token is not listed at all.
    cmcr_su_volume_owner() {
      local guid users
      guid="$(dscl . -read "/Users/$CMCR_ADMIN_USER" GeneratedUID 2>/dev/null | awk '{print $2}')"
      [ -n "$guid" ] || return 0
      users="$(diskutil apfs listUsers / 2>/dev/null)" || return 0
      printf '%s\n' "$users" | grep -q "^+-- " || return 0
      if ! printf '%s\n' "$users" | grep -qiF -- "$guid"; then echo No; return 0; fi
      printf '%s\n' "$users" | awk -v g="$(printf '%s' "$guid" | tr '[:lower:]' '[:upper:]')" \
        'index(toupper($0), g) {f = 1; next} /^[|]? *\+--/ {f = 0} f && /Volume Owner:/ {print $NF; exit}'
    }
    cmcr_su_token_hint() {
      echo "  Nadaj kontu Secure Token przy komputerze: sudo sysadminctl -secureTokenOn $CMCR_ADMIN_USER -password - -adminUser KONTO_Z_TOKENEM -adminPassword - (sprawdzenie: sysadminctl -secureTokenStatus $CMCR_ADMIN_USER)."
    }
    # Why softwareupdate failed and what to do, from the end of its output (and the system log). The details come first
    # and the ✘ line last: the job list shows a job's last line.
    cmcr_su_explain() {
      local out why who
      out="$(tail -n 80 "$CMCR_SU_LOG" 2>/dev/null)"
      who="$(cmcr_su_logged_in)"
      case "$out" in
        *"Failed to authenticate"*|*"Failed to authorize"*|*"uthentication failed"*|*"failed to get uid for username"*)
          if [ "$(cmcr_su_volume_owner)" = No ]; then
            cmcr_su_token_hint
            echo "✘ macOS odmówił zatwierdzenia instalacji: konto $CMCR_ADMIN_USER nie jest właścicielem woluminu (brak Secure Token), a na Macu z procesorem Apple tylko właściciel woluminu może zatwierdzić instalację macOS – nadaj mu Secure Token (polecenie powyżej)."
          else
            echo "✘ macOS odmówił zatwierdzenia instalacji kontem $CMCR_ADMIN_USER (--user/--stdinpass) – sprawdź, czy konto ma Secure Token (sysadminctl -secureTokenStatus $CMCR_ADMIN_USER) i czy zapisane hasło administratora jest aktualne (Konfiguracja › Dostęp i hasła)."
          fi ;;
        *"Failed to queue update and restart"*)
          why="$(log show --last 30m --info --style compact --predicate 'eventMessage CONTAINS[c] "post-logout" OR eventMessage CONTAINS[c] "queue update"' 2>/dev/null \
                 | grep -iE 'fail|error' | tail -n 3 | cut -c1-400)"
          if [ -n "$why" ]; then echo "  Przyczyna według dziennika systemu:"; printf '%s\n' "$why" | sed 's/^/    /'; fi
          echo "  Pobrana aktualizacja zostaje na komputerze. Jeśli błąd się powtarza, zainstaluj ją przy komputerze: Ustawienia systemowe › Ogólne › Uaktualnienia (hasło właściciela woluminu); szczegóły: /var/log/install.log."
          if [ -n "$who" ]; then
            echo "✘ Aktualizacja jest pobrana, ale macOS nie przyjął zlecenia instalacji z ponownym uruchomieniem („Failed to queue update and restart”). Zalogowany jest: $who – macOS instaluje aktualizację po wylogowaniu: wyloguj użytkownika (Sesja i zasilanie › Wyloguj natychmiast…) i uruchom instalację ponownie."
          else
            echo "✘ Aktualizacja jest pobrana, ale macOS nie przyjął zlecenia instalacji z ponownym uruchomieniem („Failed to queue update and restart”) – uruchom komputer ponownie (Sesja i zasilanie) i powtórz instalację."
          fi ;;
        *"Failed to quit all apps"*|*"quit any relevant apps"*)
          echo "✘ macOS nie zdołał zamknąć aplikacji zalogowanego użytkownika${who:+ ($who)} przed instalacją – zwykle z powodu niezapisanej pracy. Wyloguj go (Sesja i zasilanie › Wyloguj natychmiast…) i uruchom instalację ponownie." ;;
        *"ot enough free"*|*"nsufficient"*|*"not enough space"*|*"ot enough disk"*)
          echo "✘ Za mało wolnego miejsca na dysku na instalację tej aktualizacji – zwolnij miejsce (duże aktualizacje macOS potrzebują kilkudziesięciu GB) i spróbuj ponownie." ;;
        *"Failed to download"*|*"rror downloading"*|*"internet connection"*|*"etwork"*|*"timed out"*)
          echo "✘ Nie udało się pobrać aktualizacji z serwerów Apple – sprawdź połączenie komputera z internetem i spróbuj ponownie. Przy wielu komputerach naraz pomaga Buforowanie zawartości (Content Caching) na jednym z Maców w sieci." ;;
        *) echo "✘ softwareupdate zakończył się kodem $1 – szczegóły powyżej, dziennik instalacji: /var/log/install.log." ;;
      esac
    }
    cmcr_su_install() {
      local CUR LIST_RC LABEL TITLE VER OK line i BEST AUTH ARMED RC
      local -a LABELS OSVER RESTARTS KEEP ARGS KV
      CUR="$(sw_vers -productVersion 2>/dev/null)"; CUR="${CUR%%.*}"
      echo "→ softwareupdate --list"
      softwareupdate --list > "$CMCR_SU_DIR/list" 2>&1; LIST_RC=$?
      LABELS=(); OSVER=(); RESTARTS=(); SKIPPED=""; LABEL=""; LISTED=0
      while IFS= read -r line; do
        case "$line" in
          "* Label: "*) LABEL="${line#\* Label: }"; LISTED=1 ;;
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
            if [ $OK = 1 ]; then
              LABELS+=("$LABEL")
              case "$TITLE" in macOS*) OSVER+=("${VER:-0}") ;; *) OSVER+=("") ;; esac
              case "$line" in *"Action: restart"*) RESTARTS+=(1) ;; *) RESTARTS+=(0) ;; esac
            fi
            LABEL="" ;;
        esac
      done < "$CMCR_SU_DIR/list"
      if [ -n "$SKIPPED" ]; then
        echo "↷ Pominięto przejście na nową wersję systemu: $SKIPPED (wymaga zaznaczenia „Pozwól na nową wersję macOS”)."
      fi
      # Of several macOS versions only the newest: it contains the earlier ones, which would cost a download and a
      # restart each.
      BEST=-1; i=0
      while [ $i -lt ${#LABELS[@]} ]; do
        if [ -n "${OSVER[$i]}" ] && { [ $BEST -lt 0 ] || cmcr_ver_newer "${OSVER[$i]}" "${OSVER[$BEST]}"; }; then BEST=$i; fi
        i=$((i + 1))
      done
      KEEP=(); NEEDS_RESTART=0; i=0
      while [ $i -lt ${#LABELS[@]} ]; do
        if [ -n "${OSVER[$i]}" ] && [ $i -ne $BEST ]; then
          echo "↷ Pominięto wersję pośrednią: ${LABELS[$i]} – od razu instaluję najnowszą: ${LABELS[$BEST]}."
        else
          KEEP+=("${LABELS[$i]}")
          [ "${RESTARTS[$i]}" = 1 ] && NEEDS_RESTART=1
        fi
        i=$((i + 1))
      done
      if [ ${#KEEP[@]} -eq 0 ]; then
        # Nothing to install only when the list says so (or every listed update was skipped above); an empty answer
        # is a failed list (no network, Apple's server unreachable), not "no updates".
        if [ $LISTED = 1 ] || { [ $LIST_RC = 0 ] && grep -q "No new software available" "$CMCR_SU_DIR/list"; }; then
          echo "✔ Brak aktualizacji do zainstalowania."; exit 0
        fi
        echo "✘ Nie udało się pobrać listy aktualizacji (softwareupdate --list, kod $LIST_RC) – nic nie zainstalowano:"
        grep -v '^ *$' "$CMCR_SU_DIR/list" | tail -n 20 | sed 's/^/  /'
        exit 1
      fi
      if [ $DL = 1 ]; then ARGS=(--download); else ARGS=(--install); fi
      ARGS+=("${KEEP[@]}")
      if [ $DL = 0 ]; then ARGS+=(--agree-to-license); [ $RESTART = 1 ] && ARGS+=(--restart); fi
      if [ $DL = 1 ]; then printf '↓ %s\n' "${KEEP[@]}"; else printf '→ %s\n' "${KEEP[@]}"; fi
      KV=(); for LABEL in "${KEEP[@]}"; do KV+=("label=$LABEL"); done
      if [ $BEST -ge 0 ]; then KV+=(os_update=1); else KV+=(os_update=0); fi
      cmcr_su_put phase=install "needs_restart=$NEEDS_RESTART" "${KV[@]}"
      # Apple silicon: only a volume owner (Secure Token) can authorise installing macOS – checked before a download of
      # several GB that would end in a refusal.
      AUTH=0
      if [ "$(uname -m)" = arm64 ]; then
        if [ -n "$CMCR_PW" ]; then
          AUTH=1
          if [ "$(cmcr_su_volume_owner)" = "No" ]; then
            if [ $DL = 0 ] && [ $NEEDS_RESTART = 1 ]; then
              cmcr_su_token_hint
              echo "✘ Konto $CMCR_ADMIN_USER nie jest właścicielem woluminu (brak Secure Token), a na Macu z procesorem Apple tylko właściciel woluminu może zatwierdzić instalację macOS – softwareupdate pobrałby ją i odmówił instalacji. Nic nie pobrano; nadaj kontu Secure Token (polecenie powyżej)."
              exit 1
            fi
            echo "⚠︎ Konto $CMCR_ADMIN_USER nie jest właścicielem woluminu (brak Secure Token) – aktualizacji macOS nie da się nim zainstalować."
          fi
        elif [ $DL = 0 ] && [ $NEEDS_RESTART = 1 ]; then
          echo "✘ Na Macu z procesorem Apple instalację macOS musi zatwierdzić właściciel woluminu hasłem, a hasło administratora nie jest zapisane (Konfiguracja › Dostęp i hasła). Nic nie pobrano."
          exit 1
        fi
      fi
      if [ $DL = 0 ] && [ $NEEDS_RESTART = 1 ] && [ $RESTART = 0 ]; then
        echo "ℹ︎ Bez „Uruchom ponownie” aktualizacja macOS zostanie tylko pobrana i przygotowana – zwykły restart jej nie zainstaluje, dopiero instalacja z restartem."
      fi
      # Armed only when a restart really follows: fdesetup cannot disarm, the key would wait for any later restart.
      ARMED=0
      if [ $DL = 0 ] && [ $RESTART = 1 ] && [ $NEEDS_RESTART = 1 ]; then
        cmcr_arm_authrestart "przy restarcie po aktualizacji" && [ "$(fdesetup isactive 2>/dev/null)" = "true" ] && ARMED=1
        who="$(cmcr_su_logged_in)"
        if [ -n "$who" ]; then
          echo "⚠︎ Zalogowany jest: $who – macOS zainstaluje aktualizację po wylogowaniu (zamknie aplikacje) i uruchomi komputer ponownie; aplikacja z niezapisaną pracą może to wstrzymać."
        fi
      fi
      i="$(pgrep -x softwareupdate 2>/dev/null | paste -sd, -)"
      [ -z "$i" ] || echo "⚠︎ Na komputerze działa już inny proces softwareupdate (PID $i) – instalacja może się nie udać."
      if [ $AUTH = 1 ]; then
        printf '%s\n' "$CMCR_PW" | softwareupdate "${ARGS[@]}" --user "$CMCR_ADMIN_USER" --stdinpass 2>&1
      else
        softwareupdate "${ARGS[@]}" 2>&1
      fi
      RC=$?
      if [ $RC -ne 0 ]; then
        if [ $ARMED = 1 ]; then
          echo "⚠︎ Aktualizacja się nie powiodła, więc restartu nie było – jednorazowe odblokowanie FileVault zostaje uzbrojone do najbliższego restartu (fdesetup nie pozwala go cofnąć)."
        fi
        cmcr_su_explain "$RC"
      elif [ $DL = 1 ]; then
        echo "✔ Pobrano – zainstalujesz przyciskiem „Zainstaluj aktualizacje”."
      fi
      exit $RC
    }
    # The detached run: its output goes only to the log, its result into the state.
    cmcr_su_runner() {
      local rc
      cd / || :
      ( cmcr_su_install ); rc=$?
      cmcr_su_put phase=done "rc=$rc" "finished=$(date +%s)"
    }
    """#

    /// Installs (or downloads) the updates offered by `softwareupdate --list` as a detached run on the Mac (see the
    /// type's notes and `updateInstallFunctions`) and follows it until it ends. `runID` names the run, so that
    /// `followUpdate` finds this run again after a lost connection. When a run started earlier is still going, it is
    /// followed instead of starting a second one.
    static func installUpdates(restart: Bool, recommendedOnly: Bool, downloadOnly: Bool,
                               allowMajorUpgrade: Bool = false, runID: String = RemoteJobs.newID()) -> RemoteScript {
        let run = RemoteJobs.isValidID(runID) ? runID : RemoteJobs.newID()
        return RemoteScript(#"""
        \#(fileVaultArmFunction)
        \#(updateRunFunctions)
        \#(updateInstallFunctions)
        RESTART=\#(restart ? 1 : 0); REC=\#(recommendedOnly ? 1 : 0); DL=\#(downloadOnly ? 1 : 0); MAJOR=\#(allowMajorUpgrade ? 1 : 0)
        umask 022
        cmcr_su_dir || exit 70
        if cmcr_su_active; then
          ACTIVE="$(cmcr_su_get run)"; WHEN="$(cmcr_su_when "$(cmcr_su_get started)")"
          if [ "$(cmcr_su_get mode)" = download ]; then WHAT="pobieranie aktualizacji (bez instalacji) uruchomione"
          elif [ "$(cmcr_su_get restart)" = 1 ]; then WHAT="instalacja aktualizacji z ponownym uruchomieniem uruchomiona"
          else WHAT="instalacja aktualizacji bez ponownego uruchomienia uruchomiona"; fi
          if [ $DL = 1 ]; then WANT=download; else WANT=install; fi
          # A run that does less than asked (a download, an install without restart) is not joined: the job would end
          # as if the updates were installed.
          if [ "$(cmcr_su_level "$(cmcr_su_get mode)" "$(cmcr_su_get restart)")" -lt "$(cmcr_su_level $WANT $RESTART)" ]; then
            echo "✘ Na tym komputerze trwa już $WHAT $WHEN – poczekaj, aż się skończy (Aktualizacje › Stan instalacji), i uruchom tę instalację ponownie; teraz niczego nie zainstalowano." >&2
            exit \#(updateBusyCode)
          fi
          echo "\#(updateRunMarker)$ACTIVE"
          # „Przerwij” of this job stops the run it shows: it was started by another session, in another process group.
          trap 'cmcr_su_stop "$ACTIVE"; exit 143' TERM INT
          echo "↻ Na tym komputerze trwa już $WHAT $WHEN – pokazuję postęp zamiast uruchamiać drugą."
          cmcr_su_labels
          cmcr_su_replay 5
          cmcr_su_follow "$ACTIVE"; exit $?
        fi
        RUN='\#(run)'
        [ -f "$CMCR_SU_LOG" ] && mv -f "$CMCR_SU_LOG" "$CMCR_SU_LOG.1"
        : > "$CMCR_SU_LOG"
        if ! { echo "run=$RUN"; echo "boot=$(cmcr_boot)"; echo "started=$(date +%s)"
               if [ $DL = 1 ]; then echo "mode=download"; else echo "mode=install"; fi
               echo "restart=$RESTART"; echo "from=$(cmcr_os)"; echo "phase=list"; } > "$CMCR_SU_STATE.new" \
           || ! mv -f "$CMCR_SU_STATE.new" "$CMCR_SU_STATE"; then
          echo "✘ Nie udało się zapisać stanu instalacji w $CMCR_SU_DIR." >&2; exit 70
        fi
        # Detached from this session: neither a lost connection nor a stalled output relay reaches softwareupdate.
        cmcr_su_runner </dev/null >>"$CMCR_SU_LOG" 2>&1 &
        echo "$RUN $! $(cmcr_boot)" > "$CMCR_SU_PIDF"
        echo "\#(updateRunMarker)$RUN"
        cmcr_su_follow "$RUN"
        """#, asRoot: true)
    }

    /// Follows update run `runID` (nil: the last run CMCR Manager started on the Mac): which updates, its log so far
    /// (the last `replayLines` lines; nil: all of it), its progress while it runs and how it ended – after a restart, the
    /// system version before and now. Reads only, no root needed; stopping it leaves the update running.
    static func followUpdate(runID: String? = nil, replayLines: Int? = nil) -> RemoteScript {
        let run = runID.flatMap { RemoteJobs.isValidID($0) ? shQuote($0) : nil } ?? "\"$(cmcr_su_get run)\""
        return RemoteScript(#"""
        \#(updateRunFunctions)
        if [ ! -f "$CMCR_SU_STATE" ]; then
          echo "Na tym komputerze nie uruchamiano jeszcze instalacji aktualizacji z CMCR Manager."; exit 0
        fi
        RUN=\#(run)
        cmcr_su_wait_run "$RUN" || exit 1
        echo "\#(updateRunMarker)$RUN"
        if [ "$(cmcr_su_get mode)" = download ]; then WHAT="Pobieranie aktualizacji"; else WHAT="Instalacja aktualizacji"; fi
        [ "$(cmcr_su_get restart)" = 1 ] && WHAT="$WHAT z ponownym uruchomieniem"
        echo "▸ $WHAT rozpoczęta $(cmcr_su_when "$(cmcr_su_get started)") na macOS $(cmcr_su_get from):"
        cmcr_su_labels
        cmcr_su_replay \#(replayLines.map { String(max(1, $0)) } ?? "")
        cmcr_su_follow "$RUN"
        """#)
    }

    /// Stops update run `runID` on the Mac: softwareupdate and the session that started it (one process group).
    static func stopUpdate(runID: String) -> RemoteScript {
        let run = RemoteJobs.isValidID(runID) ? runID : "-"
        return RemoteScript(#"""
        \#(updateRunFunctions)
        RUN='\#(run)'
        cmcr_su_stop "$RUN"
        case $? in
          0) echo "▸ Zatrzymano instalację aktualizacji na komputerze." ;;
          2) echo "▸ Instalacja nie działała już na komputerze." ;;
          *) echo "▸ \#(RemoteCancelOutcome.stillRunning.message)" >&2; exit 1 ;;
        esac
        """#, asRoot: true)
    }

    /// softwareupdate lists the history oldest first; the column header stays and the 40 newest follow, newest first.
    static func updateHistory(limit: Int = 40) -> RemoteScript {
        RemoteScript(#"""
        softwareupdate --history 2>&1 | awk -v max=\#(max(1, limit)) '
          NR <= 2 && /^(Display Name|-)/ { print; next }
          { a[++n] = $0 }
          END {
            stop = n > max ? n - max : 0
            for (i = n; i > stop; i--) print a[i]
            if (stop > 0) printf "… pominięto starsze wpisy: %d (pokazano %d najnowszych)\n", stop, max
          }'
        """#)
    }

    /// mas ≥ 4 runs sudo itself; `with_askpass` supplies the askpass and DISPLAY sudo needs without a tty.
    /// Updates apps bought with the Apple ID signed into the App Store on the admin account.
    static func masUpgrade() -> RemoteScript {
        RemoteScript(#"""
        if ! command -v mas >/dev/null 2>&1; then
          echo "Brak narzędzia mas (App Store CLI). Zainstaluj: brew install mas" >&2; exit 2
        fi
        mas outdated
        with_askpass mas upgrade
        """#)
    }
}
