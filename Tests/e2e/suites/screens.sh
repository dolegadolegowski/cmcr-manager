# Screen preview engine: single captures and live streams (cmcrctl screenshot / screen-watch).
# Sourced by run.sh. The picture comes from CMCR Screen Agent (installed by run.sh, run by the fake launchd of
# fakes.sh in its test mode): files in $AGENT_TEST set what the "screen" looks like, $AGENT_TEST/requests.log lists
# what the agents were asked. A student session is simulated with $WORK/console_user: the SSH account is then not the
# console user, so the preview asks that session's agent as root through the fake sudo (one sudo per stream).

scr_settings_backup="$(cat "$WORK/config/settings.json")"
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s.update(observeAllowedUsers="", observeOnlyStandardAccounts=False, notifyOnObserve=True, screenshotMaxSize=640)
json.dump(s, open(p, "w"))
PY
scr_reset() { rm -f "$WORK/console_user"; agent_reset; }
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
SCR_UID="$(id -u)"
scr_reset
agent_ensure

section "Podgląd ekranów – pojedynczy zrzut"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-own.jpg")"; code=$?
expect_code "zrzut: własna sesja konta SSH – kod 0" "$code" 0 "$out"
scr_is_jpeg "$WORK/scr-own.jpg" && pass "zrzut: JPEG od usługi podglądu" || fail "zrzut: brak JPEG" "$out"
expect "zrzut: usługa poproszona o zrzut w rozmiarze z ustawień" "$(agentlog)" "CMCRA1 CAPTURE 640 "
expect_not "zrzut: bez screencapture" "$(fakelog)" "screencapture"
expect_code "zrzut: własna sesja bez sudo" "$(scr_count '^sudo ')" 0 "$(fakelog)"
w="$(scr_width "$WORK/scr-own.jpg")"
[ "$w" -gt 0 ] && [ "$w" -le 640 ] && pass "zrzut: pomniejszony do limitu (${w} px)" || fail "zrzut: rozmiar $w px"
cmp -s "$WORK/scr-own.jpg" "$AGENT_ROOT/shots/$SCR_UID/screen-1.jpg" \
  && pass "zrzut: wysłany dokładnie plik zapisany przez usługę" || fail "zrzut: inny plik niż zapis usługi" "$(ls -la "$AGENT_ROOT/shots/$SCR_UID" 2>&1)"

# A slow screen (the agent answers after 3 s) is still captured: the client waits up to 10 s for an answer.
echo 3 > "$AGENT_TEST/capture-delay"
out="$(ctlpw screenshot 1 "$WORK/scr-slow.jpg")"; code=$?
rm -f "$AGENT_TEST/capture-delay"
expect_code "zrzut: wolna odpowiedź usługi – kod 0" "$code" 0 "$out"
scr_is_jpeg "$WORK/scr-slow.jpg" && pass "zrzut: wolna odpowiedź usługi – obraz" || fail "zrzut: wolna odpowiedź – brak obrazu" "$out"

