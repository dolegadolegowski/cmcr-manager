# CMCR Screen Agent itself (docs/screen-agent.md): cmcrctl screen-agent install|status|permission|remove, and how the
# preview copes with an agent that is missing, stopped, disabled, not answering or not the installed one. Sourced by
# run.sh. The agent is the real debug build (CMCR_SCREEN_AGENT_APP, built by run.sh), uploaded over scp and installed
# under $WORK/setup-root by Scripts.installScreenAgent; the fake launchd of fakes.sh runs it in its test mode (files in
# $AGENT_TEST set the state of the screen, requests.log lists what it was asked).

sa_settings_backup="$(cat "$WORK/config/settings.json")"
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s.update(observeAllowedUsers="", observeOnlyStandardAccounts=False, notifyOnObserve=True, screenshotMaxSize=640)
json.dump(s, open(p, "w"))
PY
SA_UID="$(id -u)"
SA_APP="$AGENT_ROOT/CMCR Screen Agent.app"
SA_PLIST="$WORK/setup-root/Library/LaunchAgents/pl.cmcr.manager.screen-agent.plist"
SA_SOCK="$AGENT_ROOT/run/$SA_UID.sock"
SA_LOG="$WORK/config/actions.log"
SA_LABEL=pl.cmcr.manager.screen-agent
sa_count() { local n; n="$(grep -c -- "$1" "$WORK/fake.log" 2>/dev/null)"; echo "${n:-0}"; }
sa_wait_for() { # sa_wait_for FILE NEEDLE [seconds] – polls a growing file
  local i
  for i in $(seq 1 $((${3:-15} * 10))); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
# sa_order FILE FIRST SECOND – "ok" when the first line with FIRST comes before the first one with SECOND.
sa_order() {
  awk -v a="$2" -v b="$3" 'index($0, a) && !x {x = NR} index($0, b) && !y {y = NR} END {print (x && y && x < y) ? "ok" : "nie"}' "$1"
}
sa_mode() { local m; m="$(stat -f %Mp%Lp "$1" 2>/dev/null)"; echo "${m#0}"; }  # with the sticky bit (run: 1733)
sa_pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }
rm -f "$WORK/console_user" "$WORK/fake-no-console"
agent_reset
agent_ensure

section "Usługa podglądu – cmcrctl screen-agent: pomoc i błędy użycia"
clear_fakelog
out="$(ctl screen-agent --help)"; code=$?
expect_code "screen-agent --help: kod 0" "$code" 0 "$out"
expect "screen-agent --help: składnia" "$out" "Użycie:" "cmcrctl screen-agent install|status|permission|remove KOMP"
out="$(ctl screen-agent -h)"; code=$?
expect_code "screen-agent -h: kod 0" "$code" 0 "$out"
out="$(ctl screen-agent </dev/null)"; code=$?
expect_code "screen-agent bez polecenia: kod 2" "$code" 2 "$out"
out="$(ctl screen-agent bogus 1 </dev/null)"; code=$?
expect_code "screen-agent bogus: kod 2" "$code" 2 "$out"
expect "screen-agent bogus: komunikat" "$out" "Nieznane polecenie screen-agent bogus"
out="$(ctl screen-agent status 1 2 </dev/null)"; code=$?
expect_code "screen-agent status z nadmiarowym argumentem: kod 2" "$code" 2 "$out"
out="$(ctlpw screen-agent install </dev/null)"; code=$?
expect_code "screen-agent install bez komputera poza terminalem: kod 2" "$code" 2 "$out"
out="$(ctlpw screen-agent remove 1 </dev/null)"; code=$?
expect_code "screen-agent remove bez --yes poza terminalem: kod 2" "$code" 2 "$out"
expect "screen-agent remove bez --yes: wymaga potwierdzenia" "$out" "wymaga potwierdzenia"
[ -x "$AGENT_EXE" ] && pass "screen-agent remove bez --yes: usługa została" || fail "screen-agent remove bez --yes: usługa usunięta"
expect_not "screen-agent: błędy użycia niczego nie uruchomiły" "$(fakelog)" "sudo"
out="$(CMCR_SCREEN_AGENT_APP="$WORK/brak/CMCR Screen Agent.app" ctlpw screen-agent install 1 </dev/null)"; code=$?
expect_code "screen-agent install bez pakietu usługi: kod 1" "$code" 1 "$out"
expect "screen-agent install bez pakietu usługi: komunikat" "$out" "nie ma przy sobie usługi podglądu ekranu"

