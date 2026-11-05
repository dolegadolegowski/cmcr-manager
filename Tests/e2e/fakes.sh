# Fakes for privileged or disruptive macOS commands used by the end-to-end tests.
# Loaded through BASH_ENV by the test sshd (see run.sh), so every remote `bash` – including the
# root re-exec – sees these functions instead of the real tools. Nothing here needs or uses root.

CMCR_E2E_LOG="${CMCR_E2E_LOG:-/tmp/cmcr-e2e.log}"
_e2e_log() { printf '%s\n' "$*" >> "$CMCR_E2E_LOG"; }
# $CMCR_E2E_WORK/slow.NAME (seconds): the fake NAME first waits that long, logging „NAME: pauza” before and „NAME: po
# pauzie” after, so a test can interrupt the command half-way (AUDIT REV-36). Used by installer, scutil --set,
# launchctl bootout and the question dialog (ask-dialog).
_e2e_slow() {
  local f="${CMCR_E2E_WORK:-/nonexistent}/slow.$1"
  [ -e "$f" ] || return 0
  _e2e_log "$1: pauza"
  sleep "$(cat "$f")"
  _e2e_log "$1: po pauzie"
}

# sudo: accepts the test password from SUDO_ASKPASS (like real sudo -A) and runs the command as the
# current user. CMCR_E2E_NOPASSWD=1 emulates a NOPASSWD sudoers rule.
sudo() {
  local askpass=0 nonint=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -A) askpass=1; shift ;;
      -n) nonint=1; shift ;;
      -u|-g|-p|-C|-h) shift 2 ;;
      --) shift; break ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  if [ "${CMCR_E2E_NOPASSWD:-0}" = 1 ]; then
    [ $# -eq 0 ] && return 0
    _e2e_log "sudo(nopasswd) $*"; SUDO_USER="$(id -un)" "$@"; return
  fi
  if [ $nonint = 1 ]; then echo "sudo: a password is required" >&2; return 1; fi
  if [ $askpass = 0 ]; then echo "sudo: a terminal is required to read the password" >&2; return 1; fi
  # $CMCR_E2E_WORK/sudo.lecture: the warning macOS sudo prints before the first successful authentication of an
  # account (on stderr when it has no terminal), ahead of "Sorry, try again" (AUDIT PRZ-08).
  if [ -e "${CMCR_E2E_WORK:-/nonexistent}/sudo.lecture" ]; then
    printf '\nWARNING: Improper use of the sudo command could lead to data loss\nor the deletion of important system files. Please double-check your\ntyping when using sudo. Type "man sudo" for more information.\n\nTo proceed, enter your password, or type Ctrl-C to abort.\n\n' >&2
  fi
  local pw
  pw="$("$SUDO_ASKPASS" "Password:")" || { echo "sudo: no password was provided" >&2; return 1; }
  if [ "$pw" != "${CMCR_E2E_PASSWORD:-}" ]; then
    _e2e_log "sudo: wrong password (got ${#pw} chars, expected ${#CMCR_E2E_PASSWORD} chars)"
    echo "Sorry, try again." >&2
    pw="$("$SUDO_ASKPASS" "Password:")" || {
      echo "sudo: no password was provided" >&2
      echo "sudo: 1 incorrect password attempt" >&2
      return 1
    }
    [ "$pw" = "${CMCR_E2E_PASSWORD:-}" ] || { echo "sudo: 2 incorrect password attempts" >&2; return 1; }
  fi
  _e2e_log "sudo $*"
  SUDO_USER="$(id -un)" "$@"
}

# screencapture: the screen preview no longer runs it (CMCR Screen Agent takes the picture); a call is only logged and
# refused, so nothing in the tests can capture the real screen of the Mac running them.
screencapture() {
  _e2e_log "screencapture $*"
  echo "screencapture (atrapa): nieużywane – zrzut robi CMCR Screen Agent" >&2
  return 1
}

# tccutil: logged only – the real one would reset privacy permissions of this Mac (install and removal of the screen
# agent run `tccutil reset ScreenCapture pl.cmcr.manager.screen-agent`).
tccutil() { _e2e_log "tccutil $*"; return 0; }