# macOS 15+: before capturing, the preview renews replayd's remembered consent for the screen agent (its bundle id and
# its executable), so the person at the screen is never asked whether "CMCR Screen Agent" may keep seeing the screen
# (cmcr_sc_approval). The home folder is the one under CMCR_SETUP_ROOT_PREFIX (fakes.sh), never the real one, and the
# fake pkill does not stop the real replayd.
section "Podgląd ekranów – zapamiętana zgoda replayd (macOS 15+)"
scr_home="$WORK/setup-root$HOME"
scr_plist="$scr_home/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
scr_exe_key="/Library/Application Support/CMCR/ScreenAgent/CMCR Screen Agent.app/Contents/MacOS/cmcr-screen-agent"
if [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ]; then
  # The first missing folder on the way is removed again afterwards (the setup suite expects its own tree).
  scr_made=""; scr_d="$scr_home"
  while [ "$scr_d" != "$WORK" ] && [ "$scr_d" != / ]; do [ -d "$scr_d" ] || scr_made="$scr_d"; scr_d="$(dirname "$scr_d")"; done
  mkdir -p "$scr_home"
  rm -f "$scr_plist"
  clear_fakelog
  out="$(ctlpw screenshot 1 "$WORK/scr-approval.jpg")"; code=$?
  expect_code "zgoda replayd: zrzut działa" "$code" 0 "$out"
  approvals="$(plutil -p "$scr_plist" 2>&1)"
  expect "zgoda replayd: wpisy usługi podglądu zapisane przed zrzutem" "$approvals" \
    '"pl.cmcr.manager.screen-agent" => {' "\"$scr_exe_key\" => {" \
    '"kScreenCapturePrivacyHintDate" => 2099-01-01' '"kScreenCapturePrivacyHintPolicy" => 2592000'
  expect_not "zgoda replayd: bez wpisu sesji SSH" "$approvals" "sshd-keygen-wrapper"
  expect_code "zgoda replayd: replayd zatrzymany przed zapisem i po nim" "$(scr_count '^pkill -KILL -x -U [0-9]* replayd$')" 2 "$(fakelog)"
  clear_fakelog
  out="$(ctlpw screenshot 1 "$WORK/scr-approval2.jpg")"; code=$?
  expect_code "zgoda replayd: drugi zrzut działa" "$code" 0 "$out"
  expect_code "zgoda replayd: ważna zgoda nie jest odnawiana (replayd nietknięty)" "$(scr_count 'replayd')" 0 "$(fakelog)"
  # The keys have dots and spaces (plutil splits key paths on dots), so the date is aged with plistlib.
  python3 - "$scr_plist" <<'PY'
import datetime, plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, "rb")); k = "pl.cmcr.manager.screen-agent"
if isinstance(d.get(k), dict): d[k]["kScreenCaptureApprovalLastUsed"] = datetime.datetime(2020, 1, 1)
else: d[k] = datetime.datetime(2020, 1, 1)
plistlib.dump(d, open(p, "wb"))
PY
  clear_fakelog
  ctlpw screenshot 1 "$WORK/scr-approval3.jpg" >/dev/null
  expect_code "zgoda replayd: wygasła zgoda odnowiona" "$(scr_count '^pkill -KILL -x -U [0-9]* replayd$')" 2 "$(fakelog)"
  expect_not "zgoda replayd: data użycia odświeżona" "$(plutil -p "$scr_plist" 2>&1)" "2020-01-01"
  if [ -n "$scr_made" ]; then rm -rf "$scr_made"; else rm -rf "$scr_home/Library/Group Containers/group.com.apple.replayd"; fi
else
  pass "zgoda replayd: macOS starszy niż 15 – okna nie ma, pominięto"
fi

section "Podgląd ekranów – konto ucznia (root, jedno sudo)"
scr_console daemon
agent_bootout 1                                    # the student's session has no agent running yet
printf 'Przeglądarka Testowa' > "$AGENT_TEST/front"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-student.jpg")"; code=$?
expect_code "zrzut ucznia: kod 0" "$code" 0 "$out"
scr_is_jpeg "$WORK/scr-student.jpg" && pass "zrzut ucznia: JPEG od usługi w sesji ucznia" || fail "zrzut ucznia: brak JPEG" "$out"
expect_code "zrzut ucznia: dokładnie jedno sudo na klatkę" "$(scr_count '^sudo ')" 1 "$(fakelog)"
expect "zrzut ucznia: usługa nieuruchomiona w sesji ucznia – uruchomiona przez podgląd" "$(fakelog)" \
  "launchctl enable gui/1/pl.cmcr.manager.screen-agent" "launchctl bootstrap gui/1 $WORK/setup-root/Library/LaunchAgents/pl.cmcr.manager.screen-agent.plist"
[ -n "$(agent_pid 1)" ] && pass "zrzut ucznia: usługa działa w sesji ucznia" || fail "zrzut ucznia: usługa nie działa" "$(fakelog)"
expect "zrzut ucznia: powiadomienie w sesji ucznia przed zrzutem" "$(agentlog)" \
  "NOTICE-TEXT Podgląd ekranu | Administrator rozpoczął podgląd Twojego ekranu." "CMCRA1 CAPTURE 640 "