section "Usługa podglądu – usunięcie (cmcrctl screen-agent remove)"
sa_pid="$(agent_pid "$SA_UID")"
[ -n "$sa_pid" ] && pass "usunięcie: usługa działa przed usunięciem" || fail "usunięcie: usługa nie działa przed usunięciem" "$(agent_ping "$SA_UID")"
rm -f "$SA_LOG"
clear_fakelog
out="$(ctlpw screen-agent remove 1 --yes)"; code=$?
expect_code "usunięcie: kod 0" "$code" 0 "$out"
expect "usunięcie: komunikat" "$out" "CMCR:AGENT removed 1.0.0" "→ imac01: usługa podglądu usunięta."
if [ ! -e "$SA_APP" ] && [ ! -e "$SA_PLIST" ] && [ ! -e "$AGENT_ROOT/run" ] && [ ! -e "$AGENT_ROOT/shots" ]; then
  pass "usunięcie: aplikacja, LaunchAgent, gniazda i zrzuty usunięte"
else
  fail "usunięcie: zostały pliki" "$(find "$AGENT_ROOT" "$SA_PLIST" 2>&1 | head -20)"
fi
expect "usunięcie: zatrzymana w sesji i uprawnienie Nagrywanie ekranu wyczyszczone" "$(fakelog)" \
  "launchctl bootout gui/$SA_UID/$SA_LABEL" "tccutil reset ScreenCapture $SA_LABEL"
if [ -n "$sa_pid" ] && ! kill -0 "$sa_pid" 2>/dev/null; then pass "usunięcie: proces usługi zakończony"
else fail "usunięcie: proces usługi nadal działa" "$(ps -p "${sa_pid:-0}" -o pid,command 2>&1)"; fi
expect "usunięcie: wpis w dzienniku działań" "$(cat "$SA_LOG" 2>/dev/null)" "cmcrctl screen-agent remove 1 --yes → imac01"
out="$(ctlpw _builder screen-agent-remove 1)"; code=$?
expect_code "usunięcie drugi raz: kod 0" "$code" 0 "$out"
expect "usunięcie drugi raz: usługi nie było" "$out" "CMCR:AGENT absent -" "Usługi podglądu ekranu nie było na tym iMacu."

section "Usługa podglądu – brak usługi na iMacu"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/sa-missing.jpg")"
expect "brak usługi: podgląd mówi, co zainstalować" "$out" "Na tym iMacu nie ma usługi podglądu ekranu (CMCR Screen Agent)" \
  "Zainstaluj usługę podglądu"
[ ! -f "$WORK/sa-missing.jpg" ] && pass "brak usługi: brak pliku" || fail "brak usługi: zapisano obraz"
out="$(ctlpw screen-watch 1 "$WORK/sa-missing" --frames 1 --interval 2)"; code=$?
expect_code "brak usługi: screen-watch – kod 9" "$code" 9 "$out"
# A student's session would need sudo – the missing agent is found before, so a wrong password does not hide it.
printf daemon > "$WORK/console_user"
clear_fakelog
out="$(CMCR_PASSWORD="zle-haslo" "$CTL" screen-watch 1 "$WORK/sa-missing2" --frames 1 --interval 2 2>&1)"; code=$?
expect_code "brak usługi, konto ucznia, złe hasło: kod 9" "$code" 9 "$out"
expect "brak usługi, konto ucznia: komunikat o usłudze" "$out" "nie ma usługi podglądu ekranu"
expect_not "brak usługi, konto ucznia: bez sudo" "$(fakelog)" "sudo"
rm -f "$WORK/console_user"
out="$(ctlpw screen-agent status 1)"; code=$?
expect "brak usługi: status" "$out" "imac01: wersja: brak usługi, załadowana: nie, uprawnienie: –"
expect_code "brak usługi: status – kod 1" "$code" 1 "$out"
out="$(ctlpw _builder screen-agent-permission 1)"; code=$?
expect_code "brak usługi: prośba o uprawnienie – kod 9" "$code" 9 "$out"
expect "brak usługi: prośba o uprawnienie – komunikat" "$out" "najpierw ją zainstaluj"