# --- CMCR Screen Agent in the GUI sessions (docs/screen-agent.md) -----------------------------------------------
# launchd's state of the LaunchAgent pl.cmcr.manager.screen-agent in each gui/<uid> domain lives in
# $CMCR_E2E_WORK/launchd/gui-<uid>/: loaded (the plist it was bootstrapped from), pid (the running agent), disabled.
# bootstrap and kickstart start the INSTALLED agent – the plist's ProgramArguments, and only a program under
# $CMCR_E2E_WORK – detached like a launchd job (its own session, no terminal, a fresh environment, output appended to
# $CMCR_E2E_WORK/agent-serve.log) and always in the agent's DEBUG test mode: CMCR_SCREEN_AGENT_TEST_DIR=
# $CMCR_E2E_WORK/agent (no AppKit, ScreenCaptureKit or TCC; the screen's state comes from files there),
# CMCR_SCREEN_AGENT_TEST_UID=<uid> (the socket of that session), CMCR_SETUP_ROOT_PREFIX (the files of the test install).
# bootout sends SIGTERM (the agent removes its socket) and waits for it to end. Unlike launchd it never restarts an
# agent that ended by itself (KeepAlive): `print` then reports "not running" and the scripts have to revive it
# (kickstart -k), which is what the tests check. `print` reports the pid of the agent process itself (the client is
# given it with --pid). With $CMCR_E2E_WORK/agent-nostart the agent never starts (loaded, but no process – like a
# program that ends at once). Calls about anything else return 200 to the caller.
_e2e_agent_dir() { printf '%s/launchd/gui-%s' "${CMCR_E2E_WORK:-/nonexistent}" "$1"; }
# _e2e_agent_pid UID – prints the pid of that session's agent while it runs (a process of this test in serve mode).
_e2e_agent_pid() {
  local p
  p="$(cat "$(_e2e_agent_dir "$1")/pid" 2>/dev/null)"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  case "$(command ps -p "$p" -o command= 2>/dev/null)" in
    "${CMCR_E2E_WORK:-/nonexistent}/"*" serve") echo "$p" ;;
    *) return 1 ;;
  esac
}
_e2e_agent_start() { # _e2e_agent_start UID
  local w="${CMCR_E2E_WORK:-}" d plist exe mode
  [ -n "$w" ] || return 1
  d="$(_e2e_agent_dir "$1")"
  plist="$(cat "$d/loaded" 2>/dev/null)"
  exe="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" 2>/dev/null)"
  mode="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$plist" 2>/dev/null)"
  case "$exe" in
    "$w/"*) ;;
    *) _e2e_log "launchd: usługa spoza katalogu testu nie zostanie uruchomiona (${exe:-?})"; return 1 ;;
  esac
  # A LaunchAgent whose program is missing just does not run (launchd keeps trying).
  [ -x "$exe" ] || { _e2e_log "launchd: brak pliku usługi $exe"; return 0; }
  [ -e "$w/agent-nostart" ] && { _e2e_log "launchd: gui/$1/pl.cmcr.manager.screen-agent nie uruchamia się (test)"; return 0; }
  mkdir -p "$w/agent"
  # $! is the agent itself: env and perl exec it in the same process.
  ( cd / || exit 1
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" USER="$(id -un)" TMPDIR="${TMPDIR:-/tmp/}" \
      CMCR_SETUP_ROOT_PREFIX="${CMCR_SETUP_ROOT_PREFIX:-$w/setup-root}" CMCR_SCREEN_AGENT_TEST_DIR="$w/agent" \
      CMCR_SCREEN_AGENT_TEST_UID="$1" \
      /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec { $ARGV[0] } @ARGV; exit 127' "$exe" "$mode" \
      </dev/null >>"$w/agent-serve.log" 2>&1 &
    echo $! > "$d/pid" )
  _e2e_log "launchd: gui/$1/pl.cmcr.manager.screen-agent uruchomiona"
}
_e2e_agent_stop() { # _e2e_agent_stop UID
  local p i d
  d="$(_e2e_agent_dir "$1")"
  if p="$(_e2e_agent_pid "$1")"; then
    builtin kill -TERM "$p" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
      _e2e_agent_pid "$1" >/dev/null || break
      sleep 0.1
    done
    _e2e_agent_pid "$1" >/dev/null && builtin kill -KILL "$p" 2>/dev/null
    _e2e_log "launchd: gui/$1/pl.cmcr.manager.screen-agent zatrzymana"
  fi
  rm -f "$d/pid"
}
_e2e_agent_launchctl() {
  local cmd="${1:-}" all="$*" k=0 t uid d p label
  [ -n "${CMCR_E2E_WORK:-}" ] || return 200
  shift
  if [ "$cmd" = kickstart ]; then
    while :; do case "${1:-}" in -k) k=1; shift ;; -p|-s) shift ;; *) break ;; esac; done
  fi
  t="${1:-}"
  case "$cmd $t" in
    "bootstrap gui/"[0-9]*)
      case "${2:-}" in */pl.cmcr.manager.screen-agent.plist) ;; *) return 200 ;; esac
      uid="${t#gui/}" ;;
    "bootout gui/"[0-9]*/*|"print gui/"[0-9]*/*|"kickstart gui/"[0-9]*/*|"enable gui/"[0-9]*/*|"disable gui/"[0-9]*/*)
      case "$t" in */pl.cmcr.manager.screen-agent) ;; *) return 200 ;; esac
      uid="${t#gui/}"; uid="${uid%%/*}" ;;
    "bootout gui/"[0-9]*)
      # The whole session ends (logout): its agent goes with it; the rest is the caller's.
      uid="${t#gui/}"
      case "$uid" in *[!0-9]*) return 200 ;; esac
      _e2e_agent_stop "$uid"
      rm -f "$(_e2e_agent_dir "$uid")/loaded"
      return 200 ;;
    *) return 200 ;;
  esac
  case "$uid" in ''|*[!0-9]*) return 200 ;; esac
  d="$(_e2e_agent_dir "$uid")"
  mkdir -p "$d"
  _e2e_log "launchctl $all"
  case "$cmd" in
    print)
      if [ ! -e "$d/loaded" ]; then
        echo "Bad request." >&2
        echo "Could not find service \"pl.cmcr.manager.screen-agent\" in domain for user gui: $uid" >&2
        return 113
      fi
      p="$(_e2e_agent_pid "$uid")"
      printf 'gui/%s/pl.cmcr.manager.screen-agent = {\n\tpath = %s\n\tstate = %s\n' "$uid" "$(cat "$d/loaded")" \
        "$([ -n "$p" ] && echo running || echo 'not running')"
      [ -n "$p" ] && printf '\tpid = %s\n' "$p"
      echo "}"
      return 0 ;;
    bootstrap)
      if [ ! -f "${2:-}" ]; then echo "Bootstrap failed: 2: No such file or directory" >&2; return 2; fi
      label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$2" 2>/dev/null)"
      if [ -e "$d/loaded" ] || [ -e "$d/disabled" ] || [ "$label" != pl.cmcr.manager.screen-agent ]; then
        echo "Bootstrap failed: 5: Input/output error" >&2; return 5
      fi
      printf '%s\n' "$2" > "$d/loaded"
      _e2e_agent_start "$uid"
      return 0 ;;
    bootout)
      _e2e_slow launchctl-bootout
      [ -e "$d/loaded" ] || { echo "Boot-out failed: 3: No such process" >&2; return 3; }
      _e2e_agent_stop "$uid"
      rm -f "$d/loaded"
      return 0 ;;
    kickstart)
      if [ ! -e "$d/loaded" ]; then
        echo "Could not find service \"pl.cmcr.manager.screen-agent\" in domain for user gui: $uid" >&2; return 113
      fi
      if [ -e "$d/disabled" ]; then
        echo "Could not kickstart service \"pl.cmcr.manager.screen-agent\": 119: Service is disabled" >&2; return 119
      fi
      if _e2e_agent_pid "$uid" >/dev/null; then
        [ $k = 1 ] || return 0
        _e2e_agent_stop "$uid"
      fi
      _e2e_agent_start "$uid"
      return 0 ;;
    enable) rm -f "$d/disabled"; return 0 ;;
    disable) : > "$d/disabled"; return 0 ;;
  esac
  return 200
}

# launchctl: `asuser UID cmd…` runs cmd "in the GUI session" – here: only logs it. The screen agent's service in
# gui/<uid> is kept by _e2e_agent_launchctl above; anything else is logged only.
launchctl() {
  case "${1:-}" in
    print|bootout|bootstrap|enable|disable|kickstart)
      _e2e_agent_launchctl "$@"
      local _e2e_rc=$?
      [ "$_e2e_rc" = 200 ] || return "$_e2e_rc" ;;
  esac
  case "${1:-}" in
    asuser)
      shift 2
      if [ "${1:-}" = sudo ]; then
        shift
        local sflags=""
        while [ $# -gt 0 ]; do
          case "$1" in -u) sflags="$sflags -u $2"; shift 2 ;; --) shift; break ;; -*) sflags="$sflags $1"; shift ;; *) break ;; esac
        done
        _e2e_log "gui-sudo:$sflags (cwd $PWD)"
      fi
      local input=""
      if [ ! -t 0 ]; then input="$(cat)"; fi
      _e2e_log "gui-exec: $*"
      [ -n "$input" ] && _e2e_log "gui-stdin: $input"
      # fake-ae-denied: Apple Events refused (Automation/TCC), as the scripts' `on error` handler logs it.
      if [ "${1:-}" = /usr/bin/osascript ] && [ -e "${CMCR_E2E_WORK:-/nonexistent}/fake-ae-denied" ]; then
        echo "CMCR_AE_ERR -1743 Not authorized to send Apple events to the application." >&2
      fi
      return 0 ;;
    print) _e2e_log "launchctl $*"; return 0 ;;
    bootout) _e2e_slow launchctl-bootout; _e2e_log "launchctl $*"; return 0 ;;
    bootstrap|enable|disable|kickstart|load|unload) _e2e_log "launchctl $*"; return 0 ;;
    *) command launchctl "$@" ;;
  esac
}

shutdown() { _e2e_log "shutdown $*"; }
reboot() { _e2e_log "reboot $*"; }
halt() { _e2e_log "halt $*"; }

pmset() {
  _e2e_log "pmset $*"
  case "${1:-}" in
    -g) echo " womp                 1"; echo " sleep                0" ;;
  esac
  return 0
}

# Detached update runs (Scripts+Updates.swift) keep their state here instead of /Library/Application Support/CMCR, and
# wait only a moment for the restart a fake install never brings (real sudo resets both).
export CMCR_SU_STATE_DIR="${CMCR_E2E_WORK:-/tmp/cmcr-e2e-state}/softwareupdate"
# $CMCR_E2E_WORK/su.restart_wait: a longer wait for the restart (seconds; default 1).
CMCR_SU_RESTART_WAIT="$(cat "${CMCR_E2E_WORK:-/nonexistent}/su.restart_wait" 2>/dev/null || echo 1)"
export CMCR_SU_RESTART_WAIT

# An install or download of the fake softwareupdate. Control files in $CMCR_E2E_WORK:
#   softwareupdate.slow – seconds of "Downloading: N%" progress first (one line a second);
#   softwareupdate.fail – printed instead of success, exit code 1 (e.g. "Failed to queue update and restart.").
_e2e_su_run() {
  local w="${CMCR_E2E_WORK:-/nonexistent}" n i
  if [ -e "$w/softwareupdate.slow" ]; then
    n="$(cat "$w/softwareupdate.slow")"
    for ((i = 1; i <= n; i++)); do echo "Downloading: $((i * 100 / n)).00%"; sleep 1; done
  fi
  if [ -e "$w/softwareupdate.fail" ]; then cat "$w/softwareupdate.fail"; return 1; fi
  echo "Done."
}