order="$(awk '/^CMCRA1 NOTICE / {n++} /^CMCRA1 CAPTURE / {print (n >= 1 ? "ok" : "za wcześnie"); exit}' "$AGENT_TEST/requests.log")"
[ "$order" = ok ] && pass "zrzut ucznia: najpierw powiadomienie, potem obraz" || fail "zrzut ucznia: kolejność ($order)" "$(agentlog)"
shot="$AGENT_ROOT/shots/1/screen-1.jpg"
[ "$(stat -f %Lp "$shot" 2>/dev/null) $(stat -f %Lp "$AGENT_ROOT/shots/1" 2>/dev/null)" = "600 700" ] \
  && pass "zrzut ucznia: plik usługi tylko dla roota (600, katalog 700)" || fail "zrzut ucznia: prawa plików usługi" "$(ls -la "$AGENT_ROOT/shots/1" 2>&1)"

clear_fakelog
out="$(CMCR_PASSWORD="zle-haslo" "$CTL" screenshot 1 "$WORK/scr-wrong.jpg" 2>&1)"
expect "zrzut ucznia: błędne hasło nazwane wprost" "$out" "Błędne hasło administratora"
expect_not "zrzut ucznia: błędne hasło to nie brak uprawnienia Nagrywanie ekranu" "$out" "Nagrywanie"
expect_not "zrzut ucznia: błędne hasło – usługa nie była pytana" "$(agentlog)" "CMCRA1"
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
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-login.jpg")"
expect "zrzut: okno logowania" "$out" "Nikt nie jest zalogowany"
out="$(ctlpw screen-watch 1 "$WORK/scr-login" --frames 1 --interval 2)"; code=$?
expect_code "na żywo: okno logowania – kod 3" "$code" 3 "$out"
expect_not "okno logowania: usługa nie była pytana" "$(agentlog)" "CMCRA1"

# The agent has no Screen Recording permission yet: the notice was shown, the picture is refused – the message
# names the agent and where to switch it on, not the SSH session (sshd-keygen-wrapper) as before.
scr_reset
echo denied > "$AGENT_TEST/perm"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-tcc.jpg")"
expect "zrzut: brak uprawnienia Nagrywanie ekranu" "$out" "nie ma jeszcze uprawnienia do nagrywania ekranu" \
  "Nagrywanie ekranu i dźwięku systemowego" "CMCR Screen Agent"
expect_not "zrzut: brak uprawnienia – bez sesji SSH w komunikacie" "$out" "sshd-keygen-wrapper"
[ ! -f "$WORK/scr-tcc.jpg" ] && pass "zrzut: brak uprawnienia – brak pliku" || fail "zrzut: plik mimo braku uprawnienia"
start=$SECONDS
out="$(ctlpw screen-watch 1 "$WORK/scr-tcc" --frames 1 --interval 2)"; code=$?
expect "na żywo: brak uprawnienia Nagrywanie ekranu" "$out" "nie ma jeszcze uprawnienia do nagrywania ekranu"
expect_code "na żywo: brak uprawnienia – kod 5" "$code" 5 "$out"
[ $((SECONDS - start)) -lt 30 ] && pass "na żywo: brak uprawnienia – koniec po jednym cyklu ($((SECONDS - start)) s)" \
  || fail "na żywo: brak uprawnienia – czekał na limit czasu ($((SECONDS - start)) s)" "$out"
rm -f "$AGENT_TEST/perm"