section "Usługa podglądu – instalacja (cmcrctl screen-agent install)"
rm -f "$SA_LOG"
: > "$WORK/tar.mode"                               # the fake tar logs the uploaded archive it unpacks
clear_fakelog
out="$(ctlpw screen-agent install 1)"; code=$?
expect_code "instalacja: kod 0" "$code" 0 "$out"
expect "instalacja: zainstalowana i działa w sesji zalogowanego użytkownika" "$out" "CMCR:AGENT installed 1.0.0" \
  "CMCR:AGENT-SESSION $ME $SA_UID AGENT 1.0.0 perm=granted" "→ imac01: usługa podglądu zainstalowana (wersja 1.0.0)"
modes="$(sa_mode "$AGENT_ROOT") $(sa_mode "$SA_APP") $(sa_mode "$AGENT_EXE") $(sa_mode "$SA_PLIST") $(sa_mode "$AGENT_ROOT/run") $(sa_mode "$AGENT_ROOT/shots")"
expect_code "instalacja: prawa (katalog, aplikacja, plik wykonywalny, LaunchAgent, run, shots)" "$modes" "755 755 755 644 1733 700" \
  "$(ls -la "$AGENT_ROOT" "$SA_PLIST" 2>&1)"
[ -S "$SA_SOCK" ] && [ "$(sa_mode "$SA_SOCK")" = 600 ] && pass "instalacja: gniazdo usługi 600" \
  || fail "instalacja: gniazdo usługi" "$(ls -la "$AGENT_ROOT/run" 2>&1)"
codesign --verify --strict "$SA_APP" 2>/dev/null && pass "instalacja: podpis zainstalowanej kopii poprawny" \
  || fail "instalacja: podpis" "$(codesign --verify --strict "$SA_APP" 2>&1)"
plist="$(sa_pb Label "$SA_PLIST")|$(sa_pb Program "$SA_PLIST")|$(sa_pb ProgramArguments:0 "$SA_PLIST") $(sa_pb ProgramArguments:1 "$SA_PLIST")|$(sa_pb RunAtLoad "$SA_PLIST") $(sa_pb KeepAlive "$SA_PLIST")|$(sa_pb LimitLoadToSessionType "$SA_PLIST") $(sa_pb ProcessType "$SA_PLIST")|$(sa_pb AssociatedBundleIdentifiers:0 "$SA_PLIST") $(sa_pb ThrottleInterval "$SA_PLIST")|$(sa_pb StandardOutPath "$SA_PLIST")"
expect_code "instalacja: LaunchAgent (program, serve, zawsze w sesji Aqua, bez pliku wyjścia)" "$plist" \
  "$SA_LABEL|$AGENT_EXE|$AGENT_EXE serve|true true|Aqua Interactive|$SA_LABEL 5|" "$(cat "$SA_PLIST" 2>&1)"
plutil -lint "$SA_PLIST" >/dev/null 2>&1 && pass "instalacja: LaunchAgent poprawny (plutil -lint)" || fail "instalacja: plutil -lint" "$(plutil -lint "$SA_PLIST" 2>&1)"
expect "instalacja: właściciel root:wheel, start w sesji przez launchd" "$(fakelog)" "chown -R root:wheel $AGENT_ROOT/.cmcr-agent-new." \
  "launchctl bootstrap gui/$SA_UID $SA_PLIST"