# kern.boottime and the system version from $CMCR_E2E_WORK/boottime and sw_vers.version / sw_vers.build when present:
# a suite "restarts" the Mac into a new system by changing them.
sysctl() {
  if [ "$*" = "-n kern.boottime" ] && [ -s "${CMCR_E2E_WORK:-/nonexistent}/boottime" ]; then
    echo "{ sec = $(cat "$CMCR_E2E_WORK/boottime"), usec = 0 } Mon Jan  1 00:00:00 2026"; return 0
  fi
  command sysctl "$@"
}
sw_vers() {
  local w="${CMCR_E2E_WORK:-/nonexistent}"
  case "${1:-}" in
    -productVersion) [ -s "$w/sw_vers.version" ] && { cat "$w/sw_vers.version"; return 0; } ;;
    -buildVersion) [ -s "$w/sw_vers.build" ] && { cat "$w/sw_vers.build"; return 0; } ;;
  esac
  command sw_vers "$@"
}
# `log show` prints $CMCR_E2E_WORK/log.show (what the system log says about a failed update).
log() {
  if [ "${1:-}" = show ]; then cat "${CMCR_E2E_WORK:-/nonexistent}/log.show" 2>/dev/null; return 0; fi
  command log "$@"
}

softwareupdate() {
  _e2e_log "softwareupdate $*"
  case " $* " in
    *" --list "*|*" -l "*)
      # $CMCR_E2E_WORK/softwareupdate.list: printed instead of the list below, with the exit code from
      # softwareupdate.list.rc (default 0) – no updates, or a server that cannot be reached (AUDIT APL-10).
      if [ -e "${CMCR_E2E_WORK:-/nonexistent}/softwareupdate.list" ]; then
        cat "$CMCR_E2E_WORK/softwareupdate.list"
        return "$(cat "$CMCR_E2E_WORK/softwareupdate.list.rc" 2>/dev/null || echo 0)"
      fi
      cat <<'EOF'
Software Update Tool

Finding available software
Software Update found the following new or updated software:
* Label: macOS Testowy 99.1-99A123
	Title: macOS Testowy 99.1, Version: 99.1, Size: 1234567KiB, Recommended: YES, Action: restart,
* Label: Safari99.1-99.1
	Title: Safari, Version: 99.1, Size: 123456KiB, Recommended: YES,
EOF
      ;;
    *" --stdinpass "*)
      local pw; IFS= read -r pw
      if [ "$pw" = "${CMCR_E2E_PASSWORD:-}" ]; then _e2e_log "softwareupdate stdinpass ok"; echo "Installing (fake)…"; _e2e_su_run
      else echo "Authentication failed" >&2; return 1; fi ;;
    *" --history "*)
      # Oldest first, as the real softwareupdate. Control file in $CMCR_E2E_WORK: history.count (number of entries).
      local n i; n="$(cat "${CMCR_E2E_WORK:-/nonexistent}/history.count" 2>/dev/null || echo 1)"
      echo "Display Name   Version   Date"; echo "------------   -------   ----"
      for ((i = 1; i < n; i++)); do echo "Stara aktualizacja $i  1.$i      01.01.2020"; done
      echo "macOS Testowy  99.0      01.01.2026" ;;
    *) echo "Installing (fake)…"; _e2e_su_run ;;
  esac
}