# A capture that fails in the agent, and a screen that sleeps: no image, the reason in words.
printf 'testowy błąd ScreenCaptureKit' > "$AGENT_TEST/capture-fail"
out="$(ctlpw screen-watch 1 "$WORK/scr-fail" --frames 1 --interval 2)"; code=$?
expect "na żywo: nieudany zrzut usługi – powód" "$out" "Usługa podglądu nie zrobiła zrzutu ekranu" "testowy błąd ScreenCaptureKit"
expect_code "na żywo: nieudany zrzut usługi – kod 5" "$code" 5 "$out"
rm -f "$AGENT_TEST/capture-fail"
: > "$AGENT_TEST/asleep"
out="$(ctlpw screenshot 1 "$WORK/scr-asleep.jpg")"
expect "zrzut: uśpiony ekran nazwany po polsku" "$out" "ekran jest uśpiony"
[ ! -f "$WORK/scr-asleep.jpg" ] && pass "zrzut: uśpiony ekran – brak pliku" || fail "zrzut: plik mimo uśpionego ekranu"
scr_reset

section "Podgląd ekranów – sesja na żywo (screen-watch)"
scr_console daemon
printf 'Przeglądarka Testowa' > "$AGENT_TEST/front"
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/scr-live" --frames 3 --interval 2)"; code=$?
expect_code "na żywo: kod 0" "$code" 0 "$out"
expect "na żywo: jedna sesja root" "$out" "jedno sudo na całą sesję"
expect "na żywo: użytkownik i aplikacja na pierwszym planie (z odpowiedzi usługi)" "$out" "Użytkownik: daemon" "na pierwszym planie: Przeglądarka Testowa"
expect "na żywo: pierwsza klatka" "$out" "Klatka 1: nowy obraz"
expect "na żywo: niezmieniony ekran nie jest przesyłany ponownie" "$out" "Klatka 2: bez zmian" "Klatka 3: bez zmian"
expect_code "na żywo: jedno sudo na trzy klatki" "$(scr_count '^sudo ')" 1 "$(fakelog)"
expect_code "na żywo: trzy zrzuty usługi" "$(agent_count '^CMCRA1 CAPTURE ')" 3 "$(agentlog)"
expect_code "na żywo: jedno powiadomienie na sesję" "$(agent_count '^CMCRA1 NOTICE ')" 1 "$(agentlog)"
f="$(ls "$WORK/scr-live"/*.jpg 2>/dev/null | head -1)"
[ -n "$f" ] && scr_is_jpeg "$f" && pass "na żywo: klatka zapisana jako JPEG" || fail "na żywo: brak klatki" "$(ls -la "$WORK/scr-live" 2>&1)"
scr_sessions_gone && pass "na żywo: sesja zamknięta po zakończeniu podglądu" || fail "na żywo: zostały procesy sesji" "$(pgrep -lP "$SSHD_PID")"

clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/scr-live2" --frames 1 --interval 2 --notified-user daemon)"
expect "na żywo: kontynuacja sesji obserwacji" "$out" "Klatka 1: nowy obraz"
expect_code "na żywo: ten sam użytkownik nie jest powiadamiany ponownie" "$(agent_count '^CMCRA1 NOTICE ')" 0 "$(agentlog)"

# Another account logs in while the stream runs (_www, uid 70, stands in for a second student; its session has no
# agent running yet): it is told first, and its screen comes from the agent of its own session.
clear_fakelog
ctlpw screen-watch 1 "$WORK/scr-live3" --frames 3 --interval 2 > "$WORK/scr-live3.out" 2>&1 &
scr_pid=$!
scr_wait_for "$WORK/scr-live3.out" "Klatka 1:" 20
scr_console _www
: > "$AGENT_TEST/variant"
wait "$scr_pid"
out="$(cat "$WORK/scr-live3.out")"
expect "na żywo: zmiana użytkownika – nowe powiadomienie" "$out" "Powiadomiono użytkownika daemon" "Powiadomiono użytkownika _www"
expect_code "na żywo: zmiana użytkownika – dwa powiadomienia" "$(agent_count '^CMCRA1 NOTICE ')" 2 "$(agentlog)"
expect "na żywo: zmieniony ekran przesłany ponownie" "$out" "Klatka 2: nowy obraz"
expect_code "na żywo: zmiana użytkownika bez ponownego sudo" "$(scr_count '^sudo ')" 1 "$(fakelog)"
expect "na żywo: usługa uruchomiona w sesji nowego użytkownika" "$(fakelog)" "launchctl bootstrap gui/70 "
rm -f "$AGENT_TEST/variant"
agent_bootout 70

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
out="$(ctl screen-watch 1 "$WORK/scr-live6" --frames 1 --interval 2)"; code=$?
expect "na żywo: konto spoza listy dozwolonych" "$out" "nie jest na liście kont dozwolonych"
expect_code "na żywo: konto spoza listy dozwolonych – kod 4" "$code" 4 "$out"
expect_not "na żywo: zablokowane konto – nic nie przechwycono" "$(agentlog)" "CMCRA1 CAPTURE"
expect_not "na żywo: zablokowane konto – bez sudo" "$(fakelog)" "sudo"
expect_not "na żywo: zablokowane konto – bez powiadomienia" "$(agentlog)" "CMCRA1 NOTICE"
expect_not "na żywo: zablokowane konto – aplikacja nie jest odczytywana" "$out" "Przeglądarka Testowa"
python3 - "$WORK/config/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["observeAllowedUsers"] = ""; json.dump(s, open(p, "w"))
PY

