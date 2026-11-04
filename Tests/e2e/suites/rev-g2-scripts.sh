# Review of the audit fixes, group G2 (remote scripts): Screen Sharing access list, gentle logout with the
# administrator's background session, the attention-lock check of the screen preview and uninstalling apps whose
# names are stored decomposed (AUDIT REV-06 … REV-09). Sourced by Tests/e2e/run.sh (helpers: section, pass, fail,
# expect, expect_not, expect_code, ctl, ctlpw, fakelog, clear_fakelog). Everything runs against folders inside
# $WORK and the fakes in fakes.sh (control files in $WORK).

RV="$WORK/rev-g2"
mkdir -p "$RV"
rv_count() { local n; n="$(grep -c -- "$1" "$WORK/fake.log" 2>/dev/null)"; echo "${n:-0}"; }

section "REV-06: szybka naprawa VNC nie obiecuje „tylko administratorzy”, gdy na liście są inne konta"
# The access lists are simulated while $WORK/setup-sys/groups exists (fakes.sh): "nested GUID" / "member NAME".
mkdir -p "$WORK/setup-sys/groups"
RV_G="$WORK/setup-sys/groups/com.apple.access_screensharing"
RV_ADMIN_GUID="$(dsmemberutil getuuid -G admin 2>/dev/null)"
# „Tylko ci użytkownicy” chosen earlier, with the students' shared account added (it is not an administrator).
printf 'nested %s\nmember cmcr-rev-uczen\n' "$RV_ADMIN_GUID" > "$RV_G"
: > "$WORK/setup-sys/off-com.apple.screensharing"
clear_fakelog
out="$(ctlpw _builder screen-sharing 1)"; code=$?
expect_code "VNC, konto ucznia na liście: usługa włączona – kod 0" "$code" 0 "$out"
expect_not "VNC, konto ucznia na liście: bez „tylko administratorzy”" "$out" "ekranu: tylko administratorzy"
expect "VNC, konto ucznia na liście: ostrzeżenie z nazwą konta" "$out" "⚠︎" "bez uprawnień administratora" "cmcr-rev-uczen"
# A list switched off in System Settings (…-disabled) comes back with its members: they are named too.
rm -f "$RV_G"
printf 'member cmcr-rev-uczen\n' > "$RV_G-disabled"
: > "$WORK/setup-sys/off-com.apple.screensharing"
clear_fakelog
out="$(ctlpw _builder screen-sharing 1)"; code=$?
expect "VNC, przywrócona lista: przywrócona" "$(fakelog)" "dscl . -change /Groups/com.apple.access_screensharing-disabled"
expect_not "VNC, przywrócona lista z kontem ucznia: bez „tylko administratorzy”" "$out" "ekranu: tylko administratorzy"
expect "VNC, przywrócona lista z kontem ucznia: ostrzeżenie" "$out" "cmcr-rev-uczen"
# Only the administrators: the promise stays.
printf 'nested %s\n' "$RV_ADMIN_GUID" > "$RV_G"
rm -f "$RV_G-disabled"
out="$(ctlpw _builder screen-sharing 1)"; code=$?
expect_code "VNC, tylko administratorzy: kod 0" "$code" 0 "$out"
expect "VNC, tylko administratorzy: komunikat" "$out" "tylko administratorzy"
expect_not "VNC, tylko administratorzy: bez ostrzeżenia" "$out" "⚠︎"
rm -rf "$WORK/setup-sys"

section "REV-07: „Wyloguj (z pytaniem o zapis)” pomija sesję w tle konta administratora"
# Real GUI sessions of other accounts on this Mac would count as students' sessions in the background.
others="$(ctl exec 'cmcr_gui_sessions | awk -v a="$CMCR_ADMIN_USER" "\$2 != a" | wc -l' 1 | tail -1 | tr -d ' ')"
if [ "$others" = 0 ]; then
  # The administrator (the SSH account) left its session in the background after „Przełącz użytkownika”.
  echo "$(id -u) $ME" > "$WORK/ps.sessions"
  printf '%s' daemon > "$WORK/console_user"        # a student at the screen (uid 1: no GUI session listed)
  out="$(ctlpw _builder logout 1 --wait 1)"; code=$?
  expect "logout z pytaniem: uczeń wylogowany" "$out" "Wylogowano daemon"
  expect_not "logout z pytaniem: sesja administratora nie jest zgłaszana jako sesja w tle" "$out" "W tle działa jeszcze sesja"
  expect_code "logout z pytaniem: sesja administratora w tle – kod 0" "$code" 0 "$out"
  rm -f "$WORK/console_user"
  : > "$WORK/fake-no-console"                       # nobody at the screen, only the administrator in the background
  out="$(ctlpw _builder logout 1 --wait 1)"; code=$?
  expect_code "logout z pytaniem, ekran logowania + sesja administratora: kod 0" "$code" 0 "$out"
  expect_not "logout z pytaniem, ekran logowania + sesja administratora: bez błędu" "$out" "w tle działa sesja"
  expect "logout z pytaniem, ekran logowania + sesja administratora: nikt nie jest zalogowany" "$out" "CMCR:NOUSER"
  # A student's session in the background is still reported (AUDIT DOD-03), without the administrator's.
  printf '%s %s\n502 cmcr-rev-uczen\n' "$(id -u)" "$ME" > "$WORK/ps.sessions"
  out="$(ctlpw _builder logout 1 --wait 1)"; code=$?
  expect_code "logout z pytaniem, sesja ucznia w tle: kod 1" "$code" 1 "$out"
  expect "logout z pytaniem, sesja ucznia w tle: zgłoszona" "$out" "w tle działa sesja: cmcr-rev-uczen."
  rm -f "$WORK/ps.sessions" "$WORK/fake-no-console"