expect_not "instalacja: nowa instalacja nie czyści uprawnienia" "$(fakelog)" "tccutil"
sa_tar="$(awk '{print $3}' "$WORK/tar.mode" 2>/dev/null | head -n 1)"
rm -f "$WORK/tar.mode"
if [ -n "$sa_tar" ] && [ ! -e "$sa_tar" ]; then pass "instalacja: przesłane archiwum usunięte ($sa_tar)"
else fail "instalacja: archiwum ${sa_tar:-?} zostało" "$(ls -la "$sa_tar" 2>&1)"; fi
expect "instalacja: usługa odpowiada" "$(agent_ping "$SA_UID")" "AGENT 1.0.0 perm=granted"
expect "instalacja: wpis w dzienniku działań" "$(cat "$SA_LOG" 2>/dev/null)" "cmcrctl screen-agent install 1 → imac01"

sa_ino="$(stat -f %i "$AGENT_EXE")"; sa_pid="$(agent_pid "$SA_UID")"
clear_fakelog
out="$(ctlpw screen-agent install 1)"; code=$?
expect_code "druga instalacja: kod 0" "$code" 0 "$out"
expect "druga instalacja: bez zmian" "$out" "CMCR:AGENT unchanged 1.0.0" "→ imac01: usługa podglądu bez zmian (wersja 1.0.0 była już zainstalowana)"
[ "$(stat -f %i "$AGENT_EXE")" = "$sa_ino" ] && pass "druga instalacja: plik usługi nietknięty (to samo i-węzło)" || fail "druga instalacja: plik wymieniony"
[ -n "$sa_pid" ] && [ "$(agent_pid "$SA_UID")" = "$sa_pid" ] && pass "druga instalacja: usługa działa dalej (ten sam proces)" \
  || fail "druga instalacja: usługa uruchomiona ponownie (${sa_pid:-?} → $(agent_pid "$SA_UID"))" "$(fakelog)"
expect_not "druga instalacja: uprawnienie zostaje" "$(fakelog)" "tccutil"
expect_code "druga instalacja: usługa nie jest zatrzymywana" "$(grep -c '^launchctl bootout gui/' "$WORK/fake.log")" 0 "$(fakelog)"

# Only the LaunchAgent differs (e.g. edited on the iMac): it is rewritten, the app and its permission stay.
/usr/libexec/PlistBuddy -c "Set :ThrottleInterval 60" "$SA_PLIST"
clear_fakelog
out="$(ctlpw screen-agent install 1)"; code=$?
expect_code "zmieniony LaunchAgent: kod 0" "$code" 0 "$out"
expect "zmieniony LaunchAgent: przepisany, aplikacja bez zmian" "$out" "CMCR:AGENT updated 1.0.0" \
  "zaktualizowano ustawienia uruchamiania (aplikacja bez zmian)"
expect_code "zmieniony LaunchAgent: przywrócony" "$(sa_pb ThrottleInterval "$SA_PLIST")" 5
[ "$(stat -f %i "$AGENT_EXE")" = "$sa_ino" ] && pass "zmieniony LaunchAgent: plik usługi nietknięty" || fail "zmieniony LaunchAgent: plik usługi wymieniony"
expect_not "zmieniony LaunchAgent: uprawnienie zostaje" "$(fakelog)" "tccutil"
expect "zmieniony LaunchAgent: usługa działa" "$(agent_ping "$SA_UID")" "AGENT 1.0.0"

# Another version (an older one, re-signed ad hoc): replaced, and with a new signature the Screen Recording permission
# is cleared and has to be granted again.
SA_OLD="$WORK/agent-bundle-0.9.0/CMCR Screen Agent.app"
mkdir -p "$WORK/agent-bundle-0.9.0"
cp -R "$CMCR_SCREEN_AGENT_APP" "$WORK/agent-bundle-0.9.0/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.9.0" -c "Set :CFBundleVersion 0.9.0" "$SA_OLD/Contents/Info.plist"
codesign --force --sign - --options runtime "$SA_OLD" >/dev/null 2>&1
sa_pid="$(agent_pid "$SA_UID")"
clear_fakelog
out="$(CMCR_SCREEN_AGENT_APP="$SA_OLD" ctlpw screen-agent install 1)"; code=$?
expect_code "inna wersja: kod 0" "$code" 0 "$out"
expect "inna wersja: wymieniona, uprawnienie do nadania ponownie" "$out" "CMCR:AGENT updated 0.9.0" \
  "Zaktualizowano usługę podglądu ekranu 1.0.0 → 0.9.0." "uprawnienie Nagrywanie ekranu trzeba nadać ponownie" \
  "→ imac01: usługa podglądu zaktualizowana do wersji 0.9.0"