installer() {
  _e2e_slow installer
  _e2e_log "installer $*"
  # $CMCR_E2E_WORK/installer.cancel: the job is cancelled while the package installs – SIGTERM to the shell of
  # the job, as the remote cancel sends it (AUDIT APL-08). One time only.
  if [ -e "${CMCR_E2E_WORK:-/nonexistent}/installer.cancel" ]; then
    rm -f "$CMCR_E2E_WORK/installer.cancel"
    _e2e_log "installer: anulowano"
    builtin kill -TERM $$
    sleep 2 & wait $!
    return 143
  fi
  local pkg=""
  while [ $# -gt 0 ]; do case "$1" in -pkg) pkg="$2"; shift 2 ;; *) shift ;; esac; done
  [ -e "$pkg" ] || { echo "installer: Error - the package path specified was invalid: '$pkg'." >&2; return 1; }
  echo "installer: The install was successful."
}

# chown: logged only. The working directory is logged too: scripts change owners from inside a folder ("chown x .").
# With $CMCR_E2E_WORK/chown.fail it refuses, like chown for an account that does not exist (AUDIT PLI-08).
chown() {
  _e2e_log "chown $* (cwd $PWD)"
  if [ -e "${CMCR_E2E_WORK:-/nonexistent}/chown.fail" ]; then echo "chown: odmowa (test)" >&2; return 1; fi
  return 0
}
systemsetup() { _e2e_log "systemsetup $*"; echo "Remote Login: On"; }
# scutil --set: logged only; with $CMCR_E2E_WORK/scutil-set.fail it fails (AUDIT PRZ-16).
scutil() {
  case "${1:-}" in
    --set)
      _e2e_slow scutil
      _e2e_log "scutil $*"
      if [ -e "${CMCR_E2E_WORK:-/nonexistent}/scutil-set.fail" ]; then echo "SCPreferencesSetComputerName() failed: test" >&2; return 1; fi ;;
    *) command scutil "$@" ;;
  esac
}
dseditgroup() {
  case " $* " in
    *" checkmember "*) command dseditgroup "$@" ;;
    *) _e2e_log "dseditgroup $*"; return 0 ;;
  esac
}
visudo() { _e2e_log "visudo $*"; return 0; }
# spctl: an assessment (--assess/-a, read-only) asks the real Gatekeeper, so installers are checked for real;
# anything that would change the policy is only logged.
# With $CMCR_E2E_WORK/spctl.override it answers like a Mac with Gatekeeper switched off.
spctl() {
  case "${1:-}" in
    --assess|-a)
      _e2e_log "spctl $*"
      if [ -e "${CMCR_E2E_WORK:-/nonexistent}/spctl.override" ]; then
        local last=""; for last in "$@"; do :; done
        printf '%s: accepted\noverride=security disabled\n' "$last" >&2; return 0
      fi
      command spctl "$@" ;;
    *) _e2e_log "spctl $*"; return 0 ;;
  esac
}
# defaults write/delete: logged only; with $CMCR_E2E_WORK/defaults-write.fail they fail (AUDIT PRZ-16).
defaults() {
  case " $* " in
    *" write "*|*" delete "*)
      _e2e_log "defaults $*"
      if [ -e "${CMCR_E2E_WORK:-/nonexistent}/defaults-write.fail" ]; then echo "Could not write domain (test)" >&2; return 1; fi
      return 0 ;;
    *) command defaults "$@" ;;
  esac
}
# brew: like the real one, re-runs with a filtered environment (env -i keeps SUDO_ASKPASS) and asks the
# askpass for the password, as `sudo -A` inside brew would.
brew() {
  _e2e_log "brew $*"
  if [ -n "${SUDO_ASKPASS:-}" ]; then
    local pw
    pw="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" SUDO_ASKPASS="$SUDO_ASKPASS" /bin/sh -c '"$SUDO_ASKPASS" brew-sudo')"
    if [ "$pw" = "${CMCR_E2E_PASSWORD:-}" ]; then _e2e_log "brew: askpass ok"; else _e2e_log "brew: askpass FAILED"; fi
  fi
  echo "brew (fake) $*"
}
# mas ≥ 4 calls plain sudo, which uses the askpass only when DISPLAY is set.
mas() {
  _e2e_log "mas $*"
  if [ "${1:-}" = upgrade ]; then
    if [ -n "${DISPLAY:-}" ] && [ -x "${SUDO_ASKPASS:-}" ]; then _e2e_log "mas: askpass+DISPLAY ok"; else _e2e_log "mas: no askpass"; fi
  fi
  echo "mas (fake) $*"
}
osascript() { _e2e_log "osascript $*"; return 0; }
# FileVault state comes from marker files in the test folder: fake-filevault (on, admin can unlock),
# fake-filevault-nouser (on, admin not enabled for FileVault).
fdesetup() {
  local w="${CMCR_E2E_WORK:-/nonexistent}"
  case "${1:-}" in
    isactive)
      if [ -e "$w/fake-filevault" ] || [ -e "$w/fake-filevault-nouser" ] || [ -e "$w/filevault.on" ]; then
        echo true; return 0
      fi
      echo false; return 1 ;;
    status)
      if [ -e "$w/fake-filevault" ] || [ -e "$w/fake-filevault-nouser" ]; then echo "FileVault is On."; else echo "FileVault is Off."; fi ;;
    supportsauthrestart) echo true ;;
    list) [ -e "$w/fake-filevault" ] && echo "$(id -un),00000000-0000-0000-0000-000000000000"; return 0 ;;
    authrestart)
      local input; input="$(cat)"
      if [ -e "$w/fake-fde-refuse" ]; then
        _e2e_log "fdesetup $* refused"; echo "Error: Unable to restart with authentication." >&2; return 1
      fi
      case "$input" in
        *"<string>${CMCR_E2E_PASSWORD:-}</string>"*) _e2e_log "fdesetup $* password ok" ;;
        *) _e2e_log "fdesetup $* password WRONG"; echo "Error: User could not be authenticated." >&2; return 1 ;;
      esac ;;
    *) _e2e_log "fdesetup $*" ;;
  esac
}
# Nobody at the login window when $CMCR_E2E_WORK/fake-no-console exists.
stat() {
  if [ "$*" = "-f%Su /dev/console" ] && [ -e "${CMCR_E2E_WORK:-/nonexistent}/fake-no-console" ]; then echo root; return 0; fi
  # Console user override for screen-preview tests: $CMCR_E2E_WORK/console_user replaces the owner of
  # /dev/console (e.g. "daemon" for a student session that needs root, "root" for the login window).
  if [ "$*" = "-f%Su /dev/console" ] && [ -s "${CMCR_E2E_WORK:-/nonexistent}/console_user" ]; then
    cat "$CMCR_E2E_WORK/console_user"; return 0
  fi
  # Paths listed in $CMCR_E2E_WORK/restricted.paths carry the SIP flag "restricted" (stat -f %Sf), like the
  # system's own applications (AUDIT APL-07).
  if [ "${1:-} ${2:-}" = "-f %Sf" ] && [ -s "${CMCR_E2E_WORK:-/nonexistent}/restricted.paths" ] \
     && grep -qxF -- "${3:-}" "$CMCR_E2E_WORK/restricted.paths"; then
    echo restricted; return 0
  fi
  # $CMCR_E2E_WORK/stat.uid ("uid folder" per line, the folder's physical path): `stat -f %u` of that folder answers
  # with the uid, like a folder left by a deleted account (AUDIT REV-48).
  if [ $# = 3 ] && [ "$1 $2" = "-f %u" ] && [ -s "${CMCR_E2E_WORK:-/nonexistent}/stat.uid" ]; then
    local _e2e_p _e2e_u
    _e2e_p="$(cd -P -- "$3" 2>/dev/null && /bin/pwd -P)"
    _e2e_u="$(awk -v p="$_e2e_p" 'p != "" { u = $1; sub(/^[^ ]+ /, ""); if ($0 == p) { print u; exit } }' \
      "$CMCR_E2E_WORK/stat.uid")"
    if [ -n "$_e2e_u" ]; then echo "$_e2e_u"; return 0; fi
  fi
  command stat "$@"
}
# `diskutil apfs listUsers`: the current user is a volume owner (whatever the account running the tests really is),
# unless a control file in $CMCR_E2E_WORK says otherwise:
#   fake-no-volume-owner – listed as a cryptographic user that is not a volume owner;
#   fake-volume-owner-unlisted – not a cryptographic user at all (no Secure Token).
diskutil() {
  if [ "${1:-} ${2:-}" = "apfs listUsers" ]; then
    local w="${CMCR_E2E_WORK:-/nonexistent}" g owner=Yes
    g="$(command dscl . -read "/Users/$(id -un)" GeneratedUID | awk '{print $2}')"
    [ -e "$w/fake-no-volume-owner" ] && owner=No
    printf 'Cryptographic users for disk3s1s1 (2 found)\n|\n'
    if [ ! -e "$w/fake-volume-owner-unlisted" ]; then
      printf '+-- %s\n|   Type: Local Open Directory User\n|   Volume Owner: %s\n|\n' "$g" "$owner"
    fi
    printf '+-- EBC6C064-0000-11AA-AA11-00306543ECAC\n    Type: Personal Recovery User\n    Volume Owner: Yes\n'
    return 0
  fi
  case "${1:-} ${2:-}" in
    "list "*|"info "*|"apfs list"*) command diskutil "$@" ;;
    *) _e2e_log "diskutil $*"; return 0 ;;
  esac
}
dscl() {
  case " $* " in
    *" -read "*|*" -list "*|*" -search "*) command dscl "$@" ;;
    *) _e2e_log "dscl $*"; return 0 ;;
  esac
}
createhomedir() { _e2e_log "createhomedir $*"; return 0; }
networksetup() {
  case "${1:-}" in
    -list*|-get*|-print*|-show*) command networksetup "$@" ;;
    *) _e2e_log "networksetup $*"; return 0 ;;
  esac
}
# Installed apps and uninstalling (Tests/e2e/suites/apps-uninstall.sh). The student's ~/Applications and the system
# folders of launchd items and package files live in $CMCR_E2E_WORK (Scripts+Apps.swift reads these variables).
[ -n "${CMCR_E2E_WORK:-}" ] && export CMCR_USERS_DIR="$CMCR_E2E_WORK/Users" CMCR_FS_PREFIX="$CMCR_E2E_WORK/fsroot"
# pkgutil: only the test's receipts, $CMCR_E2E_WORK/receipts/ID/{info,files,dirs} (info: "version: …", "location: …",
# "install-time: …"; files and dirs: paths relative to the location). --forget removes the receipt.
pkgutil() {
  local d="${CMCR_E2E_WORK:-/nonexistent}/receipts" mode="" id="" only="" r loc p q
  _e2e_log "pkgutil $*"
  while [ $# -gt 0 ]; do
    case "$1" in
      --pkgs) mode=pkgs ;;
      --pkg-info|--files|--forget|--file-info) mode="${1#--}"; id="${2:-}"; shift ;;
      --only-files) only=files ;;
      --only-dirs) only=dirs ;;
      --volume) shift ;;
    esac
    shift
  done
  case "$mode" in
    pkgs) [ -d "$d" ] && ls "$d"; return 0 ;;
    file-info)
      echo "volume: /"; echo "path: $id"
      for r in "$d"/*/; do
        r="${r%/}"; [ -f "$r/info" ] || continue
        loc="$(sed -n 's/^location: *//p' "$r/info")"
        while IFS= read -r p; do
          q="$(printf '/%s/%s' "$loc" "$p" | sed 's#//*#/#g')"
          [ "$q" = "$id" ] && { echo "pkgid: $(basename "$r")"; break; }
        done < <(cat "$r/files" "$r/dirs" 2>/dev/null)
      done
      return 0 ;;
  esac
  [ -d "$d/$id" ] || { echo "No receipt for '$id' found at '/'." >&2; return 1; }
  case "$mode" in
    pkg-info) echo "package-id: $id"; cat "$d/$id/info"; echo "volume: /" ;;
    files)
      case "$only" in files) cat "$d/$id/files" 2>/dev/null ;; dirs) cat "$d/$id/dirs" 2>/dev/null ;;
        *) cat "$d/$id/dirs" "$d/$id/files" 2>/dev/null ;; esac ;;
    forget) rm -rf "$d/$id"; echo "Forgot package '$id' on '/'." ;;
  esac
}
# profiles: enrolled in MDM while $CMCR_E2E_WORK/mdm.enrolled exists; nothing else is ever changed.
profiles() {
  case " $* " in
    *" status "*)
      if [ -e "${CMCR_E2E_WORK:-/nonexistent}/mdm.enrolled" ]; then printf 'Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)\n'
      else printf 'Enrolled via DEP: No\nMDM enrollment: No\n'; fi ;;
    *) _e2e_log "profiles $*" ;;
  esac
  return 0
}
export -f pkgutil profiles 2>/dev/null
# With $CMCR_E2E_WORK/tar.addfile: right after a folder was packed (tar -cf - .), a file appears in it – a student
# saving work between collecting and cleaning at the end of a lesson (AUDIT ZAJ-01). One time only.
tar() {
  # $CMCR_E2E_WORK/tar.mode: log the mode of each unpacked archive (uploads wait in /tmp, AUDIT PLI-02).
  if [ "${1:-}" = -xf ] && [ -e "${CMCR_E2E_WORK:-/nonexistent}/tar.mode" ]; then
    command stat -f 'tar-mode %Lp %N' "$2" >> "$CMCR_E2E_WORK/tar.mode"
  fi
  command tar "$@"
  local rc=$?
  if [ "${1:-}" = -cf ] && [ -e "${CMCR_E2E_WORK:-/nonexistent}/tar.addfile" ]; then
    rm -f "$CMCR_E2E_WORK/tar.addfile"
    echo "zapisane po zebraniu" > ./nowy-po-zebraniu.txt
  fi
  return $rc
}
# With $CMCR_E2E_WORK/ps.sessions ("uid account" per line): more GUI sessions, as after "Switch User" (AUDIT DOD-03).
ps() {
  command ps "$@"
  local rc=$?
  if [ "$*" = "-axo uid=,user=,comm=" ] && [ -s "${CMCR_E2E_WORK:-/nonexistent}/ps.sessions" ]; then
    awk '{printf "%5d %-16s /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow\n", $1, $2}' \
      "$CMCR_E2E_WORK/ps.sessions"
  fi
  return $rc
}
export -f _e2e_log sudo screencapture tccutil _e2e_agent_dir _e2e_agent_pid _e2e_agent_start _e2e_agent_stop \
  _e2e_agent_launchctl launchctl shutdown reboot halt pmset softwareupdate installer tar ps \
  _e2e_su_run sysctl sw_vers log \
  chown systemsetup scutil dseditgroup visudo spctl defaults brew mas osascript fdesetup stat diskutil dscl \
  createhomedir networksetup 2>/dev/null