scr_reset
echo 2 > "$AGENT_TEST/displays"
clear_fakelog
out="$(ctlpw screen-watch 1 "$WORK/scr-live7" --frames 1 --interval 2 --display all)"
expect "na żywo: wszystkie ekrany" "$out" "ekran 1/2" "ekran 2/2"
expect_code "na żywo: wszystkie ekrany – jedno pytanie usługi" "$(agent_count '^CMCRA1 CAPTURE 640 [0-9]+ all$')" 1 "$(agentlog)"
n="$(ls "$WORK/scr-live7"/*.jpg 2>/dev/null | wc -l | tr -d ' ')"
expect_code "na żywo: osobny obraz dla każdego ekranu" "$n" 2 "$(ls -la "$WORK/scr-live7" 2>&1)"
out="$(ctlpw screen-watch 1 "$WORK/scr-live8" --frames 1 --interval 2 --display 2)"
expect "na żywo: wybrany ekran" "$out" "Klatka 1: nowy obraz (ekran 2/"
echo 1 > "$AGENT_TEST/displays"
out="$(ctlpw screen-watch 1 "$WORK/scr-live9" --frames 1 --interval 2 --display 2)"; code=$?
expect "na żywo: brak wybranego ekranu – powód" "$out" "brak ekranu"
expect_code "na żywo: brak wybranego ekranu – kod 5" "$code" 5 "$out"
rm -f "$AGENT_TEST/displays"

section "Podgląd ekranów – bez potwierdzonego powiadomienia nie ma obrazu"
scr_reset
scr_console daemon
# The agent answers that its panel did not appear on screen (e.g. the session is not the one at the screen).
echo hidden > "$AGENT_TEST/notice"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-nonotice.jpg")"; code=$?
[ "$code" -ne 0 ] && pass "powiadomienie nieudane: zrzut kończy się błędem" || fail "powiadomienie nieudane: kod 0" "$out"
expect "powiadomienie nieudane: czytelny powód" "$out" "nie udało się wyświetlić informacji o podglądzie" "daemon" \
  "okno komunikatu nie pojawiło się na ekranie"