expect "inna wersja: tccutil reset" "$(fakelog)" "tccutil reset ScreenCapture $SA_LABEL"
expect_code "inna wersja: zatrzymana przed podmianą, potem uruchomiona" \
  "$(sa_order "$WORK/fake.log" "launchctl bootout gui/$SA_UID/$SA_LABEL" "launchctl bootstrap gui/$SA_UID $SA_PLIST")" ok "$(fakelog)"
expect_code "inna wersja: zainstalowana 0.9.0" "$(sa_pb CFBundleShortVersionString "$SA_APP/Contents/Info.plist")" 0.9.0
[ "$(stat -f %i "$AGENT_EXE")" != "$sa_ino" ] && pass "inna wersja: plik usługi wymieniony" || fail "inna wersja: plik usługi ten sam"
[ -n "$(agent_pid "$SA_UID")" ] && [ "$(agent_pid "$SA_UID")" != "$sa_pid" ] && pass "inna wersja: działa nowa kopia usługi" \
  || fail "inna wersja: proces usługi (${sa_pid:-?} → $(agent_pid "$SA_UID"))"
out="$(ctlpw screen-agent status 1)"; code=$?
expect "inna wersja: status – starsza wersja" "$out" "imac01: wersja: 0.9.0 (starsza niż 1.0.0 – cmcrctl screen-agent install)"
expect_code "inna wersja: status – kod 1" "$code" 1 "$out"
clear_fakelog
out="$(ctlpw screen-agent install 1)"; code=$?
expect_code "powrót do wersji aplikacji: kod 0" "$code" 0 "$out"
expect "powrót do wersji aplikacji: zaktualizowana" "$out" "CMCR:AGENT updated 1.0.0" "→ imac01: usługa podglądu zaktualizowana do wersji 1.0.0"
expect "powrót do wersji aplikacji: tccutil reset" "$(fakelog)" "tccutil reset ScreenCapture $SA_LABEL"
expect "powrót do wersji aplikacji: usługa odpowiada" "$(agent_ping "$SA_UID")" "AGENT 1.0.0 perm=granted"

section "Usługa podglądu – podgląd wznawia usługę, której nie ma w sesji albo która nie odpowiada"
# Killed while a stream runs (its socket stays behind): the next cycle restarts it and the frames go on.
sa_pid="$(agent_pid "$SA_UID")"
clear_fakelog
ctlpw screen-watch 1 "$WORK/sa-killed" --frames 3 --interval 2 > "$WORK/sa-killed.out" 2>&1 &
sa_job=$!
sa_wait_for "$WORK/sa-killed.out" "Klatka 1:" 20
[ -n "$sa_pid" ] && kill -KILL "$sa_pid" 2>/dev/null
wait "$sa_job"; code=$?
out="$(cat "$WORK/sa-killed.out")"
expect_code "zabita usługa: kod 0" "$code" 0 "$out"
expect "zabita usługa: klatki dalej przychodzą" "$out" "Klatka 1: nowy obraz" "Klatka 2: " "Klatka 3: " "Zakończono: 3 cykle"
expect "zabita usługa: uruchomiona ponownie (kickstart -k)" "$(fakelog)" "launchctl kickstart -k gui/$SA_UID/$SA_LABEL"
[ -n "$(agent_pid "$SA_UID")" ] && [ "$(agent_pid "$SA_UID")" != "$sa_pid" ] && pass "zabita usługa: działa nowa" || fail "zabita usługa: nie działa" "$(fakelog)"

# Not loaded in the session (e.g. after a logout of the agent) and disabled by the student: enabled and loaded again.
agent_bootout "$SA_UID"
ctl exec "launchctl disable gui/$SA_UID/$SA_LABEL" 1 >/dev/null
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/sa-disabled.jpg")"; code=$?
expect_code "wyłączona usługa: zrzut – kod 0" "$code" 0 "$out"
expect_code "wyłączona usługa: najpierw włączona, potem załadowana" \
  "$(sa_order "$WORK/fake.log" "launchctl enable gui/$SA_UID/$SA_LABEL" "launchctl bootstrap gui/$SA_UID $SA_PLIST")" ok "$(fakelog)"