# ---------------------------------------------------------------- classroom, attention mode, power (U8)
# State of these fakes lives in $CMCR_E2E_WORK, so suites can prepare and inspect it (lockscreen.fail,
# filevault.on, ask.answer, ask.timeout, pmset.repeat …).
_e2e_state() { printf '%s/%s' "${CMCR_E2E_WORK:-/tmp/cmcr-e2e-state}" "$1"; }

# launchctl: wraps the fake above. LockScreen and the attention overlay are only recorded as "running";
# question dialogs (Scripts.ask) get a canned answer.
eval "_e2e_launchctl_base() $(declare -f launchctl | tail -n +2)"
launchctl() {
  if [ "${1:-}" != asuser ]; then _e2e_launchctl_base "$@"; return; fi
  local all=" $* " last="" a
  for a in "$@"; do last="$a"; done
  case "$all" in
    *"/LockScreen "*)
      _e2e_log "lockscreen: $*"
      [ -e "$(_e2e_state lockscreen.fail)" ] || : > "$(_e2e_state lockscreen.running)"
      return 0 ;;
    *" CMCR_ATTENTION "*)
      case "$all" in *" /usr/bin/osascript -l JavaScript "*) _e2e_log "attention-overlay: osascript JXA $last" ;;
        *) _e2e_log "attention-overlay: $last" ;; esac
      : > "$(_e2e_state attention.running)"
      # Like the real overlay: whether macOS let it take the keyboard (overlay.inactive: it did not;
      # overlay.silent: no report at all).
      if [ -e "$(_e2e_state overlay.silent)" ]; then :
      elif [ -e "$(_e2e_state overlay.inactive)" ]; then echo "CMCR:OVERLAY:inactive"
      else echo "CMCR:OVERLAY:active"; fi
      return 0 ;;
  esac
  local input=""
  if [ ! -t 0 ]; then input="$(cat)"; fi
  case "$input" in
    *"CMCR:ANSWER:"*)
      _e2e_log "ask-dialog"
      _e2e_slow ask-dialog
      if [ -e "$(_e2e_state ask.timeout)" ]; then echo "CMCR:TIMEOUT"; return 0; fi
      case "$input" in
        *"default answer"*) printf 'CMCR:ANSWER:Wyślij\t%s\n' "$(cat "$(_e2e_state ask.answer)" 2>/dev/null || echo odpowiedź)" ;;
        *) printf 'CMCR:ANSWER:%s\n' "$(printf '%s\n' "$input" | sed -n 's/.*buttons {"\([^"]*\)".*/\1/p' | head -1)" ;;
      esac
      return 0 ;;
  esac
  printf '%s' "$input" | _e2e_launchctl_base "$@"
}

_e2e_pattern() { local a p=""; for a in "$@"; do case "$a" in -*) ;; *) p="$a" ;; esac; done; printf '%s' "$p"; }

# pgrep/pkill: LockScreen and the overlay are simulated; the tagged helper processes the scripts start
# (timers) are real and may be stopped, but only this user's. Nothing else is ever killed.
# `pgrep -u UID -f CMCR_ATTENTION` (only that account's processes) keeps its -u for the real helper processes.
pgrep() {
  local a prev="" eu=""
  for a in "$@"; do [ "$prev" = -u ] && eu="$a"; prev="$a"; done
  case "$(_e2e_pattern "$@")" in
    LockScreen) [ -e "$(_e2e_state lockscreen.running)" ] && { echo 99901; return 0; }; return 1 ;;
    CMCR_ATTENTION)
      [ -e "$(_e2e_state attention.running)" ] && { echo 99902; return 0; }
      command pgrep -U "$(id -u)" ${eu:+-u "$eu"} -f CMCR_ATTENTION ;;
    cmcr-delayed-power) command pgrep -U "$(id -u)" -f cmcr-delayed-power ;;
    *) command pgrep "$@" ;;
  esac
}
pkill() {
  local p rc=1 sig="" pids
  p="$(_e2e_pattern "$@")"
  _e2e_log "pkill $*"
  case "$p" in
    LockScreen) [ -e "$(_e2e_state lockscreen.running)" ] && rc=0; rm -f "$(_e2e_state lockscreen.running)" ;;
    CMCR_ATTENTION)
      [ -e "$(_e2e_state attention.running)" ] && rc=0; rm -f "$(_e2e_state attention.running)"
      command pkill -U "$(id -u)" -f CMCR_ATTENTION && rc=0 ;;
    cmcr-delayed-power) command pkill -U "$(id -u)" -f cmcr-delayed-power && rc=0 ;;
    # The test user's real replayd is never stopped (renewing the screen-capture consent, cmcr_sc_approval).
    replayd) rc=0 ;;
    *)
      # Anything else really signals the matching processes, but through the guarded kill below.
      case "${1:-}" in -[0-9]*|-[A-Z][A-Z]*) sig="$1"; shift ;; esac
      pids="$(command pgrep "$@")" && [ -n "$pids" ] && kill ${sig:+"$sig"} $pids && rc=0 ;;
  esac
  return $rc
}

