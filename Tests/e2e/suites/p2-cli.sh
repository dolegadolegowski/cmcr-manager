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

section "P2 cmcrctl – hosts generate: prefiks to też nazwa komputera (AUDIT CLI-09)"
GEN="$WORK/cfg-p2-generate"
mkdir -p "$GEN"
cp "$P2/settings.json" "$GEN/"
out="$(CMCR_CONFIG_DIR="$GEN" "$CTL" hosts generate "lab,b" --count 2 2>&1)"; code=$?
expect_code "hosts generate: przecinek w prefiksie – kod 2" "$code" 2 "$out"
expect "hosts generate: przecinek w prefiksie – komunikat" "$out" "Niepoprawny prefiks „lab,b”: zawiera przecinek"
out="$(CMCR_CONFIG_DIR="$GEN" "$CTL" hosts generate "lab,b" --count 2 --replace --yes 2>&1)"; code=$?
expect_code "hosts generate --replace: przecinek w prefiksie – kod 2" "$code" 2 "$out"
[ ! -e "$GEN/hosts.json" ] && pass "hosts generate: nic nie zapisano" || fail "hosts generate: zapisano listę" "$(cat "$GEN/hosts.json")"
out="$(CMCR_CONFIG_DIR="$GEN" "$CTL" hosts generate lab-b --count 2 2>&1)"; code=$?
expect "hosts generate: zwykły prefiks działa" "$out" "lab-b01@lab-b01.local"

section "P2 cmcrctl – hosts generate --replace zachowuje uszkodzony hosts.json (AUDIT CLI-10)"
BADG="$WORK/cfg-p2-badgen"
mkdir -p "$BADG"
cp "$P2/settings.json" "$BADG/"
printf '%s\n' '[{"name":"sala1","address":"sala1.cmcr-e2e.invalid","macAddress":"aa:bb:cc:dd:ee:ff"},' \
  ' {"name":"sala2","adress":"sala2.cmcr-e2e.invalid"}]' > "$BADG/hosts.json"
cp "$BADG/hosts.json" "$WORK/p2-badgen.orig"
out="$(CMCR_CONFIG_DIR="$BADG" "$CTL" hosts generate sala --count 2 --replace --yes 2>&1)"; code=$?
expect_code "generate --replace na uszkodzonym pliku: kod 0" "$code" 0 "$out"
bak="$(ls "$BADG"/hosts.json.*.bak 2>/dev/null | head -1)"
[ -n "$bak" ] && cmp -s "$bak" "$WORK/p2-badgen.orig" && pass "generate --replace: oryginał zachowany jako .bak" \
  || fail "generate --replace: brak kopii oryginału" "$(ls -la "$BADG")"
expect "generate --replace: ścieżka kopii w komunikacie" "$out" "$(basename "${bak:-hosts.json.X.bak}")"
expect "generate --replace: nowa lista" "$(CMCR_CONFIG_DIR="$BADG" "$CTL" list 2>&1)" "sala01@sala01.local"
# A file that cannot even be read cannot be copied: then it is not replaced either.
cp "$WORK/p2-badgen.orig" "$BADG/hosts.json"
rm -f "$BADG"/hosts.json.*.bak
chmod 000 "$BADG/hosts.json"
out="$(CMCR_CONFIG_DIR="$BADG" "$CTL" hosts generate sala --count 2 --replace --yes 2>&1)"; code=$?
chmod 644 "$BADG/hosts.json"
expect_code "generate --replace na nieczytelnym pliku bez kopii: kod 1" "$code" 1 "$out"
expect "generate --replace bez kopii: komunikat" "$out" "nie została zmieniona"
cmp -s "$BADG/hosts.json" "$WORK/p2-badgen.orig" && pass "generate --replace bez kopii: plik nie został nadpisany" \
  || fail "generate --replace: nadpisano plik bez kopii" "$(cat "$BADG/hosts.json")"