[ -n "$(agent_pid "$SA_UID")" ] && pass "wyłączona usługa: działa" || fail "wyłączona usługa: nie działa" "$(fakelog)"

# It cannot start at all (here: its run folder is gone): one restart, then "does not answer", without an image.
mv "$AGENT_ROOT/run" "$AGENT_ROOT/run.away"
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/sa-down" --frames 1 --interval 2)"; code=$?
expect_code "usługa nie odpowiada: kod 9" "$code" 9 "$out"
expect "usługa nie odpowiada: komunikat" "$out" "nie odpowiada w sesji zalogowanego użytkownika, także po ponownym uruchomieniu" "brak katalogu"
expect "usługa nie odpowiada: próba ponownego uruchomienia" "$(fakelog)" "launchctl kickstart -k gui/$SA_UID/$SA_LABEL"
n="$(ls "$WORK/sa-down"/*.jpg 2>/dev/null | wc -l | tr -d ' ')"
expect_code "usługa nie odpowiada: żadnej klatki" "$n" 0 "$out"
out="$(ctlpw screen-agent status 1)"; code=$?
expect "usługa nie odpowiada: status" "$out" "imac01: wersja: 1.0.0, załadowana: tak" "błąd: "
expect_code "usługa nie odpowiada: status – kod 1" "$code" 1 "$out"
mv "$AGENT_ROOT/run.away" "$AGENT_ROOT/run"
agent_restart "$SA_UID" && pass "usługa nie odpowiada: po naprawie znów działa" || fail "usługa nie odpowiada: nie wróciła" "$(tail -5 "$WORK/agent-serve.log")"

# Another program answers on the agent's socket: here a copy of the agent itself at another path, in serve mode (its
# test mode – it never touches the real screen). The client refuses it: no notice, no image, no restart of anything.
mkdir -p "$WORK/sa-impostor"
cp "$AGENT_EXE" "$WORK/sa-impostor/cmcr-screen-agent"
sa_ino="$(stat -f %i "$SA_SOCK" 2>/dev/null)"
( cd / || exit 1
  exec /usr/bin/env -i PATH=/usr/bin:/bin CMCR_SETUP_ROOT_PREFIX="$WORK/setup-root" CMCR_SCREEN_AGENT_TEST_DIR="$AGENT_TEST" \
    CMCR_SCREEN_AGENT_TEST_UID="$SA_UID" "$WORK/sa-impostor/cmcr-screen-agent" serve </dev/null >"$WORK/sa-impostor.log" 2>&1 ) &
sa_imp=$!
for i in $(seq 1 50); do [ -S "$SA_SOCK" ] && [ "$(stat -f %i "$SA_SOCK" 2>/dev/null)" != "$sa_ino" ] && break; sleep 0.1; done
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/sa-untrusted.jpg")"
expect "obca usługa: odmowa" "$out" "Na gnieździe usługi podglądu odpowiada inny program niż zainstalowana usługa" "sa-impostor"
[ ! -f "$WORK/sa-untrusted.jpg" ] && pass "obca usługa: brak pliku" || fail "obca usługa: zapisano obraz"
out="$(ctlpw screen-watch 1 "$WORK/sa-untrusted" --frames 1 --interval 2)"; code=$?
expect_code "obca usługa: screen-watch – kod 9" "$code" 9 "$out"
expect_code "obca usługa: nic do niej nie wysłano" "$(agent_count '^CMCRA1 ')" 0 "$(agentlog)"
expect_code "obca usługa: bez prób ponownego uruchomienia" "$(grep -cE '^launchctl (kickstart|bootstrap) gui/' "$WORK/fake.log")" 0 "$(fakelog)"
out="$(ctlpw screen-agent status 1)"; code=$?
expect "obca usługa: status – błąd" "$out" "błąd: "
expect_code "obca usługa: status – kod 1" "$code" 1 "$out"
kill -TERM "$sa_imp" 2>/dev/null; wait "$sa_imp" 2>/dev/null
agent_restart "$SA_UID" && pass "obca usługa: po jej zakończeniu prawdziwa usługa działa" || fail "obca usługa: usługa nie wróciła"

