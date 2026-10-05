#!/bin/bash
# End-to-end tests: runs cmcrctl against a throw-away, user-mode sshd on 127.0.0.1 whose sessions load
# Tests/e2e/fakes.sh (fake sudo/launchctl/shutdown/…). Exercises the real ssh/scp transport, the
# RemoteScript wrapper (password via stdin, askpass, root re-exec) and the remote bash builders without
# root privileges and without touching this Mac's system state.
#
#   Tests/e2e/run.sh            – build (debug) and run all tests
#   CMCR_E2E_NOBUILD=1 …        – reuse the existing build
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${CMCR_E2E_PORT:-2299}"
WORK="$(mktemp -d /tmp/cmcr-e2e.XXXXXX)"
PASS=0
FAIL=0
SSHD_PID=""

cleanup() {
  [ -n "$SSHD_PID" ] && kill "$SSHD_PID" 2>/dev/null
  case "${CMCR_KEYCHAIN_SERVICE:-}" in
    pl.cmcr.manager.e2e-*) while security delete-generic-password -s "$CMCR_KEYCHAIN_SERVICE" >/dev/null 2>&1; do :; done ;;
  esac
  if [ "${CMCR_E2E_KEEP:-0}" = 1 ]; then echo "Zachowano: $WORK"; return; fi
  pkill -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1)); printf '  \033[31m✘ %s\033[0m\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | head -n 25 | sed 's/^/      │ /'
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
# check NAME CONDITION-RESULT OUTPUT
contains() { case "$2" in *"$3"*) return 0 ;; esac; return 1; }
expect() { # expect "name" "$output" "needle" ["needle2"…]
  local name="$1" out="$2"; shift 2
  local n
  for n in "$@"; do
    if ! contains "" "$out" "$n"; then fail "$name (brak: $n)" "$out"; return; fi
  done
  pass "$name"
}
expect_not() { # expect_not "name" "$output" "needle"
  if contains "" "$2" "$3"; then fail "$1 (nieoczekiwane: $3)" "$2"; else pass "$1"; fi
}
expect_code() { # expect_code "name" actual expected output
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (kod $2, oczekiwano $3)" "${4:-}"; fi
}
fakelog() { cat "$WORK/fake.log" 2>/dev/null; }
clear_fakelog() { : > "$WORK/fake.log"; }

# ---------------------------------------------------------------- build
if [ "${CMCR_E2E_NOBUILD:-0}" != 1 ]; then
  echo "• Kompilacja…"
  (cd "$ROOT" && swift build >/dev/null 2>&1) || { (cd "$ROOT" && swift build 2>&1 | tail -30); exit 1; }
fi
BIN="$(cd "$ROOT" && swift build --show-bin-path 2>/dev/null)"
CTL="$BIN/cmcrctl"
[ -x "$CTL" ] || { echo "Brak $CTL"; exit 1; }

# ---------------------------------------------------------------- environment
ME="$(id -un)"
# Deliberately awkward: spaces, quotes, $ and non-ASCII must survive stdin → askpass → sudo.
PASSWORD="e2e Hasło 'z' \$dolarem"
mkdir -p "$WORK/config" "$WORK/remote/Public/cmcr" "$WORK/local" "$WORK/Applications" "$WORK/in"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/hostkey"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/client" -C cmcr-e2e
cp "$WORK/client.pub" "$WORK/authorized_keys"
chmod 600 "$WORK/authorized_keys"
cat > "$WORK/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $WORK/hostkey
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
Subsystem sftp /usr/libexec/sftp-server
# As macOS ships it (sshd_config.d/100-macos.conf): a client's LANG/LC_* (ssh SendEnv) reach the scripts.
AcceptEnv LANG LC_*
EOF
# sshd honours only the first SetEnv line, so all variables go into one.
printf 'SetEnv BASH_ENV=%s CMCR_E2E_LOG=%s CMCR_APPS_DIR=%s CMCR_E2E_WORK=%s CMCR_E2E_PASSWORD="%s"\n' \
  "$ROOT/Tests/e2e/fakes.sh" "$WORK/fake.log" "$WORK/Applications" "$WORK" "$PASSWORD" >> "$WORK/sshd_config"