# kill: refuses to signal application processes (…/X.app/Contents/MacOS/…) that do not belong to the test,
# e.g. when "Zamknij wszystkie aplikacje" would otherwise reach the real apps of the user running the tests.
kill() {
  local a cmd args=() pids=0 ended=0
  for a in "$@"; do
    # Process groups (kill -- -PGID, used by the remote job cancel): allowed only for groups led by a
    # CMCR job shell or by a process of this test.
    if [ $ended = 1 ] || { [ "${#args[@]}" -gt 0 ] && case "$a" in -[0-9]*) true ;; *) false ;; esac; }; then
      case "$a" in
        -[0-9]*)
          cmd="$(command ps -p "${a#-}" -o command= 2>/dev/null)"
          case "$cmd" in
            *CMCR:SESSION-STARTED*|*/tmp/cmcr.*|*"${CMCR_E2E_WORK:-/nonexistent-cmcr-e2e}/"*) args+=("$a"); pids=$((pids + 1)) ;;
            "") args+=("$a"); pids=$((pids + 1)) ;;
            *) _e2e_log "kill zablokowany (grupa spoza testu): $a $cmd" ;;
          esac
          continue ;;
      esac
    fi
    case "$a" in
      --) args+=("$a"); ended=1 ;;
      -*|%*) args+=("$a") ;;
      *)
        cmd="$(command ps -p "$a" -o command= 2>/dev/null)"
        case "$cmd" in
          *"${CMCR_E2E_WORK:-/nonexistent-cmcr-e2e}/"*) args+=("$a"); pids=$((pids + 1)) ;;
          # A CMCR job shell or a subshell of one (e.g. the time limit of an agent call): its command line is the whole
          # script, which names the agent's …/CMCR Screen Agent.app/Contents/MacOS/… – still a process of this test.
          *CMCR:SESSION-STARTED*) args+=("$a"); pids=$((pids + 1)) ;;
          *.app/Contents/MacOS/*) _e2e_log "kill zablokowany (aplikacja spoza testu): $a $cmd" ;;
          *) args+=("$a"); pids=$((pids + 1)) ;;
        esac ;;
    esac
  done
  if [ $pids -eq 0 ]; then
    case " $* " in *" -l "*|*" -L "*) builtin kill "$@"; return ;; esac
    return 0
  fi
  builtin kill "${args[@]}"
}

ioreg() {
  case " $* " in
    *" IOConsoleUsers "*|*" Root "*)
      printf '  "IOConsoleUsers" = ({"kCGSSessionOnConsoleKey"=No,"kCGSSessionIDKey"=111,"kCGSSessionUserNameKey"="inny"},{"kCGSSessionOnConsoleKey"=Yes,"kCGSSessionIDKey"=4242,"kCGSSessionUserNameKey"="%s"})\n' "$(id -un)" ;;
    *) command ioreg "$@" ;;
  esac
}

# pmset: keeps the repeating schedule and -a settings in state files and prints them like pmset does.
pmset() {
  _e2e_log "pmset $*"
  local f; f="$(_e2e_state pmset.repeat)"
  case "${1:-}" in
    -g)
      case "${2:-}" in
        sched)
          if [ -s "$f" ]; then echo "Repeating power events:"; cat "$f"; fi
          echo "Scheduled power events:"
          echo " [0]  wake at 10/06/2026 07:45:00 by 'com.apple.alarm.user-invisible-e2e'" ;;
        *)
          echo "System-wide power settings:"
          echo "Currently in use:"
          echo " womp                 $(cat "$(_e2e_state pmset.womp)" 2>/dev/null || echo 1)"
          echo " autorestart          $(cat "$(_e2e_state pmset.autorestart)" 2>/dev/null || echo 0)"
          echo " sleep                0"
          echo " displaysleep         10" ;;
      esac ;;
    repeat)
      shift
      if [ "${1:-}" = cancel ]; then rm -f "$f"; return 0; fi
      local out="" type days time h m ap d
      while [ $# -ge 3 ]; do
        type="$1"; days="$2"; time="$3"; shift 3
        case "$type" in wake|poweron|wakeorpoweron|sleep|shutdown|restart) ;; *) echo "pmset: bad type $type" >&2; return 1 ;; esac
        case "$days" in ""|*[!MTWRFSU]*) echo "pmset: bad weekdays $days" >&2; return 1 ;; esac
        case "$time" in [0-2][0-9]:[0-5][0-9]:[0-5][0-9]) ;; *) echo "pmset: bad time $time" >&2; return 1 ;; esac
        [ "$type" = wakeorpoweron ] && type=wakepoweron
        h=$((10#${time%%:*})); m="${time#*:}"; m="${m%%:*}"; ap=AM
        [ $h -ge 12 ] && ap=PM
        [ $h -gt 12 ] && h=$((h - 12))
        [ $h -eq 0 ] && h=12
        case "$days" in MTWRF) d="weekdays only" ;; MTWRFSU) d="every day" ;; SU) d="weekends only" ;; *) d="$days" ;; esac
        out="$out$(printf '  %s at %d:%s%s %s' "$type" "$h" "$m" "$ap" "$d")
"
      done
      [ $# -eq 0 ] || { echo "pmset: bad arguments" >&2; return 1; }
      printf '%s' "$out" > "$f" ;;
    -a|-c|-b)
      shift
      while [ $# -ge 2 ]; do echo "$2" > "$(_e2e_state "pmset.$1")"; shift 2; done ;;
  esac
  return 0
}

# fdesetup: the fake above also answers for the classroom state file filevault.on.
# killall: `shutdown` (pending shutdown +N) and mDNSResponder (root daemon) are simulated; other names go
# through the guarded kill, limited to this user's processes.
killall() {
  _e2e_log "killall $*"
  local a sig="" name="" pids
  for a in "$@"; do
    case "$a" in -[0-9]*|-[A-Z][A-Z]*) sig="$a" ;; -*) ;; *) name="$a" ;; esac
  done
  case "$name" in
    shutdown|mDNSResponder) return 0 ;;
  esac
  pids="$(command pgrep -U "$(id -u)" -x "$name")" && [ -n "$pids" ] || return 1
  kill ${sig:+"$sig"} $pids
}
dscacheutil() { _e2e_log "dscacheutil $*"; return 0; }
export -f _e2e_state _e2e_launchctl_base launchctl _e2e_pattern pgrep pkill kill ioreg pmset fdesetup killall \
  dscacheutil 2>/dev/null

# The classroom block (U8) wraps launchctl, replaces pmset (a superset of the fake above) and adds
# pgrep/pkill/kill/killall/ioreg/fdesetup/dscacheutil; the setup block after it wraps those again (it only
# takes over while a setup test prepares $CMCR_E2E_WORK/setup-sys).
# --- One-time setup script and readiness check (Tests/e2e/suites/setup.sh) ----------------------------
# setup/cmcr-imac-setup.sh and Scripts.readiness put every system file and home folder they touch under
# CMCR_SETUP_ROOT_PREFIX. While the setup suite runs it creates $CMCR_E2E_WORK/setup-sys, which switches
# the fakes below to a small simulated system state (launchd services, pmset, firewall, FileVault); otherwise
# they behave like the fakes above or pass read-only calls through.
[ -n "${CMCR_E2E_WORK:-}" ] && export CMCR_SETUP_ROOT_PREFIX="$CMCR_E2E_WORK/setup-root"
# The screen agent's client (cmcr-screen-agent client, run by the preview, install, status and readiness scripts) in
# its DEBUG test mode: it trusts an agent running as the developer also for another uid (the harness has no root and no
# second account); the checks of the socket, the executable path and serve mode stay (docs/screen-agent.md › Testy).
[ -n "${CMCR_E2E_WORK:-}" ] && export CMCR_SCREEN_AGENT_TEST_DIR="$CMCR_E2E_WORK/agent"
_e2e_sys() { [ -n "${CMCR_E2E_WORK:-}" ] && [ -d "$CMCR_E2E_WORK/setup-sys" ]; }
# Keeps an earlier fake of NAME callable as _e2e_base_NAME, so the wrappers below compose with it. A wrapper
# inherited from the parent shell (export -f) is skipped: wrapping it again would make it call itself.
_e2e_wrap() {
  declare -F "$1" >/dev/null || return 0
  declare -f "$1" | grep -q 'e2e-setup-wrapper' && return 0
  eval "$(declare -f "$1" | sed "1s/^$1 /_e2e_base_$1 /")"
}
# _e2e_next NAME ARGS… – the earlier fake when there is one, otherwise the real tool (read-only uses only).
_e2e_next() {
  local n=$1; shift
  if declare -F "_e2e_base_$n" >/dev/null; then "_e2e_base_$n" "$@"; else command "$n" "$@"; fi
}
# Same, but never falls back to the real tool.
_e2e_next_fake() {
  local n=$1; shift
  if declare -F "_e2e_base_$n" >/dev/null; then "_e2e_base_$n" "$@"; else _e2e_log "$n $*"; fi
}
for _e2e_f in launchctl pmset fdesetup dscl dseditgroup; do _e2e_wrap "$_e2e_f"; done
unset _e2e_f
# Service access lists (com.apple.access_ssh, …) are simulated while setup-sys/groups exists: one file per
# group, with lines "nested GUID" (nested group, e.g. admin) and "member NAME" (direct member).
_e2e_groups() { _e2e_sys && [ -d "$CMCR_E2E_WORK/setup-sys/groups" ]; }

launchctl() {
  : e2e-setup-wrapper
  if _e2e_sys; then
    local st="$CMCR_E2E_WORK/setup-sys"
    case "${1:-} ${2:-}" in
      "print system/com.openssh.sshd"|"print system/com.apple.screensharing")
        _e2e_log "launchctl $*"
        [ -e "$st/off-${2#system/}" ] && return 113
        return 0 ;;
      "bootstrap system")
        _e2e_log "launchctl $*"
        case "${3:-}" in
          */ssh.plist) rm -f "$st/off-com.openssh.sshd" ;;
          */com.apple.screensharing.plist) rm -f "$st/off-com.apple.screensharing" ;;
        esac
        return 0 ;;
      "asuser "*)
        if [ "${3:-}" = osascript ]; then shift 3; osascript "$@"; return; fi ;;
    esac
  fi
  _e2e_next_fake launchctl "$@"
}

