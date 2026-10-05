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
      return 0 ;;
  esac
  local input=""
  if [ ! -t 0 ]; then input="$(cat)"; fi
  case "$input" in
    *"CMCR:ANSWER:"*)
      _e2e_log "ask-dialog"
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
pgrep() {
  case "$(_e2e_pattern "$@")" in
    LockScreen) [ -e "$(_e2e_state lockscreen.running)" ] && { echo 99901; return 0; }; return 1 ;;
    CMCR_ATTENTION)
      [ -e "$(_e2e_state attention.running)" ] && { echo 99902; return 0; }
      command pgrep -U "$(id -u)" -f CMCR_ATTENTION ;;
    cmcr-delayed-power) command pgrep -U "$(id -u)" -f cmcr-delayed-power ;;
    *) command pgrep "$@" ;;
  esac
}
pkill() {
  local p rc=1
  p="$(_e2e_pattern "$@")"
  _e2e_log "pkill $*"
  case "$p" in
    LockScreen) [ -e "$(_e2e_state lockscreen.running)" ] && rc=0; rm -f "$(_e2e_state lockscreen.running)" ;;
    CMCR_ATTENTION)
      [ -e "$(_e2e_state attention.running)" ] && rc=0; rm -f "$(_e2e_state attention.running)"
      command pkill -U "$(id -u)" -f CMCR_ATTENTION && rc=0 ;;
    cmcr-delayed-power) command pkill -U "$(id -u)" -f cmcr-delayed-power && rc=0 ;;
  esac
  return $rc
}

# kill: refuses to signal application processes (…/X.app/Contents/MacOS/…) that do not belong to the test,
# e.g. when "Zamknij wszystkie aplikacje" would otherwise reach the real apps of the user running the tests.
kill() {
  local a cmd args=() pids=0
  for a in "$@"; do
    case "$a" in
      -*|%*) args+=("$a") ;;
      *)
        cmd="$(command ps -p "$a" -o command= 2>/dev/null)"
        case "$cmd" in
          *"${CMCR_E2E_WORK:-/nonexistent-cmcr-e2e}/"*) args+=("$a"); pids=$((pids + 1)) ;;
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

fdesetup() {
  case "${1:-}" in
    isactive) if [ -e "$(_e2e_state filevault.on)" ]; then echo true; return 0; fi; echo false; return 1 ;;
    supportsauthrestart) echo true ;;
    *) _e2e_log "fdesetup $*" ;;
  esac
}
killall() { _e2e_log "killall $*"; return 0; }
dscacheutil() { _e2e_log "dscacheutil $*"; return 0; }
export -f _e2e_state _e2e_launchctl_base launchctl _e2e_pattern pgrep pkill kill ioreg pmset fdesetup killall \
  dscacheutil 2>/dev/null