section "Usługa podglądu – uprawnienie i stan (permission, status)"
agent_restart "$SA_UID"
echo denied > "$AGENT_TEST/perm"
out="$(ctlpw screen-agent status 1)"; code=$?
expect "bez uprawnienia: status" "$out" "imac01: wersja: 1.0.0, załadowana: tak, uprawnienie: brak, zalogowany: $ME"
expect_code "bez uprawnienia: status – kod 1" "$code" 1 "$out"
rm -f "$SA_LOG"
agent_restart "$SA_UID"
clear_fakelog
out="$(ctlpw screen-agent permission 1)"; code=$?
expect_code "prośba o uprawnienie: kod 0" "$code" 0 "$out"
expect "prośba o uprawnienie: okno macOS przy komputerze" "$out" "CMCR:AGENT-PERMISSION denied" \
  "→ imac01: na iMacu pojawiło się okno macOS" "włącz „CMCR Screen Agent”" "cmcrctl screen-agent status imac01"
[ -e "$AGENT_TEST/permission-requested" ] && pass "prośba o uprawnienie: usługa poprosiła macOS" || fail "prośba o uprawnienie: usługa nie poprosiła" "$(agentlog)"
expect "prośba o uprawnienie: wpis w dzienniku działań" "$(cat "$SA_LOG" 2>/dev/null)" "cmcrctl screen-agent permission 1 → imac01"
out="$(ctlpw screen-watch 1 "$WORK/sa-noperm" --frames 1 --interval 2)"; code=$?
expect_code "bez uprawnienia: podgląd – kod 5" "$code" 5 "$out"
rm -f "$AGENT_TEST/perm" "$AGENT_TEST/permission-requested"
out="$(ctlpw screen-agent status 1)"; code=$?
expect "z uprawnieniem: status" "$out" "imac01: wersja: 1.0.0, załadowana: tak, uprawnienie: nadane, zalogowany: $ME"
expect_code "z uprawnieniem: status – kod 0" "$code" 0 "$out"
expect_not "status: bez wpisu w dzienniku działań" "$(cat "$SA_LOG" 2>/dev/null)" "screen-agent status"
out="$(ctlpw _builder screen-agent-permission 1)"; code=$?
expect_code "prośba o uprawnienie, gdy jest: kod 0" "$code" 0 "$out"
expect "prośba o uprawnienie, gdy jest: komunikat" "$out" "CMCR:AGENT-PERMISSION granted" "ma już uprawnienie Nagrywanie ekranu"
out="$(ctlpw screen-agent permission 1)"
expect "prośba o uprawnienie, gdy jest: cmcrctl" "$out" "→ imac01: usługa podglądu ma już uprawnienie nagrywania ekranu."

: > "$AGENT_TEST/locked"
out="$(ctlpw screen-agent status 1)"; code=$?
expect "zablokowany ekran: status" "$out" "uprawnienie: nadane" "ekran zablokowany"
expect_code "zablokowany ekran: status – kod 0" "$code" 0 "$out"
out="$(ctlpw screen-watch 1 "$WORK/sa-locked" --frames 1 --interval 2)"; code=$?
expect_code "zablokowany ekran: podgląd – kod 8 (bez komunikatu nie ma obrazu)" "$code" 8 "$out"
rm -f "$AGENT_TEST/locked"

