# Screen preview engine: single captures and live streams (cmcrctl screenshot / screen-watch).
# Sourced by run.sh. A student session is simulated with $WORK/console_user (see fakes.sh): the SSH account
# is then not the console user, so capturing needs `launchctl asuser` as root through the fake sudo.

scr_settings_backup="$(cat "$WORK/config/settings.json")"
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s.update(observeAllowedUsers="", observeOnlyStandardAccounts=False, notifyOnObserve=True, screenshotMaxSize=640)
json.dump(s, open(p, "w"))
PY
scr_reset() { rm -f "$WORK/console_user" "$WORK/screencapture_fail" "$WORK/displays" "$WORK/screen_variant" "$WORK/front_app" "$WORK"/fake-notify-*; }
scr_console() { printf '%s' "$1" > "$WORK/console_user"; }
scr_count() { local n; n="$(grep -c -- "$1" "$WORK/fake.log" 2>/dev/null)"; echo "${n:-0}"; }
scr_wait_for() { # scr_wait_for FILE NEEDLE [seconds] – polls a growing file
  local i
  for i in $(seq 1 $((${3:-15} * 10))); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
scr_is_jpeg() { file "$1" 2>/dev/null | grep -q JPEG; }
scr_width() { sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null | awk '/pixel/ { if ($2 > m) m = $2 } END { print m + 0 }'; }
scr_sessions_gone() { # the test sshd has no session processes left
  local i
  # The shared ssh connection (ControlPersist) keeps one sshd-session alive by design. "-O stop" lets running
  # sessions finish, so a stream that is still open would keep it alive and still fail this check.
  "$CTL" __close-master 1 >/dev/null 2>&1
  for i in $(seq 1 50); do [ -z "$(pgrep -P "$SSHD_PID" 2>/dev/null)" ] && return 0; sleep 0.1; done
  return 1
}
scr_reset

section "Podgląd ekranów – pojedynczy zrzut"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-own.jpg")"; code=$?
expect_code "zrzut: własna sesja konta SSH – kod 0" "$code" 0 "$out"
scr_is_jpeg "$WORK/scr-own.jpg" && pass "zrzut: JPEG prosto z screencapture" || fail "zrzut: brak JPEG" "$out"
expect "zrzut: przechwytywanie od razu w JPEG" "$(fakelog)" "screencapture -x -C -m -t jpg"
expect_not "zrzut: bez PNG" "$(fakelog)" "-t png"
expect_code "zrzut: własna sesja bez sudo" "$(scr_count '^sudo ')" 0 "$(fakelog)"
w="$(scr_width "$WORK/scr-own.jpg")"
[ "$w" -gt 0 ] && [ "$w" -le 640 ] && pass "zrzut: pomniejszony do limitu (${w} px)" || fail "zrzut: rozmiar $w px"

scr_console daemon
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-student.jpg")"; code=$?
expect_code "zrzut ucznia: kod 0" "$code" 0 "$out"
scr_is_jpeg "$WORK/scr-student.jpg" && pass "zrzut ucznia: JPEG przez launchctl asuser" || fail "zrzut ucznia: brak JPEG" "$out"
expect_code "zrzut ucznia: dokładnie jedno sudo na klatkę" "$(scr_count '^sudo ')" 1 "$(fakelog)"
expect "zrzut ucznia: powiadomienie w sesji ucznia" "$(fakelog)" "observe-notice: gui"
expect "zrzut ucznia: aplikacja na pierwszym planie odczytana" "$(fakelog)" "lsappinfo info -only name ASN:"

clear_fakelog
out="$(CMCR_PASSWORD="zle-haslo" "$CTL" screenshot 1 "$WORK/scr-wrong.jpg" 2>&1)"
expect "zrzut ucznia: błędne hasło nazwane wprost" "$out" "Błędne hasło administratora"
expect_not "zrzut ucznia: błędne hasło to nie brak uprawnienia Nagrywanie ekranu" "$out" "Nagrywanie"
expect_not "zrzut ucznia: błędne hasło – nic nie przechwycono" "$(fakelog)" "screencapture"
[ ! -f "$WORK/scr-wrong.jpg" ] && pass "zrzut ucznia: błędne hasło – brak pliku" || fail "zrzut ucznia: plik mimo błędu"

clear_fakelog
out="$(ctl screenshot 1 "$WORK/scr-nopw.jpg")"
expect "zrzut ucznia: brak hasła – wskazówka" "$out" "zapisz hasło administratora"
expect_not "zrzut ucznia: brak hasła to nie brak uprawnienia Nagrywanie ekranu" "$out" "Nagrywanie"
expect_not "zrzut ucznia: brak hasła – bez prób hasła" "$(fakelog)" "Sorry"
out="$(ctl screen-watch 1 "$WORK/scr-nopw" --frames 1 --interval 2)"; code=$?
expect "na żywo: brak hasła – wskazówka" "$out" "zapisz hasło administratora"
expect_code "na żywo: brak hasła – kod 6" "$code" 6 "$out"

scr_console root
out="$(ctlpw screenshot 1 "$WORK/scr-login.jpg")"
expect "zrzut: okno logowania" "$out" "Nikt nie jest zalogowany"
out="$(ctlpw screen-watch 1 "$WORK/scr-login" --frames 1 --interval 2)"; code=$?
expect_code "na żywo: okno logowania – kod 3" "$code" 3 "$out"

scr_reset
touch "$WORK/screencapture_fail"
out="$(ctlpw screenshot 1 "$WORK/scr-tcc.jpg")"
expect "zrzut: brak uprawnienia Nagrywanie ekranu" "$out" "Nagrywanie ekranu" "sshd-keygen-wrapper"
out="$(ctlpw screen-watch 1 "$WORK/scr-tcc" --frames 1 --interval 2)"; code=$?
expect "na żywo: brak uprawnienia Nagrywanie ekranu" "$out" "Nagrywanie ekranu"
expect_code "na żywo: brak uprawnienia – kod 5" "$code" 5 "$out"
scr_reset

section "Podgląd ekranów – sesja na żywo (screen-watch)"
scr_console daemon
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/scr-live" --frames 3 --interval 2)"; code=$?
expect_code "na żywo: kod 0" "$code" 0 "$out"
expect "na żywo: jedna sesja root" "$out" "jedno sudo na całą sesję"
expect "na żywo: użytkownik i aplikacja na pierwszym planie" "$out" "Użytkownik: daemon" "na pierwszym planie: Przeglądarka Testowa"
expect "na żywo: pierwsza klatka" "$out" "Klatka 1: nowy obraz"
expect "na żywo: niezmieniony ekran nie jest przesyłany ponownie" "$out" "Klatka 2: bez zmian" "Klatka 3: bez zmian"
expect_code "na żywo: jedno sudo na trzy klatki" "$(scr_count '^sudo ')" 1 "$(fakelog)"
expect_code "na żywo: trzy przechwycenia" "$(scr_count '^screencapture ')" 3 "$(fakelog)"
expect_code "na żywo: jedno powiadomienie na sesję" "$(scr_count 'observe-notice:')" 1 "$(fakelog)"
f="$(ls "$WORK/scr-live"/*.jpg 2>/dev/null | head -1)"
[ -n "$f" ] && scr_is_jpeg "$f" && pass "na żywo: klatka zapisana jako JPEG" || fail "na żywo: brak klatki" "$(ls -la "$WORK/scr-live" 2>&1)"
scr_sessions_gone && pass "na żywo: sesja zamknięta po zakończeniu podglądu" || fail "na żywo: zostały procesy sesji" "$(pgrep -lP "$SSHD_PID")"

clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/scr-live2" --frames 1 --interval 2 --notified-user daemon)"
expect "na żywo: kontynuacja sesji obserwacji" "$out" "Klatka 1: nowy obraz"
expect_code "na żywo: ten sam użytkownik nie jest powiadamiany ponownie" "$(scr_count 'observe-notice:')" 0 "$(fakelog)"

clear_fakelog
ctlpw screen-watch 1 "$WORK/scr-live3" --frames 3 --interval 2 > "$WORK/scr-live3.out" 2>&1 &
scr_pid=$!
scr_wait_for "$WORK/scr-live3.out" "Klatka 1:" 20
scr_console nobody
echo nowy > "$WORK/screen_variant"
wait "$scr_pid"
out="$(cat "$WORK/scr-live3.out")"
expect "na żywo: zmiana użytkownika – nowe powiadomienie" "$out" "Powiadomiono użytkownika daemon" "Powiadomiono użytkownika nobody"
expect_code "na żywo: zmiana użytkownika – dwa powiadomienia" "$(scr_count 'observe-notice:')" 2 "$(fakelog)"
expect "na żywo: zmieniony ekran przesłany ponownie" "$out" "Klatka 2: nowy obraz"
expect_code "na żywo: zmiana użytkownika bez ponownego sudo" "$(scr_count '^sudo ')" 1 "$(fakelog)"
rm -f "$WORK/screen_variant"

scr_console root
clear_fakelog
ctlpw screen-watch 1 "$WORK/scr-live4" --frames 2 --interval 2 > "$WORK/scr-live4.out" 2>&1 &
scr_pid=$!
scr_wait_for "$WORK/scr-live4.out" "Nikt nie jest zalogowany" 20
scr_console daemon
wait "$scr_pid"
out="$(cat "$WORK/scr-live4.out")"
expect "na żywo: okno logowania bez sudo" "$out" "bez sudo" "Nikt nie jest zalogowany"
expect "na żywo: po zalogowaniu ucznia jedno sudo i obraz" "$out" "jedno sudo na całą sesję" "nowy obraz"
expect_code "na żywo: logowanie ucznia – jedno sudo" "$(scr_count '^sudo ')" 1 "$(fakelog)"

clear_fakelog
out="$(CMCR_PASSWORD="zle-haslo" "$CTL" screen-watch 1 "$WORK/scr-live5" --frames 2 --interval 2 2>&1)"; code=$?
expect "na żywo: błędne hasło nazwane wprost" "$out" "Błędne hasło administratora"
expect_not "na żywo: błędne hasło to nie Nagrywanie ekranu" "$out" "Nagrywanie"
expect_code "na żywo: błędne hasło – kod 6" "$code" 6 "$out"

python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["observeAllowedUsers"] = "ktos-inny"; json.dump(s, open(p, "w"))
PY
clear_fakelog
out="$(ctl screen-watch 1 "$WORK/scr-live6" --frames 1 --interval 2)"
expect "na żywo: konto spoza listy dozwolonych" "$out" "nie jest na liście kont dozwolonych"
expect_not "na żywo: zablokowane konto – nic nie przechwycono" "$(fakelog)" "screencapture"
expect_not "na żywo: zablokowane konto – bez sudo" "$(fakelog)" "sudo"
expect_not "na żywo: zablokowane konto – bez powiadomienia" "$(fakelog)" "observe-notice"
expect_not "na żywo: zablokowane konto – aplikacja nie jest odczytywana" "$out" "Przeglądarka Testowa"
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["observeAllowedUsers"] = ""; json.dump(s, open(p, "w"))
PY

scr_reset
echo 2 > "$WORK/displays"
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/scr-live7" --frames 1 --interval 2 --display all)"
expect "na żywo: wszystkie ekrany" "$out" "ekran 1/2" "ekran 2/2"
n="$(ls "$WORK/scr-live7"/*.jpg 2>/dev/null | wc -l | tr -d ' ')"
expect_code "na żywo: osobny obraz dla każdego ekranu" "$n" 2 "$(ls -la "$WORK/scr-live7" 2>&1)"

section "Podgląd ekranów – bez potwierdzonego powiadomienia nie ma obrazu"
scr_reset
scr_console daemon
touch "$WORK/fake-notify-fail"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-nonotice.jpg")"; code=$?
[ "$code" -ne 0 ] && pass "powiadomienie nieudane: zrzut kończy się błędem" || fail "powiadomienie nieudane: kod 0" "$out"
expect "powiadomienie nieudane: czytelny powód" "$out" "nie udało się wyświetlić informacji o podglądzie" "daemon" \
  "Connection to the window server refused"
expect_not "powiadomienie nieudane: nie zgłoszono powiadomienia" "$out" "Powiadomiono"
[ ! -f "$WORK/scr-nonotice.jpg" ] && pass "powiadomienie nieudane: brak pliku" || fail "powiadomienie nieudane: zapisano obraz"
expect "powiadomienie nieudane: próba w sesji ucznia" "$(fakelog)" "observe-notice: gui"
expect_not "powiadomienie nieudane: ekran nie został przechwycony" "$(fakelog)" "screencapture"
expect_not "powiadomienie nieudane: aplikacja na pierwszym planie nie jest odczytywana" "$(fakelog)" "lsappinfo"

out="$(ctlpw screen-watch 1 "$WORK/scr-nonotice" --frames 1 --interval 2)"; code=$?
expect_code "na żywo: powiadomienie nieudane – kod 8" "$code" 8 "$out"
expect "na żywo: powiadomienie nieudane – powód" "$out" "Na ekranie użytkownika daemon nie udało się wyświetlić"
n="$(ls "$WORK/scr-nonotice"/*.jpg 2>/dev/null | wc -l | tr -d ' ')"
expect_code "na żywo: powiadomienie nieudane – żadnej klatki" "$n" 0 "$out"

# The next cycle tries again; the first frame comes only after a confirmed notice.
clear_fakelog
ctlpw screen-watch 1 "$WORK/scr-notice-retry" --frames 3 --interval 2 > "$WORK/scr-notice-retry.out" 2>&1 &
scr_pid=$!
scr_wait_for "$WORK/scr-notice-retry.out" "nie udało się wyświetlić" 20
expect_code "na żywo: przed powiadomieniem brak przechwycenia" "$(scr_count '^screencapture ')" 0 "$(fakelog)"
rm -f "$WORK/fake-notify-fail"
wait "$scr_pid"
out="$(cat "$WORK/scr-notice-retry.out")"
expect "na żywo: ponowna próba powiadomienia, potem obraz" "$out" "Powiadomiono użytkownika daemon" "nowy obraz"
notices="$(scr_count 'observe-notice:')"
[ "$notices" -ge 2 ] && pass "na żywo: powiadomienie ponowione w kolejnym cyklu ($notices)" || fail "na żywo: brak ponownej próby ($notices)" "$(fakelog)"
order="$(awk '/observe-notice:/ {n++} /^screencapture / {print (n >= 2 ? "ok" : "za wcześnie"); exit}' "$WORK/fake.log")"
[ "$order" = ok ] && pass "na żywo: pierwsza klatka dopiero po potwierdzonym powiadomieniu" \
  || fail "na żywo: przechwycenie przed powiadomieniem (${order:-brak})" "$(fakelog)"

touch "$WORK/fake-notify-hidden"
out="$(ctlpw screenshot 1 "$WORK/scr-hidden.jpg")"
expect "powiadomienie niewidoczne: obraz nie jest pobierany" "$out" "okno komunikatu nie pojawiło się na ekranie"
[ ! -f "$WORK/scr-hidden.jpg" ] && pass "powiadomienie niewidoczne: brak pliku" || fail "powiadomienie niewidoczne: zapisano obraz"
rm -f "$WORK/fake-notify-hidden"

touch "$WORK/fake-notify-silent"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-silent.jpg")"
expect "powiadomienie bez potwierdzenia: limit czasu" "$out" "brak potwierdzenia wyświetlenia"
expect_not "powiadomienie bez potwierdzenia: ekran nie został przechwycony" "$(fakelog)" "screencapture"
rm -f "$WORK/fake-notify-silent"

# A hung osascript (no answer, never quits): after the 6 s the attempt stops it with everything under it
# (launchctl asuser, sudo -u), instead of leaving one more behind on every cycle.
scr_hung() { pgrep -f "cmcr-fake-osascript $WORK/" 2>/dev/null | wc -l | tr -d ' '; }
scr_no_hung() { # scr_no_hung NAME – no hung fake osascript is left (signals may take a moment)
  local i
  for i in $(seq 1 20); do [ "$(scr_hung)" = 0 ] && break; sleep 0.1; done
  expect_code "$1" "$(scr_hung)" 0 "$(pgrep -lf "cmcr-fake-osascript $WORK/" 2>&1)"
}
touch "$WORK/fake-notify-hang"
out="$(ctlpw screenshot 1 "$WORK/scr-hang.jpg")"
expect "powiadomienie zawieszone (sesja ucznia): limit czasu" "$out" "brak potwierdzenia wyświetlenia"
scr_no_hung "powiadomienie zawieszone (sesja ucznia): po limicie czasu nie zostaje osascript"
rm -f "$WORK/console_user"
out="$(ctlpw screenshot 1 "$WORK/scr-hang-own.jpg")"
expect "powiadomienie zawieszone (własna sesja): limit czasu" "$out" "brak potwierdzenia wyświetlenia"
scr_no_hung "powiadomienie zawieszone (własna sesja): po limicie czasu nie zostaje osascript"
rm -f "$WORK/fake-notify-hang"
pkill -f "cmcr-fake-osascript $WORK/" 2>/dev/null
scr_console daemon

# Own session of the SSH account (no sudo): the same rule.
rm -f "$WORK/console_user"
touch "$WORK/fake-notify-fail"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-own-nonotice.jpg")"
expect "własna sesja: powiadomienie nieudane – obraz nie jest pobierany" "$out" "nie udało się wyświetlić informacji o podglądzie"
expect "własna sesja: próba powiadomienia bez launchctl" "$(fakelog)" "observe-notice: own"
expect_not "własna sesja: ekran nie został przechwycony" "$(fakelog)" "screencapture"

scr_reset
printf '%s' "$scr_settings_backup" > "$WORK/config/settings.json"
