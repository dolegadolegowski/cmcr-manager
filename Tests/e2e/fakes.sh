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
        local sflags=""
        while [ $# -gt 0 ]; do
          case "$1" in -u) sflags="$sflags -u $2"; shift 2 ;; --) shift; break ;; -*) sflags="$sflags $1"; shift ;; *) break ;; esac
        done
        _e2e_log "gui-sudo:$sflags (cwd $PWD)"
      fi
      case "${1:-}" in
        /usr/sbin/screencapture|screencapture) shift; screencapture "$@" ;;
        *)
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
osascript() { _e2e_log "osascript $*"; return 0; }
# FileVault state comes from marker files in the test folder: fake-filevault (on, admin can unlock),
# fake-filevault-nouser (on, admin not enabled for FileVault).
fdesetup() {
  local w="${CMCR_E2E_WORK:-/nonexistent}"
  case "${1:-}" in
    isactive)
      if [ -e "$w/fake-filevault" ] || [ -e "$w/fake-filevault-nouser" ]; then echo true; return 0; fi
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
export -f _e2e_log _e2e_fake_png sudo screencapture launchctl shutdown reboot halt pmset softwareupdate installer \
  chown systemsetup scutil dseditgroup visudo spctl defaults brew mas osascript fdesetup stat diskutil dscl \
  createhomedir networksetup 2>/dev/null
