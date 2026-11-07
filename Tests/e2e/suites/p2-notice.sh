# Student notice of the screen preview (AUDIT KON-06, ZAJ-04, ZAJ-05). Sourced by Tests/e2e/run.sh.
# The console user is simulated with $WORK/console_user (fakes.sh); the notice panel is CMCR Screen Agent's (test mode:
# $AGENT_TEST/notice and locked set its answer, requests.log lists the notices and captures it was asked for).

nt_settings_backup="$(cat "$WORK/config/settings.json")"
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
# The notice is off by default; these tests switch it on (the old notifyOnObserve key is ignored either way).
s.update(observeAllowedUsers="", observeOnlyStandardAccounts=False, observeNotifyStudent=True, notifyOnObserve=False,
         screenshotMaxSize=640)
json.dump(s, open(p, "w"))
PY
nt_reset() { rm -f "$WORK/console_user"; agent_reset; }
nt_console() { printf '%s' "$1" > "$WORK/console_user"; }
nt_wait_for() { # nt_wait_for FILE NEEDLE [seconds] – polls a growing file
  local i
  for i in $(seq 1 $((${3:-15} * 10))); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
nt_reset
agent_ensure

section "Komunikat o podglądzie – gdy włączony w ustawieniach, także przy starym kluczu notifyOnObserve=false (AUDIT KON-06)"
nt_console daemon
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-always" --frames 1 --interval 2)"; code=$?
expect_code "podgląd: kod 0" "$code" 0 "$out"
expect "podgląd: uczeń powiadomiony (stary klucz notifyOnObserve=false nie ma znaczenia)" "$out" "Powiadomiono użytkownika daemon"
expect_code "podgląd: jedno powiadomienie" "$(agent_count '^CMCRA1 NOTICE ')" 1 "$(agentlog)"
expect "podgląd: treść powiadomienia" "$(agentlog)" "NOTICE-TEXT Podgląd ekranu | Administrator rozpoczął podgląd Twojego ekranu."

section "Komunikat o podglądzie – po wylogowaniu i zalogowaniu na to samo konto (AUDIT ZAJ-04)"
# The account at the screen is the SSH account here, so its real loginwindow process identifies the login:
# knowing only the account name (as before the fix) is not enough to skip the notice.
nt_console "$ME"
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-session" --frames 1 --interval 2 --notified-user "$ME")"
expect "sesja logowania: sama nazwa konta nie wystarcza – nowe powiadomienie" "$out" "Powiadomiono użytkownika $ME"
expect_code "sesja logowania: jedno powiadomienie" "$(agent_count '^CMCRA1 NOTICE ')" 1 "$(agentlog)"
lw="$(pgrep -u "$(id -u)" -x loginwindow | head -n 1)"
if [ -n "$lw" ]; then
  clear_fakelog
  out="$(ctlpw screen-watch 1 "$WORK/nt-session2" --frames 1 --interval 2 --notified-user "$ME#$lw")"
  expect "sesja logowania: ta sama sesja – obraz bez ponownego komunikatu" "$out" "Klatka 1: nowy obraz"
  expect_code "sesja logowania: ta sama sesja – brak powiadomienia" "$(agent_count '^CMCRA1 NOTICE ')" 0 "$(agentlog)"
fi

nt_console daemon
clear_fakelog
ctlpw screen-watch 1 "$WORK/nt-relogin" --frames 4 --interval 2 > "$WORK/nt-relogin.out" 2>&1 &
nt_pid=$!
nt_wait_for "$WORK/nt-relogin.out" "Klatka 1:" 20
nt_console root                       # logged out: the login window
nt_wait_for "$WORK/nt-relogin.out" "Nikt nie jest zalogowany" 20
nt_console daemon                     # the same account logs in again
wait "$nt_pid"
out="$(cat "$WORK/nt-relogin.out")"
expect_code "ponowne zalogowanie na to samo konto: drugie powiadomienie" "$(agent_count '^CMCRA1 NOTICE ')" 2 "$out
$(agentlog)"

section "Komunikat o podglądzie – zablokowany lub uśpiony ekran (AUDIT ZAJ-05)"
nt_console daemon
: > "$AGENT_TEST/locked"                     # the agent answers NOTICE locked (and ERR locked to a capture)
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-locked" --frames 1 --interval 2)"; code=$?
expect "zablokowany ekran: komunikat nie liczy się jako pokazany" "$out" "zablokowany lub uśpiony"
expect_not "zablokowany ekran: nie powiadomiono" "$out" "Powiadomiono"
expect_code "zablokowany ekran: kod 8" "$code" 8 "$out"
expect_code "zablokowany ekran: obraz nie jest pobierany" "$(agent_count '^CMCRA1 CAPTURE ')" 0 "$(agentlog)"
# Told already in this session, then the screen locks: the agent refuses the capture (ERR locked), which counts as a
# notice that nobody can see – no image (AUDIT ZAJ-05).
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-locked2" --frames 1 --interval 2 --notified-user daemon)"; code=$?
expect "zablokowany ekran przy zrzucie: komunikat po odblokowaniu" "$out" \
  "ekran jest zablokowany – komunikat zostanie pokazany po jego odblokowaniu"
expect_code "zablokowany ekran przy zrzucie: kod 8" "$code" 8 "$out"
expect "zablokowany ekran przy zrzucie: usługa odmówiła zrzutu" "$(agentlog)" "CMCRA1 CAPTURE "
n="$(ls "$WORK/nt-locked2"/*.jpg 2>/dev/null | wc -l | tr -d ' ')"
expect_code "zablokowany ekran przy zrzucie: żadnej klatki" "$n" 0 "$out"
rm -f "$AGENT_TEST/locked"

# The attention mode's lock covers the panel: no notice is attempted and nothing is captured.
# LockScreen of the attention mode is simulated by fakes.sh (pgrep -x LockScreen answers from a state file).
NT_LOCK_STATE="$WORK/lockscreen.running"     # _e2e_state lockscreen.running in fakes.sh
touch "$NT_LOCK_STATE"
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-attention" --frames 1 --interval 2)"
rm -f "$NT_LOCK_STATE"
expect "tryb uwagi: komunikat poczeka na odblokowanie" "$out" "zablokowany w trybie uwagi"
expect_code "tryb uwagi: bez próby komunikatu" "$(agent_count '^CMCRA1 NOTICE ')" 0 "$(agentlog)"
expect_code "tryb uwagi: obraz nie jest pobierany" "$(agent_count '^CMCRA1 CAPTURE ')" 0 "$(agentlog)"

# The notice is off by default (no observeNotifyStudent in the settings file) and when switched off explicitly: no
# notice is requested, the picture is taken at once, and the actions log says that the preview ran without telling
# the student.
nt_reset
nt_console daemon
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s.pop("observeNotifyStudent", None); s.update(notifyOnObserve=True); json.dump(s, open(p, "w"))
PY
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-off" --frames 1 --interval 2)"; code=$?
expect_code "powiadomienie wyłączone: kod 0" "$code" 0 "$out"
expect_code "powiadomienie wyłączone: bez prośby o komunikat" "$(agent_count '^CMCRA1 NOTICE ')" 0 "$(agentlog)"
expect_code "powiadomienie wyłączone: obraz pobrany od razu" "$(agent_count '^CMCRA1 CAPTURE ')" 1 "$(agentlog)"
expect "powiadomienie wyłączone: wpis w dzienniku działań" "$(cat "$WORK/config/actions.log" 2>/dev/null)" "bez powiadomienia ucznia (wyłączone w ustawieniach)"
expect_not "powiadomienie wyłączone: brak wpisu o powiadomieniu" "$out" "Powiadomiono użytkownika"
# The same with the value saved explicitly.
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s.update(observeNotifyStudent=False); json.dump(s, open(p, "w"))
PY
nt_reset
nt_console daemon
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-off2" --frames 1 --interval 2)"
expect_code "powiadomienie wyłączone jawnie: bez prośby o komunikat" "$(agent_count '^CMCRA1 NOTICE ')" 0 "$(agentlog)"
expect_not "powiadomienie wyłączone jawnie: brak wpisu o powiadomieniu" "$out" "Powiadomiono użytkownika"
# Switched on in the settings (and the old key false next to it changes nothing): the notice is back.
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s.update(observeNotifyStudent=True, notifyOnObserve=False); json.dump(s, open(p, "w"))
PY
nt_reset
nt_console daemon
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-on" --frames 1 --interval 2)"
expect "powiadomienie włączone ponownie: uczeń powiadomiony" "$out" "Powiadomiono użytkownika daemon"
expect_code "powiadomienie włączone ponownie: jedno powiadomienie" "$(agent_count '^CMCRA1 NOTICE ')" 1 "$(agentlog)"

nt_reset
printf '%s' "$nt_settings_backup" > "$WORK/config/settings.json"
