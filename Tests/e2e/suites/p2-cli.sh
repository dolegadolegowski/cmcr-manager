# shellcheck shell=bash
# P2 fixes of cmcrctl (AUDIT P2, package cli): per-command help, confirmations, host lists, logging and texts.
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT come from there). Own config folders,
# so later suites see the original configuration.

P2="$WORK/cfg-p2cli"
mkdir -p "$P2"
cp "$WORK/config/settings.json" "$P2/"
cat > "$P2/hosts.json" <<EOF
[
 {"id":"21111111-1111-1111-1111-111111111111","name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"22222222-2222-2222-2222-222222222222","name":"imac02","address":"127.0.0.1","user":"$ME","port":$PORT}
]
EOF
p2() { CMCR_CONFIG_DIR="$P2" "$CTL" "$@" 2>&1; }
p2pw() { CMCR_CONFIG_DIR="$P2" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
# At a terminal (stdin, stdout and stderr on a pty), answering $P2_ANSWER after the question.
# (Typed after the question: what script(1) passes on before the program reads is lost.)
p2_tty() {
  (sleep 1; printf '%s\n' "${P2_ANSWER:-n}"; sleep 2) | CMCR_CONFIG_DIR="$P2" CMCR_PASSWORD="$PASSWORD" \
    script -q /dev/null "$CTL" "$@" 2>&1
}

section "P2 cmcrctl – przygotowanie"
out="$(p2 list)"
expect "p2: lista komputerów" "$out" "imac01" "imac02"
# Screen preview of the SSH account's own session, with nobody else to notify (see screens.sh).
python3 - "$P2/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s.update(observeAllowedUsers="", observeOnlyStandardAccounts=False, notifyOnObserve=True, screenshotMaxSize=640)
json.dump(s, open(p, "w"))
PY
rm -f "$WORK/console_user" "$WORK/screen_variant"

section "P2 cmcrctl – liczebniki w podsumowaniach (AUDIT TXT-22)"
out="$(p2pw screen-watch 1 "$WORK/p2-watch" --frames 3 --interval 2)"; code=$?
expect_code "screen-watch: kod 0" "$code" 0 "$out"
expect "screen-watch: „3 cykle, 1 nowy obraz”" "$out" "Zakończono: 3 cykle, 1 nowy obraz."

section "P2 cmcrctl – pomoc jednego polecenia podstawowego (AUDIT CLI-03)"
clear_fakelog
for cmd in exec status hosts power trust updates kill logout "hosts add" "updates install"; do
  out="$(p2 $cmd --help </dev/null)"; code=$?
  if [ "$code" = 0 ] && contains "" "$out" "Użycie:" && contains "" "$out" "cmcrctl ${cmd%% *} " \
     && ! contains "" "$out" "Instalacja i inne" && [ "$(printf '%s\n' "$out" | wc -l)" -lt 30 ]; then
    pass "$cmd --help: tylko pomoc polecenia, kod 0"
  else
    fail "$cmd --help: zamiast pomocy polecenia (kod $code, $(printf '%s\n' "$out" | wc -l | tr -d ' ') wierszy)" "$out"
  fi
done
out="$(p2 exec 'echo nie-powinno' 1 -h)"
expect "exec -h: pomoc z opisem KOMP" "$out" "cmcrctl exec \"polecenie\"" "KOMP:"
expect_not "exec -h: nic nie wykonano" "$out" "nie-powinno"
expect_not "--help: nic nie uruchomiono na komputerze" "$(fakelog)" "sudo"
for h in "--help" "help"; do
  out="$(p2 $h)"; code=$?
  expect_code "cmcrctl $h: kod 0" "$code" 0 "$out"
  expect "cmcrctl $h: pełna pomoc" "$out" "Stan i polecenia" "Instalacja i inne" "Zajęcia, zasilanie i raporty"
done
out="$(p2 help exec)"
expect "cmcrctl help exec: pomoc polecenia" "$out" "cmcrctl exec \"polecenie\""
expect_not "cmcrctl help exec: bez pełnej pomocy" "$out" "Instalacja i inne"

section "P2 cmcrctl – quit-app --force pyta o potwierdzenie (AUDIT APL-16)"
mkdir -p "$WORK/P2Dummy.app/Contents/MacOS"
cp /bin/sleep "$WORK/P2Dummy.app/Contents/MacOS/P2Dummy"
codesign --force --sign - "$WORK/P2Dummy.app/Contents/MacOS/P2Dummy" >/dev/null 2>&1
P2DUMMY="$("$WORK/P2Dummy.app/Contents/MacOS/P2Dummy" 300 >/dev/null 2>&1 & echo $!)"
sleep 0.5
out="$(p2pw quit-app P2Dummy 1 --force </dev/null)"; code=$?
expect_code "quit-app --force bez terminala i bez --yes: kod 2" "$code" 2 "$out"
expect "quit-app --force: pytanie z listą komputerów" "$out" "Wymusić zamknięcie „P2Dummy” na: imac01" "niezapisana praca uczniów przepadnie" "dodaj --yes"
kill -0 "$P2DUMMY" 2>/dev/null && pass "quit-app --force bez potwierdzenia: aplikacja działa dalej" \
  || fail "quit-app --force: zamknięto bez potwierdzenia" "$out"
P2_ANSWER=n out="$(p2_tty quit-app P2Dummy 1 --force)"
expect "quit-app --force w terminalu: pytanie i odmowa" "$out" "Wymusić zamknięcie „P2Dummy”" "Przerwano"
kill -0 "$P2DUMMY" 2>/dev/null && pass "quit-app --force: odmowa – aplikacja działa dalej" || fail "quit-app --force: zamknięto mimo odmowy" "$out"
out="$(p2pw quit-app P2Dummy 1 --force --yes)"; code=$?
expect_code "quit-app --force --yes: kod 0" "$code" 0 "$out"
sleep 0.3
if kill -0 "$P2DUMMY" 2>/dev/null; then fail "quit-app --force --yes: aplikacja nadal działa" "$out"; kill -9 "$P2DUMMY"
else pass "quit-app --force --yes: aplikacja zamknięta"; fi
out="$(p2pw quit-app P2Dummy 1 </dev/null)"; code=$?
expect_code "quit-app bez --force: bez pytania (kod 0)" "$code" 0 "$out"

section "P2 cmcrctl – updates install --major (AUDIT APL-17)"
clear_fakelog
out="$(p2pw updates install 1)"; code=$?
expect_code "updates install: kod 0" "$code" 0 "$out"
expect "updates install: nowa wersja macOS pominięta z podpowiedzią dla cmcrctl" "$out" \
  "Pominięto przejście na nową wersję systemu: macOS Testowy 99.1" "cmcrctl: dodaj --major"
expect_not "updates install: bez --major nowa wersja nie jest instalowana" "$(fakelog)" "macOS Testowy 99.1-99A123"
clear_fakelog
out="$(p2pw updates install 1 --major </dev/null)"; code=$?
expect_code "updates install --major bez terminala i bez --yes: kod 2" "$code" 2 "$out"
expect "updates install --major: pytanie o nową wersję macOS" "$out" "razem z nową wersją macOS" "imac01" "dodaj --yes"
expect_not "updates install --major bez potwierdzenia: nic nie zainstalowano" "$(fakelog)" "softwareupdate --install"
out="$(p2pw updates install 1 --major --yes)"; code=$?
expect_code "updates install --major --yes: kod 0" "$code" 0 "$out"
expect "updates install --major: także nowa wersja macOS" "$(fakelog)" "softwareupdate --install macOS Testowy 99.1-99A123"
expect_not "updates install --major: bez podpowiedzi o pominięciu" "$out" "Pominięto przejście"
clear_fakelog
out="$(p2pw updates install 1 --major --download </dev/null)"; code=$?
expect_code "updates install --major --download: samo pobieranie bez pytania (kod 0)" "$code" 0 "$out"
expect "updates install --major --download: pobiera także nową wersję" "$(fakelog)" "softwareupdate --download macOS Testowy 99.1-99A123"

section "P2 cmcrctl – kill PID tylko na jednym komputerze (AUDIT CLI-04)"
P2K="$(sleep 300 >/dev/null 2>&1 & echo $!)"
clear_fakelog
for spec in 1,2 all 1-2; do
  out="$(p2pw kill "$P2K" "$spec")"; code=$?
  expect_code "kill PID $spec: kilka komputerów – kod 2" "$code" 2 "$out"
done
expect "kill PID kilka komputerów: wskazówka" "$out" "Podaj jeden komputer"
expect_not "kill PID kilka komputerów: nic nie wysłano" "$(fakelog)" "kill -TERM"
kill -0 "$P2K" 2>/dev/null && pass "kill PID kilka komputerów: proces działa dalej" || fail "kill PID: zabito proces mimo błędu"
out="$(p2pw kill "$P2K")"; code=$?
expect_code "kill PID bez komputera: kod 2" "$code" 2 "$out"
out="$(p2pw kill "$P2K" imac02)"; code=$?
expect_code "kill PID nr: kod 0" "$code" 0 "$out"
sleep 0.3
if kill -0 "$P2K" 2>/dev/null; then fail "kill PID nr: proces nadal działa" "$out"; kill "$P2K"; else pass "kill PID nr: proces zakończony"; fi
out="$(p2 kill --help)"
expect "kill --help: PID nr" "$out" "cmcrctl kill PID nr [--force]"

section "P2 cmcrctl – logout prosi o wylogowanie, --force wylogowuje natychmiast (AUDIT CLI-05)"
# macOS refuses the Apple Event here (fake-ae-denied), so the polite request fails at once instead of waiting
# for the test user's session to end.
: > "$WORK/fake-ae-denied"
clear_fakelog
out="$(p2pw logout 1 </dev/null)"; code=$?
expect_code "logout: bez --yes – kod 2" "$code" 2 "$out"
expect "logout: pytanie o wylogowanie z pytaniem o zapis" "$out" "Poprosić o wylogowanie" "imac01"
out="$(p2pw logout 1 --yes)"; code=$?
expect "logout: prośba do loginwindow (Apple Event), jak „Wyloguj” w aplikacji" "$(fakelog)" "aevtrlgo"
expect_not "logout: bez --force nie ma launchctl bootout" "$(fakelog)" "launchctl bootout"
expect "logout: odmowa macOS – podpowiedź --force dla cmcrctl" "$out" "cmcrctl logout imac01 --force"
expect_code "logout: odmowa macOS – kod 1" "$code" 1 "$out"
rm -f "$WORK/fake-ae-denied"
clear_fakelog
out="$(p2pw logout 1 --force </dev/null)"; code=$?
expect_code "logout --force: bez --yes – kod 2" "$code" 2 "$out"
expect "logout --force: pytanie o natychmiastowe wylogowanie" "$out" "Wylogować natychmiast" "Niezapisane dane przepadną"
out="$(p2pw logout 1 --force --yes)"; code=$?
expect "logout --force: launchctl bootout" "$(fakelog)" "launchctl bootout gui/$(id -u)"
expect_code "logout --force: kod 0" "$code" 0 "$out"

section "P2 cmcrctl – report czyta listę jak inne polecenia (AUDIT CLI-06)"
# ProxyCommand=/usr/bin/false: the default list (imac01…imac15.local) must not reach the network here.
RPT="$WORK/cfg-p2-report"
mkdir -p "$RPT"
python3 - "$P2/settings.json" "$RPT/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["extraSSHOptions"] = s.get("extraSSHOptions", "") + "\nProxyCommand=/usr/bin/false"
json.dump(s, open(sys.argv[2], "w"))
PY
printf '%s\n' '[{"name":"sala1","address":"sala1.cmcr-e2e.invalid","macAddress":"aa:bb:cc:dd:ee:ff"},' \
  ' {"name":"sala2","adress":"sala2.cmcr-e2e.invalid"}]' > "$RPT/hosts.json"
cp "$RPT/hosts.json" "$WORK/p2-report-hosts.orig"
out="$(CMCR_CONFIG_DIR="$RPT" "$CTL" report 2>&1)"; code=$?
expect "report: ostrzeżenie o nieczytelnym hosts.json" "$out" "Uwaga: nie można odczytać" "brak pola „address” (wpis nr 2)"
expect_code "report: kod 1 (komputery niedostępne)" "$code" 1 "$out"
[ -z "$(ls "$RPT"/*.bak 2>/dev/null)" ] && pass "report: bez kopii .bak (lista tylko czytana)" || fail "report: utworzono kopię" "$(ls "$RPT")"
cmp -s "$RPT/hosts.json" "$WORK/p2-report-hosts.orig" && pass "report: hosts.json bez zmian" || fail "report: hosts.json zmieniony"

section "P2 cmcrctl – schedule set i ask biorą ustawienia z aplikacji (AUDIT CLI-07)"
cat > "$P2/classroom.json" <<'JSON'
{"schedule": {"powerOnEnabled": true, "onType": "wake", "onDays": ["M", "W", "F"], "onTime": {"hour": 6, "minute": 30},
              "powerOffEnabled": true, "offType": "shutdown", "offDays": ["M", "W", "F"], "offTime": {"hour": 15, "minute": 5}},
 "autoRestartAfterPowerLoss": false, "wakeOnLAN": true, "questionTimeoutMinutes": 1}
JSON
clear_fakelog
out="$(p2pw schedule set 1)"; code=$?
expect_code "schedule set bez --on/--off: kod 0" "$code" 0 "$out"
expect "schedule set bez --on/--off: harmonogram zapisany w aplikacji" "$(fakelog)" \
  "pmset repeat wake MWF 06:30:00 shutdown MWF 15:05:00" "pmset -a womp 1"
expect_not "schedule set: autorestart wyłączony w aplikacji – nie włączany" "$(fakelog)" "autorestart"
clear_fakelog
out="$(p2pw schedule set 1 --on-type wakeorpoweron --no-womp)"
expect "schedule set: opcja nadpisuje pole harmonogramu z aplikacji" "$(fakelog)" "pmset repeat wakeorpoweron MWF 06:30:00 shutdown MWF 15:05:00"
expect_not "schedule set --no-womp" "$(fakelog)" "womp"
clear_fakelog
out="$(p2pw schedule set 1 --on MTWRF@07:45)"
expect "schedule set --on: tylko podane zdarzenie" "$(fakelog)" "pmset repeat wake MTWRF 07:45:00"
expect_not "schedule set --on: bez wyłączania z aplikacji" "$(fakelog)" "shutdown MWF"
out="$(p2pw schedule clear 1)"
: > "$WORK/ask.timeout"
out="$(p2pw ask "Jest tam ktoś?" 1)"
expect "ask: czas na odpowiedź z aplikacji (1 min)" "$out" "Czas na odpowiedź: 1 min"
out="$(p2pw ask "Jest tam ktoś?" 1 --timeout 30)"
expect "ask --timeout: podany czas" "$out" "Czas na odpowiedź: 30 s"
rm -f "$WORK/ask.timeout" "$P2/classroom.json"