# pmset-repeat.fail in $CMCR_E2E_WORK: `pmset repeat` refuses every schedule (exit 1), as pmset does for a
# schedule it cannot store.
pmset() {
  : e2e-setup-wrapper
  if [ "${1:-}" = repeat ] && [ -e "${CMCR_E2E_WORK:-/nonexistent}/pmset-repeat.fail" ]; then
    _e2e_log "pmset $* (odmowa)"
    echo "pmset: Error scheduling repeating power events (test)" >&2
    return 1
  fi
  if _e2e_sys; then
    local st="$CMCR_E2E_WORK/setup-sys"
    _e2e_log "pmset $*"
    case "${1:-} ${2:-}" in
      "-g cap") echo "Capabilities for AC Power:"; printf ' %s\n' womp tcpkeepalive sleep displaysleep autorestart ;;
      "-g sched")
        if [ -s "$st/sched" ]; then echo "Repeating power events:"; sed 's/^/  /' "$st/sched"
        else echo "Scheduled power events:"; fi ;;
      "-g ")
        echo "System-wide power settings:"; echo "Currently in use:"
        sed 's/^/ /' "$st/pmset" 2>/dev/null ;;
      "-a "*)
        # setup-sys/pmset-a.fail: pmset refuses the settings listed there, one name per line (AUDIT PRZ-16).
        if grep -qxF -- "${2:-}" "$st/pmset-a.fail" 2>/dev/null; then echo "pmset: odmowa (test)" >&2; return 1; fi
        # Like the real pmset, numbers are kept as numbers: „05” is stored and shown as 5 (AUDIT REV-41).
        local v="${3:-}"
        case "$v" in ''|*[!0-9]*) ;; *) v=$((10#$v)) ;; esac
        { grep -v "^${2:-} " "$st/pmset" 2>/dev/null; echo "${2:-} $v"; } > "$st/pmset.new"
        mv "$st/pmset.new" "$st/pmset" ;;
      "repeat cancel") rm -f "$st/sched" ;;
      "repeat "*) shift; echo "$*" > "$st/sched" ;;
    esac
    return 0
  fi
  _e2e_next_fake pmset "$@"
}

# plutil-macos15 in $CMCR_E2E_WORK: plutil behaves like macOS 15, which prints „Could not extract value…” for a
# missing key on stdout (macOS 26 and later: on stderr). Otherwise the real plutil.
plutil() {
  if [ -e "${CMCR_E2E_WORK:-/nonexistent}/plutil-macos15" ]; then command plutil "$@" 2>&1; else command plutil "$@"; fi
}

socketfilterfw() {
  local st="${CMCR_E2E_WORK:-/nonexistent}/setup-sys"
  case "${1:-}" in
    --getblockall)
      if [ -e "$st/blockall" ]; then echo "Firewall has block all state set to enabled."
      else echo "Firewall has block all state set to disabled."; fi ;;
    --getglobalstate) echo "Firewall is disabled. (State = 0)" ;;
    --setblockall) _e2e_log "socketfilterfw $*"; [ "${2:-}" = off ] && rm -f "$st/blockall" ;;
    *) _e2e_log "socketfilterfw $*" ;;
  esac
  return 0
}

fdesetup() {
  : e2e-setup-wrapper
  case "${1:-}" in
    status)
      if _e2e_sys && [ -f "$CMCR_E2E_WORK/setup-sys/filevault" ]; then cat "$CMCR_E2E_WORK/setup-sys/filevault"; return 0; fi
      _e2e_next fdesetup "$@" ;;
    *) _e2e_next_fake fdesetup "$@" ;;
  esac
}

# sshd -t validates a configuration; the suite makes it fail by creating setup-sys/sshd-t-fails.
sshd() {
  case " $* " in
    *" -t "*)
      _e2e_log "sshd $*"
      if [ -e "${CMCR_E2E_WORK:-/nonexistent}/setup-sys/sshd-t-fails" ]; then
        echo "/etc/ssh/sshd_config.d/050-cmcr-manager.conf line 3: Bad configuration option (test)" >&2
        return 255
      fi
      return 0 ;;
  esac
  _e2e_log "sshd $*"
  return 1
}

ssh-keygen() {
  case " $* " in
    *" -A "*) _e2e_log "ssh-keygen $*"; return 0 ;;
  esac
  command ssh-keygen "$@"
}