/usr/sbin/sshd -D -e -f "$WORK/sshd_config" 2>"$WORK/sshd.log" &
SSHD_PID=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
nc -z 127.0.0.1 "$PORT" 2>/dev/null || { echo "sshd nie wystartował:"; cat "$WORK/sshd.log"; exit 1; }

cat > "$WORK/config/hosts.json" <<EOF
[
 {"id":"11111111-1111-1111-1111-111111111111","name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"99999999-9999-9999-9999-999999999999","name":"imac99","address":"imac99.cmcr-e2e.invalid","user":"imac99","port":22}
]
EOF
cat > "$WORK/config/settings.json" <<EOF
{"identityFile":"$WORK/client","extraSSHOptions":"UserKnownHostsFile=$WORK/known_hosts","sharedFolder":"$WORK/remote/Public/cmcr",
 "localFolder":"$WORK/local","studentUser":"$ME","connectTimeout":3,"observeOnlyStandardAccounts":false,"notifyOnObserve":true,
 "screenshotMaxSize":640}
EOF
export CMCR_CONFIG_DIR="$WORK/config"
# A throw-away Keychain service: cmcrctl must never read or change the app's own pl.cmcr.manager items here.
export CMCR_KEYCHAIN_SERVICE="pl.cmcr.manager.e2e-$$"
# Shared ssh connections of this run only (a master left from an earlier run would still talk to that
# run's sshd); the cleanup's pkill finds them by this path.
export CMCR_SSH_CONTROL_DIR="$WORK/mux"
unset CMCR_PASSWORD
ctl() { "$CTL" "$@" 2>&1; }
ctlpw() { CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }

# ---------------------------------------------------------------- safety guard
# Every remote bash must see the fake sudo. If not, stop before anything could reach the real sudo.
guard_out="$("$CTL" exec 'type sudo launchctl shutdown pmset softwareupdate installer 2>&1 | grep -c "is a function"' 1 2>&1)"
guard="$(printf '%s\n' "$guard_out" | tail -1)"
if [ "$guard" != 6 ]; then
  echo "PRZERWANO: atrapy (fakes.sh) nie są aktywne w zdalnej sesji – testy mogłyby wywołać prawdziwe sudo."
  echo "$guard_out"
  exit 2
fi
guard_root="$(CMCR_PASSWORD="$PASSWORD" "$CTL" exec 'type sudo launchctl shutdown 2>&1 | grep -c "is a function"' 1 --root 2>&1 | tail -1)"
if [ "$guard_root" != 3 ]; then
  echo "PRZERWANO: atrapy nie są aktywne w trybie root."
  echo "$guard_root"
  exit 2
fi

# ---------------------------------------------------------------- tests
section "Połączenie i stan"
out="$(ctl status 1)"; expect "status: komputer online" "$out" "● imac01" "macOS"
out="$(ctl status 99)"; code=$?
expect "status: nieistniejący host – czytelny błąd" "$out" "Nie można odnaleźć nazwy hosta"
expect_code "status: kod błędu dla offline" "$code" 1 "$out"

section "Polecenia (cmcr-exec)"
out="$(ctl exec 'echo "zażółć gęślą jaźń"; echo "konsola=$CONSOLE_USER admin=$CMCR_ADMIN_USER"' 1)"
expect "exec: UTF-8 i zmienne biblioteki" "$out" "zażółć gęślą jaźń" "konsola=$ME" "admin=$ME"
out="$(ctl exec "printf '%s|' \"a'b\" '\$HOME' \"\$(echo sub)\"" 1)"
expect "exec: cudzysłowy, dolary i podstawienia" "$out" "a'b|\$HOME|sub|"
out="$(ctl exec 'exit 7' 1)"; code=$?
expect_code "exec: kod wyjścia przekazany" "$code" 7 "$out"
out="$(ctl exec 'ls -d "$CMCR_TMP" && echo ok' 1)"
expect "exec: prywatny katalog tymczasowy" "$out" "/tmp/cmcr." "ok"
# Checks this run's directory only: other test runs on the same Mac may be creating their own right now.
tmpdir="$(printf '%s\n' "$out" | grep -o '/tmp/cmcr\.[A-Za-z0-9]*' | head -n 1)"
[ -n "$tmpdir" ] && [ ! -e "$tmpdir" ] && pass "exec: katalog tymczasowy usunięty po zakończeniu" \
  || fail "exec: został katalog tymczasowy ${tmpdir:-?}" "$(ls -la "$tmpdir" 2>&1)"