# A student at the screen: the agent of that session, asked as root (needs the password). The status only reads, so
# the agent of that session is brought back first (it ended with the others when the run folder was gone above; the
# real launchd would have restarted it by KeepAlive).
printf daemon > "$WORK/console_user"
agent_restart "$(id -u daemon)" || fail "konto ucznia: usługa w sesji ucznia nie działa" "$(agent_ping "$(id -u daemon)")"
printf daemon > "$AGENT_TEST/user"      # the account the agent reports (here it runs as the developer)
out="$(ctlpw screen-agent status 1)"; code=$?
expect "konto ucznia: status z sesji ucznia" "$out" "uprawnienie: nadane, zalogowany: daemon"
expect_code "konto ucznia: status – kod 0" "$code" 0 "$out"
out="$(ctl screen-agent status 1)"; code=$?
expect "konto ucznia bez hasła: uprawnienie nieznane" "$out" "uprawnienie: nieznane, zalogowany: daemon"
expect_code "konto ucznia bez hasła: status – kod 1" "$code" 1 "$out"
rm -f "$WORK/console_user" "$AGENT_TEST/user"

: > "$WORK/fake-no-console"
out="$(ctlpw screen-agent status 1)"; code=$?
expect "nikt nie jest zalogowany: status" "$out" "imac01: wersja: 1.0.0, załadowana: –" "zalogowany: nikt"
expect_code "nikt nie jest zalogowany: status – kod 0" "$code" 0 "$out"
out="$(ctlpw _builder screen-agent-permission 1)"; code=$?
expect_code "nikt nie jest zalogowany: prośba o uprawnienie – kod 3" "$code" 3 "$out"
expect "nikt nie jest zalogowany: prośba o uprawnienie – komunikat" "$out" "Nikt nie jest zalogowany przy komputerze"
out="$(ctlpw screen-agent permission 1)"; code=$?
expect_code "nikt nie jest zalogowany: cmcrctl screen-agent permission – kod 1" "$code" 1 "$out"
rm -f "$WORK/fake-no-console"
out="$(ctl screen-agent status 99)"; code=$?
expect "niedostępny komputer: status" "$out" "imac99: błąd: "
expect_code "niedostępny komputer: status – kod 1" "$code" 1 "$out"

section "Usługa podglądu – każdy zrzut zastępuje poprzedni (shots/<uid>/screen-<n>.jpg)"
agent_reset
SA_SHOTS="$AGENT_ROOT/shots/$SA_UID"
out="$(ctlpw screenshot 1 "$WORK/sa-shot1.jpg")"
m1="$(md5 -q "$SA_SHOTS/screen-1.jpg" 2>/dev/null)"
: > "$AGENT_TEST/variant"
out="$(ctlpw screenshot 1 "$WORK/sa-shot2.jpg")"
m2="$(md5 -q "$SA_SHOTS/screen-1.jpg" 2>/dev/null)"
rm -f "$AGENT_TEST/variant"
[ -n "$m1" ] && [ -n "$m2" ] && [ "$m1" != "$m2" ] && pass "zrzuty: zmieniony ekran zastąpił poprzedni plik" \
  || fail "zrzuty: plik nie został zastąpiony ($m1 / $m2)" "$out"
expect_code "zrzuty: jeden plik na ekran, bez plików tymczasowych" "$(ls -A "$SA_SHOTS" | tr '\n' ' ')" "screen-1.jpg " "$(ls -la "$SA_SHOTS")"
cmp -s "$WORK/sa-shot2.jpg" "$SA_SHOTS/screen-1.jpg" && pass "zrzuty: wysłany ostatni zapis usługi" || fail "zrzuty: wysłany inny plik"
echo 2 > "$AGENT_TEST/displays"
out="$(ctlpw screen-watch 1 "$WORK/sa-all" --frames 1 --interval 2 --display all)"
expect_code "zrzuty: wszystkie ekrany – plik na każdy" "$(ls -A "$SA_SHOTS" | tr '\n' ' ')" "screen-1.jpg screen-2.jpg " "$out"
out="$(ctlpw screen-watch 1 "$WORK/sa-main" --frames 1 --interval 2 --display main)"
expect_code "zrzuty: potem tylko główny – plik drugiego ekranu usunięty" "$(ls -A "$SA_SHOTS" | tr '\n' ' ')" "screen-1.jpg " "$out"

agent_reset
agent_ensure
rm -rf "$WORK/sa-impostor" "$WORK/agent-bundle-0.9.0"
printf '%s' "$sa_settings_backup" > "$WORK/config/settings.json"