dscl() {
  : e2e-setup-wrapper
  if _e2e_groups; then
    local gdir="$CMCR_E2E_WORK/setup-sys/groups"
    case "${2:-} ${3:-}" in
      "-read /Groups/com.apple.access_"*)
        [ -f "$gdir/${3#/Groups/}" ] || { echo "<dscl_cmd> DS Error: -14136 (eDSRecordNotFound)" >&2; return 56; }
        case "${4:-}" in
          RecordName) echo "RecordName: ${3#/Groups/}" ;;
          NestedGroups|GroupMembership)
            local key=nested; [ "$4" = GroupMembership ] && key=member
            grep -q "^$key " "$gdir/${3#/Groups/}" || { echo "No such key: $4" >&2; return 181; }
            echo "$4: $(sed -n "s/^$key //p" "$gdir/${3#/Groups/}" | tr '\n' ' ')" ;;
        esac
        return 0 ;;
      "-change /Groups/com.apple.access_"*)
        _e2e_log "dscl $*"
        mv "$gdir/${3#/Groups/}" "$gdir/${6:-renamed}"
        return 0 ;;
    esac
  fi
  case " $* " in
    *" -create "*|*" -change "*|*" -append "*|*" -delete "*|*" -merge "*|*" -passwd "*|*" -createpl "*|*" -deletepl "*)
      _e2e_log "dscl $*"; return 0 ;;
  esac
  _e2e_next dscl "$@"
}
dseditgroup() {
  : e2e-setup-wrapper
  local g a u="" prev=""
  for g in "$@"; do :; done
  if _e2e_groups; then
    case "$g" in com.apple.access_*)
      local f="$CMCR_E2E_WORK/setup-sys/groups/$g"
      case " $* " in
        *" checkmember "*)
          for a in "$@"; do [ "$prev" = -m ] && u=$a; prev=$a; done
          if [ -f "$f" ] && { grep -qx "member $u" "$f" \
               || { grep -q '^nested ' "$f" && _e2e_next dseditgroup -o checkmember -m "$u" admin >/dev/null 2>&1; }; }; then
            echo "yes $u is a member of $g"; return 0
          fi
          echo "no $u is NOT a member of $g"; return 1 ;;
        *" -o create "*) _e2e_log "dseditgroup $*"; : > "$f"; return 0 ;;
        *" -o edit -a admin -t group "*)
          _e2e_log "dseditgroup $*"; echo "nested $(dsmemberutil getuuid -G admin)" >> "$f"; return 0 ;;
      esac ;;
    esac
  fi
  case " $* " in
    *" checkmember "*) _e2e_next dseditgroup "$@" ;;
    *) _e2e_next_fake dseditgroup "$@" ;;
  esac
}
export -f _e2e_sys _e2e_groups _e2e_wrap _e2e_next _e2e_next_fake launchctl pmset plutil socketfilterfw fdesetup \
  sshd dscl dseditgroup 2>/dev/null
for _e2e_f in launchctl pmset fdesetup dscl dseditgroup; do
  declare -F "_e2e_base_$_e2e_f" >/dev/null && export -f "_e2e_base_$_e2e_f"
done
unset _e2e_f

# --- Unity Hub (Tests/e2e/suites/unity.sh) ---------------------------------------------------------------
# The suite puts an executable "Unity Hub" into $CMCR_APPS_DIR/Unity Hub.app that calls this function (it sees the
# fakes through BASH_ENV). Like the real Hub in headless mode it installs editors into
# $CMCR_APPS_DIR/Unity/Hub/Editor/<version>: an ad-hoc signed Unity.app, modules.json with every module of the release
# (id, parent, selected) and, for the Android parts, sdkmanager, NDK and OpenJDK/bin/java. A module comes with every
# module under it (--childModules). Control files in $CMCR_E2E_WORK: unity-hub.fail (install and install-modules fail,
# nothing installed), unity-hub.rc1 (they install but end with code 1, like Hub's HUBX-520), unity-hub.nomodules (the
# editor without the modules), unity-hub.nochildren (the modules without the ones under them), unity-hub.broken (code 1
# and a Unity.app whose signature no longer matches, like an unpacking that stopped half-way).
_e2e_unity_tree() { # "id:parent" of every module, as in modules.json of Unity 6000.6
  printf '%s\n' android: android-open-jdk-17.0.18+8:android android-sdk-ndk-tools:android \
    android-ndk-r27c:android-sdk-ndk-tools ios: webgl: documentation:
}
_e2e_unity_add() { # DIR MODULE – MODULE and, without unity-hub.nochildren, every module under it
  echo "$2" >> "$1/.e2e-modules"
  [ -e "${CMCR_E2E_WORK:-/nonexistent}/unity-hub.nochildren" ] && return 0
  local c
  for c in $(_e2e_unity_tree | awk -F: -v p="$2" '$2 == p {print $1}'); do _e2e_unity_add "$1" "$c"; done
}
_e2e_unity_write() { # DIR – modules.json as Hub writes it, and the files of the Android parts installed
  local d="$1" a="$1/PlaybackEngines/AndroidPlayer"
  _e2e_unity_tree | awk -F: -v list="$d/.e2e-modules" '
    BEGIN { while ((getline m < list) > 0) have[m] = 1; print "[" }
    { printf "%s  {\"id\": \"%s\", \"parent\": \"%s\", \"selected\": %s, \"eula\": null}", (NR > 1 ? ",\n" : ""), $1, $2,
             ($1 in have) ? "true" : "false" }
    END { print "\n]" }' > "$d/modules.json"
  if grep -qxF android-sdk-ndk-tools "$d/.e2e-modules"; then
    mkdir -p "$a/SDK/cmdline-tools/16.0/bin" "$a/NDK"
    printf '#!/bin/bash\n_e2e_log "sdkmanager $*"\n' > "$a/SDK/cmdline-tools/16.0/bin/sdkmanager"
    chmod +x "$a/SDK/cmdline-tools/16.0/bin/sdkmanager"
  fi
  if grep -qxF android-open-jdk-17.0.18+8 "$d/.e2e-modules"; then
    mkdir -p "$a/OpenJDK/bin"; printf '#!/bin/sh\n' > "$a/OpenJDK/bin/java"; chmod +x "$a/OpenJDK/bin/java"
  fi
}
_e2e_unity_editor() { # DIR – an ad-hoc signed Unity.app, like Hub unpacks it
  mkdir -p "$1/Unity.app/Contents/MacOS" || return 1
  cp /bin/sleep "$1/Unity.app/Contents/MacOS/Unity"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Unity</string>
<key>CFBundleIdentifier</key><string>com.unity3d.UnityEditor5.x</string><key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>\n' > "$1/Unity.app/Contents/Info.plist"
  codesign --force --sign - "$1/Unity.app" >/dev/null 2>&1
}
_e2e_unity_hub() {
  local w="${CMCR_E2E_WORK:-/nonexistent}" ip="${CMCR_APPS_DIR:-/nonexistent}/Unity/Hub/Editor"
  [ "${1:-}" = -- ] && shift
  [ "${1:-}" = --headless ] && shift
  _e2e_log "unity-hub $*"
  local cmd="${1:-}"; shift
  local v="" m="" mods="" d
  while [ $# -gt 0 ]; do
    case "$1" in
      --version|-v) v="$2"; shift 2 ;;
      --changeset|-c|--architecture|-a) shift 2 ;;
      -m|--module) mods="$mods $2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$cmd" in
    install-path|ip) echo "$ip" ;;
    editors|e)
      for d in "$ip"/*/; do [ -x "$d/Unity.app/Contents/MacOS/Unity" ] && echo "$(basename "$d") (atrapa) installed at ${d}Unity.app"; done ;;
    install|i|install-modules|im)
      if [ -e "$w/unity-hub.fail" ]; then
        echo "Failed to execute the command due the following, please see '-- --headless help' for assistance."
        echo "Error: download failed (atrapa)"; return 1
      fi
      d="$ip/$v"
      if [ "$cmd" = install ] || [ "$cmd" = i ]; then
        _e2e_unity_editor "$d" || return 1
        : >> "$d/.e2e-modules"
      elif [ ! -x "$d/Unity.app/Contents/MacOS/Unity" ]; then
        echo "Error: No editor found for version \"$v\"."; return 1
      fi
      [ -e "$w/unity-hub.nomodules" ] || for m in $mods; do _e2e_unity_add "$d" "$m"; done
      _e2e_unity_write "$d"
      if [ -e "$w/unity-hub.broken" ]; then
        echo "<!-- zmienione po podpisaniu -->" >> "$d/Unity.app/Contents/Info.plist"
        echo "Error: extraction failed (atrapa)"; return 1
      fi
      echo "Editor installed successfully (atrapa)."
      [ -e "$w/unity-hub.rc1" ] && return 1
      return 0 ;;
    *) echo "Error: '$cmd' is not a Hub command."; return 1 ;;
  esac
}
