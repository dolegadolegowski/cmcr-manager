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
        /usr/bin/lsappinfo|lsappinfo) shift; lsappinfo "$@" ;;
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

# Console user override for screen-preview tests: $CMCR_E2E_WORK/console_user replaces the owner of
# /dev/console (e.g. "daemon" for a student session that needs root, "root" for the login window).
stat() {
  if [ "$*" = "-f%Su /dev/console" ] && [ -s "${CMCR_E2E_WORK:-/nonexistent}/console_user" ]; then
    cat "$CMCR_E2E_WORK/console_user"; return 0
  fi
  command stat "$@"
}
# lsappinfo: a fixed frontmost application ($CMCR_E2E_WORK/front_app overrides its name).
lsappinfo() {
  _e2e_log "lsappinfo $*"
  case "${1:-}" in
    front) echo "ASN:0x0-0xe2e0e2:" ;;
    info) printf '"%s" ASN:0x0-0xe2e0e2: (in front) \n    bundleID=[ NULL ] \n' \
            "$(cat "${CMCR_E2E_WORK:-/nonexistent}/front_app" 2>/dev/null || echo 'Przeglądarka Testowa')" ;;
  esac
}
osascript() { _e2e_log "osascript $*"; return 0; }
export -f stat lsappinfo osascript 2>/dev/null
