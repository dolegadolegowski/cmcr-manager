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

# screencapture: writes a fake image per output file (format from -t). Control files in $CMCR_E2E_WORK:
# displays (number of displays, default 1), screencapture_fail (no Screen Recording permission),
# screen_variant (a different picture, to test change detection).
screencapture() {
  local fmt=png i=0 n f src
  local -a files=()
  _e2e_log "screencapture $*"
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) fmt="$2"; shift 2 ;;
      -D|-R|-T|-l) shift 2 ;;
      -*) shift ;;
      *) files[${#files[@]}]="$1"; shift ;;
    esac
  done
  if [ -e "${CMCR_E2E_WORK:-/nonexistent}/screencapture_fail" ]; then
    echo "could not create image from display" >&2; return 1
  fi
  n="$(cat "${CMCR_E2E_WORK:-/nonexistent}/displays" 2>/dev/null || echo 1)"
  src=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns
  [ -e "${CMCR_E2E_WORK:-/nonexistent}/screen_variant" ] && src=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFolderIcon.icns
  for f in "${files[@]}"; do
    i=$((i + 1)); [ "$i" -le "$n" ] || break
    case "$fmt" in
      jpg|jpeg) sips -s format jpeg "$src" --out "$f" >/dev/null 2>&1 ;;
      *) sips -s format png "$src" --out "$f" >/dev/null 2>&1 ;;
    esac
  done
}

# Observation notice of the screen preview (Scripts.observeNoticeJXA, tag CMCR_OBSERVE_NOTICE): answers like
# the real panel. Control files in $CMCR_E2E_WORK: fake-notify-fail (osascript fails, e.g. no access to the
# GUI session), fake-notify-hidden (the panel is not on screen), fake-notify-silent (no answer at all).
_e2e_notice() {
  local w="${CMCR_E2E_WORK:-/nonexistent}"
  _e2e_log "observe-notice: $1"
  if [ -e "$w/fake-notify-fail" ]; then
    echo "execution error: Error: Connection to the window server refused (-2700)" >&2; return 1
  fi
  if [ -e "$w/fake-notify-hidden" ]; then echo "CMCR:NOTICE:hidden"; return 0; fi
  if [ -e "$w/fake-notify-silent" ]; then sleep 10; return 0; fi
  echo "CMCR:NOTICE:shown"
}
_e2e_is_notice() { case " $* " in *" CMCR_OBSERVE_NOTICE "*) return 0 ;; esac; return 1; }

# launchctl: `asuser UID cmd…` runs cmd "in the GUI session" – here: logs it and executes only safe tools.
launchctl() {
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
      case "${1:-}" in
        /usr/sbin/screencapture|screencapture) shift; screencapture "$@" ;;
        /usr/bin/lsappinfo|lsappinfo) shift; lsappinfo "$@" ;;
        *)
          if [ "${1:-}" = /usr/bin/osascript ] && _e2e_is_notice "$@"; then _e2e_notice gui; return; fi
          local input=""
          if [ ! -t 0 ]; then input="$(cat)"; fi
          _e2e_log "gui-exec: $*"
          [ -n "$input" ] && _e2e_log "gui-stdin: $input"
          # fake-ae-denied: Apple Events refused (Automation/TCC), as the scripts' `on error` handler logs it.
          if [ "${1:-}" = /usr/bin/osascript ] && [ -e "${CMCR_E2E_WORK:-/nonexistent}/fake-ae-denied" ]; then
            echo "CMCR_AE_ERR -1743 Not authorized to send Apple events to the application." >&2
          fi
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
osascript() {
  if _e2e_is_notice "$@"; then _e2e_notice own; return; fi
  _e2e_log "osascript $*"; return 0
}
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
  command stat "$@"
}
# fake-no-volume-owner: the current user is listed as a crypto user that is not a volume owner.
diskutil() {
  if [ "${1:-} ${2:-}" = "apfs listUsers" ] && [ -e "${CMCR_E2E_WORK:-/nonexistent}/fake-no-volume-owner" ]; then
    local g; g="$(command dscl . -read "/Users/$(id -un)" GeneratedUID | awk '{print $2}')"
    printf 'Cryptographic users for disk3s1s1 (2 found)\n|\n+-- %s\n|   Type: Local Open Directory User\n|   Volume Owner: No\n|\n+-- EBC6C064-0000-11AA-AA11-00306543ECAC\n    Type: Personal Recovery User\n    Volume Owner: Yes\n' "$g"
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
export -f _e2e_log _e2e_fake_png _e2e_notice _e2e_is_notice sudo screencapture launchctl shutdown reboot halt pmset softwareupdate installer \
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
  local p rc=1 sig="" pids
  p="$(_e2e_pattern "$@")"
  _e2e_log "pkill $*"
  case "$p" in
    LockScreen) [ -e "$(_e2e_state lockscreen.running)" ] && rc=0; rm -f "$(_e2e_state lockscreen.running)" ;;
    CMCR_ATTENTION)
      [ -e "$(_e2e_state attention.running)" ] && rc=0; rm -f "$(_e2e_state attention.running)"
      command pkill -U "$(id -u)" -f CMCR_ATTENTION && rc=0 ;;
    cmcr-delayed-power) command pkill -U "$(id -u)" -f cmcr-delayed-power && rc=0 ;;
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
for _e2e_f in launchctl pmset osascript fdesetup dscl dseditgroup; do _e2e_wrap "$_e2e_f"; done
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
export -f _e2e_sys _e2e_groups _e2e_wrap _e2e_next _e2e_next_fake launchctl pmset osascript socketfilterfw fdesetup \
  sshd dscl dseditgroup 2>/dev/null
for _e2e_f in launchctl pmset osascript fdesetup dscl dseditgroup; do
  declare -F "_e2e_base_$_e2e_f" >/dev/null && export -f "_e2e_base_$_e2e_f"
done
unset _e2e_f

# lsappinfo: a fixed frontmost application ($CMCR_E2E_WORK/front_app overrides its name).
lsappinfo() {
  _e2e_log "lsappinfo $*"
  case "${1:-}" in
    front) echo "ASN:0x0-0xe2e0e2:" ;;
    info) printf '"%s" ASN:0x0-0xe2e0e2: (in front) \n    bundleID=[ NULL ] \n' \
            "$(cat "${CMCR_E2E_WORK:-/nonexistent}/front_app" 2>/dev/null || echo 'Przeglądarka Testowa')" ;;
  esac
}
export -f lsappinfo 2>/dev/null