section "Uprawnienia administratora (sudo przez askpass)"
clear_fakelog
out="$(ctlpw exec 'echo "uid-root-body PW=${#CMCR_PW}"; asroot echo zagniezdzone' 1 --root)"; code=$?
expect "root: poprawne hasło – ciało skryptu wykonane" "$out" "uid-root-body PW=${#PASSWORD}" "zagniezdzone"
expect_code "root: kod 0" "$code" 0 "$out"
out="$(CMCR_PASSWORD="zle-haslo" "$CTL" exec 'echo nie-powinno' 1 --root 2>&1)"; code=$?
expect "root: błędne hasło – komunikat" "$out" "Błędne hasło administratora"
expect_not "root: błędne hasło – ciało nie wykonane" "$out" "nie-powinno"
out="$(ctl exec 'echo nie-powinno' 1 --root)"; code=$?
expect "root: brak hasła – komunikat bez prób sudo" "$out" "Brak zapisanego hasła administratora"
expect_code "root: brak hasła – kod 91" "$code" 91 "$out"
expect_not "root: brak hasła – brak wywołań sudo" "$(fakelog)" "Sorry"
out="$(ctlpw exec 'asroot id -un' 1)"
expect "asroot w trybie użytkownika" "$out" "$ME"

section "Pliki (cmcr-push / cmcr-pull)"
mkdir -p "$WORK/local/all/folder z spacją" "$WORK/local/127.0.0.1"
echo "wspólny" > "$WORK/local/all/folder z spacją/plik ą.txt"
echo "dla hosta" > "$WORK/local/127.0.0.1/host.txt"
ln -sf host.txt "$WORK/local/127.0.0.1/link.txt"
clear_fakelog
out="$(ctlpw push 1 --root)"; code=$?
expect_code "push: kod 0" "$code" 0 "$out"
[ -f "$WORK/remote/Public/cmcr/folder z spacją/plik ą.txt" ] && [ -f "$WORK/remote/Public/cmcr/host.txt" ] \
  && pass "push: pliki z folderu all i hosta dotarły" || fail "push: brak plików" "$(ls -laR "$WORK/remote" 2>&1)"
[ -L "$WORK/remote/Public/cmcr/link.txt" ] && pass "push: dowiązanie zachowane" || fail "push: dowiązanie" "$(ls -la "$WORK/remote/Public/cmcr")"
expect "push: zmiana właściciela na konto ucznia" "$(fakelog)" "chown -R $ME"
perm="$(stat -f %Lp "$WORK/remote/Public/cmcr/host.txt") $(stat -f %Lp "$WORK/remote/Public/cmcr/folder z spacją")"
[ "$perm" = "666 777" ] && pass "push: 777 jak w cmcr-push (foldery 777, pliki 666 – bez prawa wykonywania)" || fail "push: uprawnienia $perm"
echo "praca ucznia" > "$WORK/remote/Public/cmcr/praca.txt"
rm -rf "$WORK/local/127.0.0.1"
out="$(ctl pull 1)"; code=$?
expect_code "pull: kod 0" "$code" 0 "$out"
[ -f "$WORK/local/127.0.0.1/praca.txt" ] && [ -f "$WORK/local/127.0.0.1/folder z spacją/plik ą.txt" ] \
  && pass "pull: prace pobrane do folderu hosta" || fail "pull: brak plików" "$(ls -laR "$WORK/local" 2>&1)"

section "Aplikacje"
mkdir -p "$WORK/CMCRDummy.app/Contents/MacOS"
cp /bin/sleep "$WORK/CMCRDummy.app/Contents/MacOS/CMCRDummy"
codesign --force --sign - "$WORK/CMCRDummy.app/Contents/MacOS/CMCRDummy" >/dev/null 2>&1
"$WORK/CMCRDummy.app/Contents/MacOS/CMCRDummy" 300 &
DUMMY=$!
sleep 0.5
out="$(ctl apps 1)"
expect "apps: uruchomiona aplikacja widoczna" "$out" "CMCRDummy.app" "Użytkownik: $ME"
clear_fakelog
out="$(ctlpw quit-app CMCRDummy 1)"
sleep 0.5
if kill -0 "$DUMMY" 2>/dev/null; then fail "quit-app: proces nadal działa" "$out"; kill "$DUMMY"; else pass "quit-app: aplikacja zamknięta (SIGTERM)"; fi
out="$(ctl quit-app CMCRDummy 1)"
expect "quit-app: nieuruchomiona aplikacja" "$out" "nie jest uruchomiona"
clear_fakelog
out="$(ctlpw open-app "Kalkulator Test" 1)"
expect "open-app: komunikat" "$out" "Uruchomiono"
expect "open-app: open -a w sesji użytkownika" "$(fakelog)" "gui-exec: /usr/bin/open -a Kalkulator Test"

section "Podgląd ekranu"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/shot.jpg")"; code=$?
expect_code "screenshot: kod 0" "$code" 0 "$out"
if file "$WORK/shot.jpg" 2>/dev/null | grep -q JPEG; then pass "screenshot: obraz JPEG"; else fail "screenshot: brak JPEG" "$out"; fi
expect "screenshot: powiadomienie użytkownika o podglądzie" "$(fakelog)" "observe-notice:"
python3 - "$WORK/config/settings.json" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["observeAllowedUsers"]="ktos-inny"; json.dump(s,open(p,"w"))
PY
out="$(ctlpw screenshot 1 "$WORK/shot2.jpg")"; code=$?
expect "screenshot: konto spoza listy dozwolonych zablokowane" "$out" "nie jest na liście kont dozwolonych"
[ ! -f "$WORK/shot2.jpg" ] && pass "screenshot: brak obrazu przy blokadzie" || fail "screenshot: obraz mimo blokady"
python3 - "$WORK/config/settings.json" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["observeAllowedUsers"]=""; s["observeOnlyStandardAccounts"]=True; json.dump(s,open(p,"w"))
PY
if dseditgroup -o checkmember -m "$ME" admin >/dev/null 2>&1; then
  out="$(ctlpw screenshot 1 "$WORK/shot3.jpg")"
  expect "screenshot: konto administratora zablokowane (tylko konta standardowe)" "$out" "podgląd zablokowany"
fi

section "Skrypty – składnia wszystkich generatorów"
if out="$("$CTL" selftest 2>&1)"; then pass "selftest: wszystkie skrypty przechodzą bash -n"; else
  case "$out" in *"Użycie"*|*"cmcrctl –"*) echo "  (cmcrctl selftest niedostępny – pominięto)";; *) fail "selftest" "$out";; esac
fi

# Optional extra suites (added by feature work): Tests/e2e/suites/*.sh, sourced with the helpers above.
for suite in "$ROOT"/Tests/e2e/suites/*.sh; do
  [ -e "$suite" ] || continue
  # shellcheck disable=SC1090
  . "$suite"
done

printf '\n\033[1mWynik: %d zaliczonych, %d niezaliczonych\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
