# Student notice of the screen preview (AUDIT KON-06, ZAJ-04, ZAJ-05). Sourced by Tests/e2e/run.sh.
# The console user is simulated with $WORK/console_user (fakes.sh); the notice panel with fake osascript.

nt_settings_backup="$(cat "$WORK/config/settings.json")"
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
# KON-06: an old settings file that switched the notice off – it must not matter any more.
s.update(observeAllowedUsers="", observeOnlyStandardAccounts=False, notifyOnObserve=False, screenshotMaxSize=640)
json.dump(s, open(p, "w"))
PY
nt_reset() { rm -f "$WORK/console_user" "$WORK"/fake-notify-* "$WORK/screen_variant"; }
nt_console() { printf '%s' "$1" > "$WORK/console_user"; }
nt_count() { local n; n="$(grep -c -- "$1" "$WORK/fake.log" 2>/dev/null)"; echo "${n:-0}"; }
nt_wait_for() { # nt_wait_for FILE NEEDLE [seconds] – polls a growing file
  local i
  for i in $(seq 1 $((${3:-15} * 10))); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
nt_reset

section "Komunikat o podglądzie – zawsze, także przy starym ustawieniu wyłączającym (AUDIT KON-06)"
nt_console daemon
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-always" --frames 1 --interval 2)"; code=$?
expect_code "podgląd: kod 0" "$code" 0 "$out"
expect "podgląd: uczeń powiadomiony mimo notifyOnObserve=false" "$out" "Powiadomiono użytkownika daemon"
expect_code "podgląd: jedno powiadomienie" "$(nt_count 'observe-notice:')" 1 "$(fakelog)"

section "Komunikat o podglądzie – po wylogowaniu i zalogowaniu na to samo konto (AUDIT ZAJ-04)"
# The account at the screen is the SSH account here, so its real loginwindow process identifies the login:
# knowing only the account name (as before the fix) is not enough to skip the notice.
nt_console "$ME"
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-session" --frames 1 --interval 2 --notified-user "$ME")"
expect "sesja logowania: sama nazwa konta nie wystarcza – nowe powiadomienie" "$out" "Powiadomiono użytkownika $ME"
expect_code "sesja logowania: jedno powiadomienie" "$(nt_count 'observe-notice:')" 1 "$(fakelog)"
lw="$(pgrep -u "$(id -u)" -x loginwindow | head -n 1)"
if [ -n "$lw" ]; then
  clear_fakelog
  out="$(ctlpw screen-watch 1 "$WORK/nt-session2" --frames 1 --interval 2 --notified-user "$ME#$lw")"
  expect "sesja logowania: ta sama sesja – obraz bez ponownego komunikatu" "$out" "Klatka 1: nowy obraz"
  expect_code "sesja logowania: ta sama sesja – brak powiadomienia" "$(nt_count 'observe-notice:')" 0 "$(fakelog)"
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
expect_code "ponowne zalogowanie na to samo konto: drugie powiadomienie" "$(nt_count 'observe-notice:')" 2 "$out
$(fakelog)"

section "Komunikat o podglądzie – zablokowany lub uśpiony ekran (AUDIT ZAJ-05)"
nt_console daemon
touch "$WORK/fake-notify-locked"
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-locked" --frames 1 --interval 2)"
expect "zablokowany ekran: komunikat nie liczy się jako pokazany" "$out" "zablokowany lub uśpiony"
expect_not "zablokowany ekran: nie powiadomiono" "$out" "Powiadomiono"
expect_code "zablokowany ekran: obraz nie jest pobierany" "$(nt_count '^screencapture ')" 0 "$(fakelog)"
rm -f "$WORK/fake-notify-locked"

# The attention mode's lock covers the panel: no notice is attempted and nothing is captured.
# LockScreen of the attention mode is simulated by fakes.sh (pgrep -x LockScreen answers from a state file).
NT_LOCK_STATE="$WORK/lockscreen.running"     # _e2e_state lockscreen.running in fakes.sh
touch "$NT_LOCK_STATE"
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/nt-attention" --frames 1 --interval 2)"
rm -f "$NT_LOCK_STATE"
expect "tryb uwagi: komunikat poczeka na odblokowanie" "$out" "zablokowany w trybie uwagi"
expect_code "tryb uwagi: bez próby komunikatu" "$(nt_count 'observe-notice:')" 0 "$(fakelog)"
expect_code "tryb uwagi: obraz nie jest pobierany" "$(nt_count '^screencapture ')" 0 "$(fakelog)"

nt_reset
printf '%s' "$nt_settings_backup" > "$WORK/config/settings.json"