section "P2 cmcrctl – trust: zmieniony klucz nigdy razem z innymi (AUDIT CLI-14)"
# Two names of the test sshd (127.0.0.1 and localhost) with their own known_hosts file; "changed" = another key
# is trusted under the name, as when a device took over a switched-off iMac's name.
TR="$WORK/cfg-p2-trust"
mkdir -p "$TR"
python3 - "$P2/settings.json" "$TR/settings.json" "$WORK/p2-known_hosts" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["extraSSHOptions"] = "UserKnownHostsFile=" + sys.argv[3]
json.dump(s, open(sys.argv[2], "w"))
PY
cat > "$TR/hosts.json" <<EOF
[
 {"id":"31111111-1111-1111-1111-111111111111","name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"32222222-2222-2222-2222-222222222222","name":"imac02","address":"localhost","user":"$ME","port":$PORT}
]
EOF
ssh-keygen -q -t ed25519 -N "" -f "$WORK/p2-otherkey"
P2_OTHER="$(cut -d' ' -f1-2 "$WORK/p2-otherkey.pub")"
P2_OTHER_B64="$(cut -d' ' -f2 "$WORK/p2-otherkey.pub")"
P2_REAL_B64="$(cut -d' ' -f2 "$WORK/hostkey.pub")"
tctl() { CMCR_CONFIG_DIR="$TR" "$CTL" "$@" 2>&1; }
known() { ssh-keygen -F "[$1]:$PORT" -f "$WORK/p2-known_hosts" 2>/dev/null | grep -v '^#'; }
printf '[127.0.0.1]:%s %s\n[localhost]:%s %s\n' "$PORT" "$P2_OTHER" "$PORT" "$P2_OTHER" > "$WORK/p2-known_hosts"
out="$(tctl trust all --dry-run)"
expect "trust --dry-run: dwa zmienione klucze" "$out" "imac01" "imac02" "KLUCZ SIĘ ZMIENIŁ"
out="$(tctl trust all --yes </dev/null)"; code=$?
expect_code "trust all --yes bez terminala: zmienione klucze pominięte – kod 1" "$code" 1 "$out"
expect "trust all --yes: wskazówka dla każdego komputera" "$out" "pominięto zmieniony klucz" "cmcrctl trust imac01" "cmcrctl trust imac02"
expect_not "trust all --yes: nic nie zaufano" "$out" "zaufano"
contains "" "$(known 127.0.0.1)" "$P2_OTHER_B64" && contains "" "$(known localhost)" "$P2_OTHER_B64" \
  && pass "trust all --yes: known_hosts bez zmian" || fail "trust all --yes: zmieniono known_hosts" "$(cat "$WORK/p2-known_hosts")"
# At a terminal each changed key gets its own question (--yes does not answer it): yes for imac01, no for imac02.
out="$( (sleep 3; printf 't\n'; sleep 2; printf 'n\n'; sleep 2) | CMCR_CONFIG_DIR="$TR" script -q /dev/null "$CTL" trust all --yes 2>&1)"
expect "trust w terminalu: osobne pytanie o każdy zmieniony klucz" "$out" \
  "Zaufać ZMIENIONEMU kluczowi komputera imac01" "imac01: zaufano" "Zaufać ZMIENIONEMU kluczowi komputera imac02"
contains "" "$(known 127.0.0.1)" "$P2_REAL_B64" && pass "trust w terminalu: zaufano tylko potwierdzonemu" \
  || fail "trust w terminalu: imac01 nie zaufany" "$(cat "$WORK/p2-known_hosts")"
contains "" "$(known localhost)" "$P2_OTHER_B64" && pass "trust w terminalu: odmowa – klucz imac02 bez zmian" \
  || fail "trust w terminalu: zaufano mimo odmowy" "$(cat "$WORK/p2-known_hosts")"
# One Mac named on its own: as before (hostkeys.sh: trust 98 --yes).
out="$(tctl trust 2 --yes </dev/null)"; code=$?
expect "trust nr --yes: zmieniony klucz jednego komputera" "$out" "imac02: zaufano"
expect_code "trust nr --yes: kod 0" "$code" 0 "$out"
# A new key and a changed one: --yes covers only the new one.
printf '[localhost]:%s %s\n' "$PORT" "$P2_OTHER" > "$WORK/p2-known_hosts"
out="$(tctl trust all --yes </dev/null)"; code=$?
expect "trust all --yes: nowy klucz zaufany" "$out" "imac01: zaufano"
expect "trust all --yes: zmieniony pominięty" "$out" "pominięto zmieniony klucz" "cmcrctl trust imac02"
expect_code "trust all --yes: nowy i zmieniony – kod 1" "$code" 1 "$out"
contains "" "$(known localhost)" "$P2_OTHER_B64" && pass "trust all --yes: zmieniony klucz bez zmian" \
  || fail "trust all --yes: zaufano zmienionemu kluczowi" "$(cat "$WORK/p2-known_hosts")"

section "P2 cmcrctl – ostrzeżenie o uszkodzonym settings.json także w poleceniach modułów (AUDIT CLI-15)"
BADS="$WORK/cfg-p2-badsettings"
mkdir -p "$BADS"
cp "$P2/hosts.json" "$BADS/"
python3 - "$P2/settings.json" "$BADS/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["sharedFolder"] = 5
json.dump(s, open(sys.argv[2], "w"))
PY
for cmd in "rename 1 --dry-run" "lesson --help" "list"; do
  out="$(CMCR_CONFIG_DIR="$BADS" "$CTL" $cmd 2>&1 </dev/null)"
  expect "uszkodzony settings.json: ostrzeżenie ($cmd)" "$out" "⚠ Niektóre ustawienia były nieprawidłowe" "sharedFolder"
  [ "$(printf '%s\n' "$out" | grep -c 'Niektóre ustawienia')" = 1 ] && pass "uszkodzony settings.json: jedno ostrzeżenie ($cmd)" \
    || fail "uszkodzony settings.json: liczba ostrzeżeń ($cmd)" "$out"
done

section "P2 cmcrctl – install: KOMP rozpoznawany niezależnie od plików lokalnych (AUDIT CLI-17)"
# As in ~/Public/cmcr (cmcr-helpers convention): local folders named like a host selection.
INS="$WORK/p2-install-cwd"
mkdir -p "$INS/all" "$INS/imac02"
printf 'nie-instalator' > "$INS/all/nie-wysylac.txt"
printf 'atrapa' > "$INS/P2Test.pkg"
clear_fakelog
out="$(cd "$INS" && CMCR_CONFIG_DIR="$P2" CMCR_PASSWORD="$PASSWORD" "$CTL" install P2Test.pkg imac02 </dev/null 2>&1)"; code=$?
expect "install plik nr: KOMP mimo folderu o tej nazwie" "$out" "imac02:" "lokalny plik lub folder o tej nazwie podaj jako ./imac02"
expect_not "install plik nr: bez błędu „Podaj komputery”" "$out" "Podaj komputery"
expect_not "install plik nr: tylko wskazany komputer" "$out" "imac01:"
out="$(cd "$INS" && CMCR_CONFIG_DIR="$P2" CMCR_PASSWORD="$PASSWORD" "$CTL" install P2Test.pkg all </dev/null 2>&1)"; code=$?
expect "install plik all: oba komputery mimo folderu all" "$out" "imac01:" "imac02:"
expect_not "install plik all: folder all nie jest instalatorem" "$out" "nie-wysylac"
out="$(cd "$INS" && CMCR_CONFIG_DIR="$P2" CMCR_PASSWORD="$PASSWORD" "$CTL" install P2Test.pkg ./all </dev/null 2>&1)"; code=$?
expect_code "install plik ./all: ./all to plik, bez KOMP w skrypcie – kod 2" "$code" 2 "$out"
expect "install plik ./all: prośba o komputery" "$out" "Podaj komputery dla polecenia install"

section "P2 cmcrctl – Wake-on-LAN: MAC karty Ethernet i czekanie na komputer (AUDIT KOM-13)"
WK="$WORK/cfg-p2-wake"
mkdir -p "$WK"
cp "$P2/settings.json" "$WK/"
cat > "$WK/hosts.json" <<EOF
[
 {"id":"41111111-1111-1111-1111-111111111111","name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"42222222-2222-2222-2222-222222222222","name":"imac02","address":"imac02.cmcr-e2e.invalid","user":"x","port":22,
  "macAddress":"00:11:22:33:44:55"}
]
EOF
# Last status saved by the app: Wi-Fi carries the default route, the wired port has another MAC.
cat > "$WK/status-cache.json" <<'EOF'
{"42222222-2222-2222-2222-222222222222": {"reachability": "offline", "message": "",
  "info": {"mac": "00:11:22:33:44:55", "mac_ethernet": "aa:bb:cc:00:11:22", "ip": "10.0.5.23"}}}
EOF
wctl() { CMCR_CONFIG_DIR="$WK" "$CTL" "$@" 2>&1; }
out="$(wctl wake 2 --dry-run)"; code=$?
expect "wake --dry-run: najpierw MAC karty Ethernet z ostatniego stanu, potem MAC z listy" "$out" \
  "imac02: pakiet Wake-on-LAN dla aa:bb:cc:00:11:22, 00:11:22:33:44:55" "10.0.5.255"
expect_code "wake --dry-run: kod 0" "$code" 0 "$out"
out="$(wctl wake 1 --wait)"; code=$?
expect "wake --wait: włączony komputer odpowiada (bez pakietów)" "$out" "imac01: komputer jest włączony"
expect_code "wake --wait: kod 0" "$code" 0 "$out"
out="$(wctl wake 1 --wait --dry-run)"; code=$?
expect_code "wake --wait --dry-run: kod 2" "$code" 2 "$out"
# status stores the MAC Wake-on-LAN needs: the wired port when the Mac has one (like the app), not the default route's.
json="$(wctl status 1 --json)"
expected="$(printf '%s' "$json" | python3 -c 'import json,sys; i=json.load(sys.stdin)[0]["info"]; print((i.get("mac_ethernet") or i.get("mac") or "").lower())')"
saved="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0].get("macAddress",""))' "$WK/hosts.json")"
[ -n "$saved" ] && [ "$saved" = "$expected" ] && pass "status: zapamiętany MAC karty Ethernet ($saved)" \
  || fail "status: zapamiętany MAC „$saved”, oczekiwano „$expected”" "$json"

section "P2 cmcrctl – collect z folderu prywatnego konta jako root, jak w aplikacji (AUDIT PLI-19)"
# A folder of the student's account outside the shared folder (Desktop on a real iMac). Here the student is the
# test account, so the folder must not exist: nothing is read from this Mac's real home folder.
clear_fakelog
out="$(p2pw collect 1 --from "/Users/{student}/cmcr-e2e-brak-$$" --to "$WORK/p2-collected" --no-date)"; code=$?
expect "collect z folderu konta: informacja o sudo" "$out" "jako root – folder prywatny konta" "Brak folderu"
expect "collect z folderu konta: przez sudo" "$(fakelog)" "sudo "
clear_fakelog
out="$(p2 collect 1 --from "/Users/{student}/cmcr-e2e-brak-$$" --to "$WORK/p2-collected" --no-date)"; code=$?
expect "collect z folderu konta bez hasła: wymaga hasła (root)" "$out" "Brak zapisanego hasła administratora"
clear_fakelog
echo "wspolna" > "$WORK/remote/Public/cmcr/p2-wspolna.txt"
out="$(p2 collect 1 --to "$WORK/p2-collected2" --no-date)"; code=$?
expect_code "collect z folderu cmcr: bez sudo i bez hasła (kod 0)" "$code" 0 "$out"
expect_not "collect z folderu cmcr: bez informacji o sudo" "$out" "jako root"
expect_not "collect z folderu cmcr: bez sudo" "$(fakelog)" "sudo "
rm -f "$WORK/remote/Public/cmcr/p2-wspolna.txt"
mkdir -p "$WORK/p2-collect-src"
echo "praca" > "$WORK/p2-collect-src/praca.txt"
out="$(p2 collect 1 --from "$WORK/p2-collect-src" --to "$WORK/p2-collected3" --no-date)"; code=$?
expect_code "collect spoza /Users: jak dotąd bez sudo (kod 0)" "$code" 0 "$out"
out="$(p2 push --help)"
expect "push --help: opis właściciela plików bez --root" "$out" "bez --root" "właściciel"

section "P2 cmcrctl – ls ŚCIEŻKA KOMP i clean rozwijają {student} (AUDIT PLI-20)"
out="$(p2 ls "/Users/{student}" 1)"; code=$?
expect_code "ls /Users/{student}: kod 0" "$code" 0 "$out"
expect "ls /Users/{student}: katalog konta ucznia" "$out" "Library"
# A folder that does not exist: nothing in this Mac's real home folder is touched.
out="$(p2pw clean "/Users/{student}/cmcr-e2e-brak-$$" 1 </dev/null)"; code=$?
expect "clean: pytanie z rozwiniętą ścieżką" "$out" "/Users/$ME/cmcr-e2e-brak-$$"
out="$(p2pw clean "/Users/{student}/cmcr-e2e-brak-$$" 1 --yes)"; code=$?
expect "clean /Users/{student}/…: ścieżka konta ucznia" "$out" "Brak folderu: /Users/$ME/cmcr-e2e-brak-$$"
expect_not "clean: bez dosłownego {student}" "$out" "{student}"

section "P2 cmcrctl – exec --root z ryzykownym poleceniem pyta w terminalu (AUDIT ZAD-15)"
RISKY='echo "wykonano-$((40 + 2))"; true || shutdown -h +60'
P2_ANSWER=n out="$(p2_tty exec "$RISKY" 1 --root)"
expect "exec --root w terminalu: pytanie z ryzykiem i listą komputerów" "$out" \
  "Polecenie zawiera: wyłączenie lub restart" "jako root na: imac01" "Przerwano"
expect_not "exec --root w terminalu: odmowa – nic nie wykonano" "$out" "wykonano-42"
P2_ANSWER=t out="$(p2_tty exec "$RISKY" 1 --root)"
expect "exec --root w terminalu: po zgodzie wykonano" "$out" "wykonano-42"
P2_ANSWER=n out="$(p2_tty exec "$RISKY" 1 --root --yes)"
expect "exec --root --yes w terminalu: bez pytania" "$out" "wykonano-42"
P2_ANSWER=n out="$(p2_tty exec 'echo "zwykle-$((1 + 1))"; asroot true' 1)"
expect "exec bez ryzyka w terminalu: bez pytania" "$out" "zwykle-2"
expect_not "exec bez ryzyka: bez ostrzeżenia" "$out" "Polecenie zawiera"
P2_ANSWER=n out="$(p2_tty exec "$RISKY" 1)"
expect "exec ryzykowne bez root: bez pytania" "$out" "wykonano-42"
out="$(p2pw exec "$RISKY" 1 --root </dev/null)"; code=$?
expect "exec --root w skrypcie: wykonane jak dotąd, z ostrzeżeniem" "$out" "wykonano-42" "Uwaga: polecenie zawiera: wyłączenie lub restart"
expect_code "exec --root w skrypcie: kod 0" "$code" 0 "$out"

section "P2 cmcrctl – screen-watch zgłasza nieudany zapis klatki (AUDIT ZAJ-15)"
mkdir -p "$WORK/p2-watch-ro"
chmod 555 "$WORK/p2-watch-ro"
out="$(p2pw screen-watch 1 "$WORK/p2-watch-ro" --frames 2 --interval 2)"; code=$?
chmod 755 "$WORK/p2-watch-ro"
expect_code "screen-watch do folderu tylko do odczytu: kod 1" "$code" 1 "$out"
expect "screen-watch: czytelny błąd zapisu" "$out" "✘ Nie można zapisać" "p2-watch-ro/klatka-001"
expect_not "screen-watch: niezapisana klatka nie jest podawana jako zapisana" "$out" "→ $WORK/p2-watch-ro"
[ -z "$(ls -A "$WORK/p2-watch-ro")" ] && pass "screen-watch: folder pusty" || fail "screen-watch: pliki w folderze" "$(ls -la "$WORK/p2-watch-ro")"