else
  pass "logout z pytaniem i sesja administratora: pominięto (na tym Macu są sesje innych kont)"
fi

section "REV-08: pozostały licznik automatycznego odblokowania nie blokuje podglądu"
rv_settings_backup="$(cat "$WORK/config/settings.json")"
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s.update(observeAllowedUsers="", observeOnlyStandardAccounts=False, screenshotMaxSize=640)
json.dump(s, open(p, "w"))
PY
rm -f "$WORK"/fake-notify-* "$WORK/attention.running" "$WORK/lockscreen.running"
printf '%s' daemon > "$WORK/console_user"           # a new student at the screen, not the SSH account
# The auto-unlock timer of lockScreen as it stays after a logout: root's bash with the tag in its arguments (here
# the test account's; the student at the screen is another account).
/bin/bash --noprofile --norc -c 'sleep "$1"; exit 0' "CMCR_ATTENTION-unlock" 300 "CMCR_ATTENTION" "$RV/" </dev/null >/dev/null 2>&1 &
RV_TIMER=$!
sleep 0.3
case "$(ps -p "$RV_TIMER" -o command= 2>/dev/null)" in
  *CMCR_ATTENTION*) pass "licznik odblokowania: proces z etykietą trybu uwagi działa" ;;
  *) fail "licznik odblokowania: nie wystartował" ;;
esac
clear_fakelog
out="$(ctlpw screen-watch 1 "$RV/watch-timer" --frames 1 --interval 2)"; code=$?
expect_not "licznik odblokowania bez blokady: nie twierdzi, że ekran jest zablokowany" "$out" "zablokowany w trybie uwagi"
expect "licznik odblokowania bez blokady: uczeń powiadomiony" "$out" "Powiadomiono użytkownika daemon"
if [ "$(rv_count '^screencapture ')" -gt 0 ]; then pass "licznik odblokowania bez blokady: obraz pobrany"
else fail "licznik odblokowania bez blokady: obraz nie został pobrany" "$(fakelog)"; fi
# The overlay itself (in the student's session) still holds the notice back (AUDIT ZAJ-05).
: > "$WORK/attention.running"
clear_fakelog
out="$(ctlpw screen-watch 1 "$RV/watch-overlay" --frames 1 --interval 2)"
rm -f "$WORK/attention.running"
expect "komunikat trybu uwagi na ekranie: powiadomienie czeka" "$out" "zablokowany w trybie uwagi"
expect_code "komunikat trybu uwagi na ekranie: obraz nie jest pobierany" "$(rv_count '^screencapture ')" 0 "$(fakelog)"
pkill -P "$RV_TIMER" 2>/dev/null; kill "$RV_TIMER" 2>/dev/null; wait "$RV_TIMER" 2>/dev/null
rm -f "$WORK/console_user"
printf '%s' "$rv_settings_backup" > "$WORK/config/settings.json"

section "REV-09: odinstalowanie zamyka aplikację, której nazwa na dysku jest rozłożona (NFD)"
# A bundle copied from an HFS+ image keeps its decomposed name on APFS; cmcr_ps lists processes precomposed.
RV_NFD="$(python3 -c 'import sys, unicodedata; sys.stdout.write(unicodedata.normalize("NFD", sys.argv[1]))' 'Żółw Rev')"
mkdir -p "$WORK/Applications/$RV_NFD.app/Contents/MacOS"
cp /bin/sleep "$WORK/Applications/$RV_NFD.app/Contents/MacOS/$RV_NFD"
codesign --force --sign - "$WORK/Applications/$RV_NFD.app/Contents/MacOS/$RV_NFD" >/dev/null 2>&1
RV_PID="$( ( "$WORK/Applications/$RV_NFD.app/Contents/MacOS/$RV_NFD" 300 >/dev/null 2>&1 & echo $! ) )"
sleep 0.3
if [ "$(ls "$WORK/Applications" | grep -c "$RV_NFD")" = 1 ] && kill -0 "$RV_PID" 2>/dev/null; then
  pass "NFD: aplikacja o rozłożonej nazwie działa"
else
  fail "NFD: nie udało się przygotować aplikacji" "$(ls "$WORK/Applications")"
fi
out="$(ctlpw _builder uninstall 1 "$WORK/Applications/$RV_NFD.app")"; code=$?
expect_code "NFD: kod 0" "$code" 0 "$out"
sleep 0.3
[ ! -e "$WORK/Applications/$RV_NFD.app" ] && pass "NFD: aplikacja usunięta" || fail "NFD: aplikacja nadal jest" "$out"
if kill -0 "$RV_PID" 2>/dev/null; then
  fail "NFD: proces usuniętej aplikacji nadal działa" "$out"; kill "$RV_PID" 2>/dev/null
else
  pass "NFD: proces aplikacji zakończony przed usunięciem"
fi

rm -rf "$RV"