expect_not "powiadomienie nieudane: nie zgłoszono powiadomienia" "$out" "Powiadomiono"
[ ! -f "$WORK/scr-nonotice.jpg" ] && pass "powiadomienie nieudane: brak pliku" || fail "powiadomienie nieudane: zapisano obraz"
expect "powiadomienie nieudane: próba w sesji ucznia (przez usługę)" "$(agentlog)" "CMCRA1 NOTICE "
expect_not "powiadomienie nieudane: ekran nie został przechwycony" "$(agentlog)" "CMCRA1 CAPTURE"
expect_not "powiadomienie nieudane: aplikacja na pierwszym planie nie jest odczytywana" "$(agentlog)" "CMCRA1 FRONT"

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
expect_code "na żywo: przed powiadomieniem brak zrzutu" "$(agent_count '^CMCRA1 CAPTURE ')" 0 "$(agentlog)"
rm -f "$AGENT_TEST/notice"
wait "$scr_pid"
out="$(cat "$WORK/scr-notice-retry.out")"
expect "na żywo: ponowna próba powiadomienia, potem obraz" "$out" "Powiadomiono użytkownika daemon" "nowy obraz"
notices="$(agent_count '^CMCRA1 NOTICE ')"
[ "$notices" -ge 2 ] && pass "na żywo: powiadomienie ponowione w kolejnym cyklu ($notices)" || fail "na żywo: brak ponownej próby ($notices)" "$(agentlog)"
order="$(awk '/^CMCRA1 NOTICE / {n++} /^CMCRA1 CAPTURE / {print (n >= 2 ? "ok" : "za wcześnie"); exit}' "$AGENT_TEST/requests.log")"
[ "$order" = ok ] && pass "na żywo: pierwsza klatka dopiero po potwierdzonym powiadomieniu" \
  || fail "na żywo: zrzut przed powiadomieniem (${order:-brak})" "$(agentlog)"

# A stopped agent (SIGSTOP – what a student would do to answer the socket with their own program) is not trusted:
# the preview refuses it without asking it anything and without restarting it (that would hide the tampering), and
# the next preview after SIGCONT works again. A genuinely hung agent (timeout → revive) is covered by the unit tests.
scr_pid_before="$(agent_pid 1)"
if [ -n "$scr_pid_before" ]; then
  : > "$AGENT_TEST/requests.log"
  kill -STOP "$scr_pid_before"
  clear_fakelog
  out="$(ctlpw screenshot 1 "$WORK/scr-hung.jpg")"; code=$?
  kill -CONT "$scr_pid_before"
  expect_code "zatrzymana usługa: odrzucona – kod 1 (screenshot)" "$code" 1 "$out"
  expect "zatrzymana usługa: komunikat" "$out" "odpowiada inny program niż zainstalowana usługa" "jest zatrzymany"
  expect_not "zatrzymana usługa: bez ponownego uruchomienia" "$(fakelog)" "launchctl kickstart"
  expect_code "zatrzymana usługa: nic do niej nie wysłano" "$(agent_count '^CMCRA1 ')" 0 "$(agentlog)"
  [ ! -e "$WORK/scr-hung.jpg" ] && pass "zatrzymana usługa: brak obrazu" || fail "zatrzymana usługa: zapisano obraz"
  out="$(ctlpw screenshot 1 "$WORK/scr-hung.jpg")"; code=$?
  expect_code "zatrzymana usługa: po wznowieniu obraz – kod 0" "$code" 0 "$out"
  expect_code "zatrzymana usługa: ta sama usługa" "$(agent_pid 1)" "$scr_pid_before" ""
  scr_sessions_gone && pass "zatrzymana usługa: sesja zamknięta" || fail "zatrzymana usługa: zostały procesy sesji" "$(pgrep -lP "$SSHD_PID")"
else
  fail "zatrzymana usługa: usługa w sesji ucznia nie działa" "$(cat "$WORK/launchd/gui-1/pid" 2>&1)"
fi

# Own session of the SSH account (no sudo): the same rule.
rm -f "$WORK/console_user"
echo hidden > "$AGENT_TEST/notice"
clear_fakelog
out="$(ctlpw screenshot 1 "$WORK/scr-own-nonotice.jpg")"
expect "własna sesja: powiadomienie nieudane – obraz nie jest pobierany" "$out" "nie udało się wyświetlić informacji o podglądzie"
expect "własna sesja: próba powiadomienia przez usługę" "$(agentlog)" "CMCRA1 NOTICE "
expect_code "własna sesja: bez sudo" "$(scr_count '^sudo ')" 0 "$(fakelog)"
expect_not "własna sesja: ekran nie został przechwycony" "$(agentlog)" "CMCRA1 CAPTURE"

scr_reset
printf '%s' "$scr_settings_backup" > "$WORK/config/settings.json"
