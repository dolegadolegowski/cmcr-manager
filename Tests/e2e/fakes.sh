# Fakes for privileged or disruptive macOS commands used by the end-to-end tests.
# Loaded through BASH_ENV by the test sshd (see run.sh), so every remote `bash` – including the
# root re-exec – sees these functions instead of the real tools. Nothing here needs or uses root.

CMCR_E2E_LOG="${CMCR_E2E_LOG:-/tmp/cmcr-e2e.log}"
_e2e_log() { printf '%s\n' "$*" >> "$CMCR_E2E_LOG"; }

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

_e2e_fake_png() {
  sips -s format png "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns" \
    --out "$1" >/dev/null 2>&1
}

screencapture() {
  local out=""
  for a in "$@"; do out="$a"; done
  _e2e_log "screencapture $*"
  _e2e_fake_png "$out"
}

# launchctl: `asuser UID cmd…` runs cmd "in the GUI session" – here: logs it and executes only safe tools.
launchctl() {
  case "${1:-}" in
    asuser)
      shift 2
      if [ "${1:-}" = sudo ]; then
        shift
        while [ $# -gt 0 ]; do
          case "$1" in -u) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac
        done
      fi
      case "${1:-}" in
        /usr/sbin/screencapture|screencapture) shift; screencapture "$@" ;;
        *)
          local input=""
          if [ ! -t 0 ]; then input="$(cat)"; fi
          _e2e_log "gui-exec: $*"
          [ -n "$input" ] && _e2e_log "gui-stdin: $input"
          return 0 ;;
      esac ;;
    print) _e2e_log "launchctl $*"; return 0 ;;
    bootout|bootstrap|enable|disable|kickstart|load|unload) _e2e_log "launchctl $*"; return 0 ;;
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

softwareupdate() {
  _e2e_log "softwareupdate $*"
  case " $* " in
    *" --list "*|*" -l "*)
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
      if [ "$pw" = "${CMCR_E2E_PASSWORD:-}" ]; then _e2e_log "softwareupdate stdinpass ok"; echo "Installing (fake)…"; echo "Done."
      else echo "Authentication failed" >&2; return 1; fi ;;
    *" --history "*) echo "Display Name   Version   Date"; echo "macOS Testowy  99.0      01.01.2026" ;;
    *) echo "Done (fake)." ;;
  esac
}

installer() {
  _e2e_log "installer $*"
  local pkg=""
  while [ $# -gt 0 ]; do case "$1" in -pkg) pkg="$2"; shift 2 ;; *) shift ;; esac; done
  [ -e "$pkg" ] || { echo "installer: Error - the package path specified was invalid: '$pkg'." >&2; return 1; }
  echo "installer: The install was successful."
}

chown() { _e2e_log "chown $*"; return 0; }
systemsetup() { _e2e_log "systemsetup $*"; echo "Remote Login: On"; }
scutil() {
  case "${1:-}" in
    --set) _e2e_log "scutil $*" ;;
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
spctl() { _e2e_log "spctl $*"; return 0; }
defaults() {
  case " $* " in
    *" write "*|*" delete "*) _e2e_log "defaults $*"; return 0 ;;
    *) command defaults "$@" ;;
  esac
}
brew() { _e2e_log "brew $*"; echo "brew (fake) $*"; }
mas() { _e2e_log "mas $*"; echo "mas (fake) $*"; }
export -f _e2e_log _e2e_fake_png sudo screencapture launchctl shutdown reboot halt pmset softwareupdate installer \
  chown systemsetup scutil dseditgroup visudo spctl defaults brew mas 2>/dev/null

# --- One-time setup script and readiness check (Tests/e2e/suites/setup.sh) ----------------------------
# setup/cmcr-imac-setup.sh and Scripts.readiness put every system file and home folder they touch under
# CMCR_SETUP_ROOT_PREFIX. While the setup suite runs it creates $CMCR_E2E_WORK/setup-sys, which switches
# the fakes below to a small simulated system state (launchd services, pmset, firewall, FileVault,
# screen-capture permission); otherwise they behave like the fakes above or pass read-only calls through.
[ -n "${CMCR_E2E_WORK:-}" ] && export CMCR_SETUP_ROOT_PREFIX="$CMCR_E2E_WORK/setup-root"
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
for _e2e_f in launchctl pmset osascript fdesetup dscl; do _e2e_wrap "$_e2e_f"; done
unset _e2e_f

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

pmset() {
  : e2e-setup-wrapper
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
        { grep -v "^${2:-} " "$st/pmset" 2>/dev/null; echo "${2:-} ${3:-}"; } > "$st/pmset.new"
        mv "$st/pmset.new" "$st/pmset" ;;
      "repeat cancel") rm -f "$st/sched" ;;
      "repeat "*) shift; echo "$*" > "$st/sched" ;;
    esac
    return 0
  fi
  _e2e_next_fake pmset "$@"
}

osascript() {
  : e2e-setup-wrapper
  if _e2e_sys; then
    case "$*" in
      *CGPreflightScreenCaptureAccess*)
        _e2e_log "osascript: screen-capture preflight"
        cat "$CMCR_E2E_WORK/setup-sys/screen-preflight" 2>/dev/null || echo false
        return 0 ;;
    esac
  fi
  _e2e_next osascript "$@"
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
  case " $* " in
    *" -create "*|*" -change "*|*" -append "*|*" -delete "*|*" -merge "*|*" -passwd "*|*" -createpl "*|*" -deletepl "*)
      _e2e_log "dscl $*"; return 0 ;;
  esac
  _e2e_next dscl "$@"
}
export -f _e2e_sys _e2e_wrap _e2e_next _e2e_next_fake launchctl pmset osascript socketfilterfw fdesetup sshd \
  dscl 2>/dev/null
for _e2e_f in launchctl pmset osascript fdesetup dscl; do
  declare -F "_e2e_base_$_e2e_f" >/dev/null && export -f "_e2e_base_$_e2e_f"
done
unset _e2e_f
