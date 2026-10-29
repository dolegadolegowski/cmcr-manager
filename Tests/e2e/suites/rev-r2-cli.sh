# shellcheck shell=bash
# Review fixes of cmcrctl (AUDIT REV, group R2-cli): Ctrl-C on several Macs and in every command that changes
# something, the warning about a damaged classroom.json and the logout hint. Sourced by Tests/e2e/run.sh (helpers and
# $WORK $CTL $PASSWORD $ME $PORT come from there). Own config folder, so later suites see the original configuration.

R2="$WORK/cfg-rev-r2"
mkdir -p "$R2"
cp "$WORK/config/settings.json" "$R2/"
cat > "$R2/hosts.json" <<EOF
[
 {"id":"a1111111-1111-1111-1111-111111111111","name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"a2222222-2222-2222-2222-222222222222","name":"imac02","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"a5555555-5555-5555-5555-555555555555","name":"imac 05","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"a9999999-9999-9999-9999-999999999999","name":"imac09","address":"imac09.cmcr-e2e.invalid","user":"imac09","port":22}
]
EOF
r2() { CMCR_CONFIG_DIR="$R2" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
# r2_before NAME OUTPUT FIRST SECOND – both lines are there, FIRST above SECOND.
r2_before() {
  local a b
  a="$(printf '%s\n' "$2" | grep -nF -- "$3" | head -n 1 | cut -d: -f1)"
  b="$(printf '%s\n' "$2" | grep -nF -- "$4" | head -n 1 | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then pass "$1"; else fail "$1 („$3” przed „$4”)" "$2"; fi
}
# r2_interrupt CONDITION ARGS… – runs cmcrctl ARGS in its own process group and, once CONDITION (shell code) holds
# (at most 10 s), sends SIGINT to the whole group, as Ctrl-C in a terminal does. Output: $R2_OUT, exit code: $R2_CODE.
r2_interrupt() {
  local cond="$1" pid _
  shift
  set -m
  CMCR_CONFIG_DIR="$R2" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" > "$WORK/rev-r2-int.out" 2>&1 </dev/null &
  pid=$!
  set +m
  for _ in $(seq 1 100); do eval "$cond" && break; sleep 0.1; done
  sleep 0.5
  kill -INT -- "-$pid"
  wait "$pid"; R2_CODE=$?
  R2_OUT="$(cat "$WORK/rev-r2-int.out")"
}

section "REV R2 cmcrctl – przygotowanie"
out="$(r2 list)"
expect "r2: lista komputerów" "$out" "imac01" "imac02" "imac 05" "imac09"

section "REV R2 cmcrctl – logout: podpowiedź --force tylko po odmowie skryptu, pod wynikiem (AUDIT REV-38)"
# A Mac that does not answer: the polite logout never reached it, --force would fail the same way.
out="$(r2 logout 9 --yes)"; code=$?
expect_code "logout, komputer niedostępny: kod 1" "$code" 1 "$out"
expect "logout, komputer niedostępny: przyczyna" "$out" "✘ imac09"
expect_not "logout, komputer niedostępny: bez podpowiedzi --force" "$out" "--force"
# macOS refuses the request (fake-ae-denied): the script itself points to „Wyloguj natychmiast”.
: > "$WORK/fake-ae-denied"
out="$(r2 logout 1 --yes)"; code=$?
expect_code "logout, odmowa macOS: kod 1" "$code" 1 "$out"
expect "logout, odmowa macOS: podpowiedź --force" "$out" "(cmcrctl logout imac01 --force – wylogowanie natychmiastowe"
r2_before "logout, odmowa macOS: podpowiedź pod przyczyną" "$out" "✘ imac01:" "cmcrctl logout imac01 --force"
out="$(r2 logout "imac 05" --yes)"; code=$?
expect "logout, nazwa ze spacją: podpowiedź do skopiowania" "$out" "(cmcrctl logout 'imac 05' --force"
rm -f "$WORK/fake-ae-denied"

section "REV R2 cmcrctl – uszkodzony classroom.json: ostrzeżenie w poleceniach zajęć (AUDIT REV-37)"
printf '{"schedule": {"powerOnEnabled": tr' > "$R2/classroom.json"
clear_fakelog
out="$(r2 schedule set 1)"; code=$?
expect "schedule set: ostrzeżenie o uszkodzonym classroom.json" "$out" \
  "⚠ Plik ustawień zajęć (classroom.json) jest uszkodzony – przywrócono ustawienia domyślne"
r2_before "schedule set: ostrzeżenie przed wynikiem" "$out" "⚠ Plik ustawień zajęć" "imac01:"
out="$(r2 ask "Pytanie R2" 1)"; code=$?
expect "ask: ostrzeżenie o uszkodzonym classroom.json" "$out" "⚠ Plik ustawień zajęć (classroom.json) jest uszkodzony"
expect "ask: czas domyślny (2 min)" "$out" "Czas na odpowiedź: 2 min"
out="$(r2 lesson start 1)"; code=$?
expect "lesson: ostrzeżenie o uszkodzonym classroom.json" "$out" "⚠ Plik ustawień zajęć (classroom.json) jest uszkodzony"
# Commands that do not use classroom.json do not read it: no warning, no backup copy.
rm -f "$R2"/classroom.json.*.bak
out="$(r2 list)"
expect_not "list: bez ostrzeżenia o classroom.json" "$out" "ustawień zajęć"
if ls "$R2"/classroom.json.*.bak >/dev/null 2>&1; then fail "list: kopia classroom.json mimo że go nie czyta" "$(ls "$R2")"
else pass "list: classroom.json nieczytany (bez kopii .bak)"; fi
# A good classroom.json: no warning.
rm -f "$R2/classroom.json"
out="$(r2 ask "Pytanie R2" 1 --buttons "Tak,Nie")"
expect_not "ask, poprawne ustawienia: bez ostrzeżenia" "$out" "⚠"

section "REV R2 cmcrctl – Ctrl-C przy kilku komputerach: wynik każdego z nich (AUDIT REV-35)"
# Two Macs at once (-j 2): the second one's output waits for the first, and must not be lost when cmcrctl ends.
R2S="$WORK/rev-r2-started"
R2M="$WORK/rev-r2-mark"
rm -f "$R2S" "$R2M"
r2_interrupt '[ "$(grep -c x "$R2S" 2>/dev/null)" = 2 ]' \
  exec "echo x >> '$R2S'; sleep 4; echo zrobione >> '$R2M'" 1,2 -j 2 --prefix
expect_code "-j 2, Ctrl-C: kod 130" "$R2_CODE" 130 "$R2_OUT"
expect "-j 2, Ctrl-C: polecenie zatrzymane na obu komputerach" "$R2_OUT" \
  "[imac01] ▸ Zatrzymano polecenie na komputerze." "[imac02] ▸ Zatrzymano polecenie na komputerze."
expect "-j 2, Ctrl-C: wynik każdego komputera" "$R2_OUT" "[imac01] ✘ imac01: Anulowano." "[imac02] ✘ imac02: Anulowano."
r2_before "-j 2, Ctrl-C: wyniki w kolejności listy" "$R2_OUT" "[imac01] ✘ imac01" "[imac02] Running command"
sleep 4
[ ! -e "$R2M" ] && pass "-j 2, Ctrl-C: polecenie nie dokończyło się na żadnym komputerze" \
  || fail "-j 2, Ctrl-C: polecenie dokończyło się mimo przerwania" "$(cat "$R2M"; echo; echo "$R2_OUT")"
# One Mac at a time: after Ctrl-C the next Mac does not start, and the output says so.
rm -f "$R2S" "$R2M"
r2_interrupt 'grep -q x "$R2S" 2>/dev/null' exec "echo x >> '$R2S'; sleep 4; echo zrobione >> '$R2M'" 1,2 --prefix
expect_code "-j 1, Ctrl-C: kod 130" "$R2_CODE" 130 "$R2_OUT"
expect "-j 1, Ctrl-C: zatrzymane na pierwszym komputerze" "$R2_OUT" "[imac01] ▸ Zatrzymano polecenie na komputerze."
expect "-j 1, Ctrl-C: komputer, na którym nic nie uruchomiono" "$R2_OUT" \
  "▸ Nie uruchomiono polecenia na 1 komputerze: imac02."
expect_not "-j 1, Ctrl-C: drugi komputer nie zaczął" "$R2_OUT" "[imac02]"
sleep 4
[ "$(grep -c x "$R2S" 2>/dev/null)" = 1 ] && [ ! -e "$R2M" ] && pass "-j 1, Ctrl-C: nic więcej nie uruchomiono" \
  || fail "-j 1, Ctrl-C: polecenie działało dalej" "$(cat "$R2S" "$R2M" 2>&1; echo "$R2_OUT")"

section "REV R2 cmcrctl – Ctrl-C zatrzymuje na iMacach każde polecenie, które coś zmienia (AUDIT REV-36)"
# Each command waits on the iMac in a fake (slow.NAME, see fakes.sh) and is interrupted there: the step after the
# pause must never happen, and cmcrctl reports the stop.
r2_slow_stop() { # r2_slow_stop LABEL FAKE ARGS…
  local label="$1" fake="$2"
  shift 2
  echo 4 > "$WORK/slow.$fake"
  clear_fakelog
  r2_interrupt "fakelog | grep -q '$fake: pauza'" "$@"
  cp "$WORK/rev-r2-int.out" "$WORK/rev-r2-int-$fake.out"
  expect_code "$label, Ctrl-C: kod 130" "$R2_CODE" 130 "$R2_OUT"
  expect "$label, Ctrl-C: polecenie zatrzymane na komputerze" "$R2_OUT" "Przerywanie" "▸ Zatrzymano polecenie na komputerze."
  sleep 5
  rm -f "$WORK/slow.$fake"
  expect_not "$label, Ctrl-C: polecenie nie dokończyło się na iMacu" "$(fakelog)" "$fake: po pauzie"
}
mkdir -p "$WORK/rev-r2-pkgroot/x"
echo x > "$WORK/rev-r2-pkgroot/x/plik.txt"
if pkgbuild --quiet --root "$WORK/rev-r2-pkgroot" --identifier pl.cmcr.e2e.r2 --version 1.0 \
    --install-location /tmp/cmcr-e2e-never "$WORK/rev-r2.pkg" >/dev/null 2>&1; then
  r2_slow_stop "install" installer install "$WORK/rev-r2.pkg" 1 --allow-unsigned
  expect_not "install, Ctrl-C: installer nie uruchomiony" "$(fakelog)" "installer -pkg"
else
  echo "  (pkgbuild niedostępny – pominięto install)"
fi
python3 - "$R2/classroom.json" <<'PY'
import json, sys
json.dump({"end": {"warn": False, "collect": False, "quitApps": False, "cleanShared": False, "cleanDownloads": False,
                   "logout": True, "power": "none"}}, open(sys.argv[1], "w"))
PY
r2_slow_stop "lesson end" launchctl-bootout lesson end 1 --yes
rm -f "$R2/classroom.json"
r2_slow_stop "ask" ask-dialog ask "Pytanie R2" 1 --timeout 30
r2_slow_stop "rename-computer" scutil rename-computer 1,2 --yes
expect "rename-computer, Ctrl-C: drugi komputer bez zmian" "$R2_OUT" "▸ Nie uruchomiono polecenia na 1 komputerze: imac02."
expect_not "rename-computer, Ctrl-C: scutil nie zmienił nazwy" "$(fakelog)" "scutil --set"
