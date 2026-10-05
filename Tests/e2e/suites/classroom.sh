# Zajęcia, tryb uwagi, harmonogram zasilania, nazwy komputerów, pytania i raporty (U8).
# Sourced by run.sh; uses its helpers and the fakes in fakes.sh (state files in $WORK).

section "Zajęcia: zabezpieczenie procesów w tle"
# Delayed actions and auto-unlock run in a detached /bin/bash – it must see the fakes too.
bg_guard="$(ctlpw exec '/bin/bash --noprofile --norc -c "type pmset shutdown pkill launchctl" 2>&1 | grep -c "is a function"' 1 --root | tail -1)"
U8_BG_OK=0
if [ "$bg_guard" = 4 ]; then U8_BG_OK=1; pass "atrapy aktywne w procesach uruchamianych w tle"
else fail "atrapy NIE są aktywne w procesach w tle – testy opóźnionych akcji pominięte" "$bg_guard"; fi

section "Zajęcia: tryb uwagi (blokada ekranów)"
rm -f "$WORK"/lockscreen.* "$WORK"/attention.*
clear_fakelog
out="$(ctlpw lock 1 --message "Patrzymy na tablicę – ąę" --minutes 1)"; code=$?
expect_code "lock: kod 0" "$code" 0 "$out"
expect "lock: LockScreen dla sesji przy konsoli" "$(fakelog)" "lockscreen:" "-session 4242" "-msg Patrzymy na tablicę – ąę"
expect "lock: wynik" "$out" "CMCR:LOCK:lockscreen" "blokada systemowa" "za 1 min"
[ -e "$WORK/lockscreen.running" ] && pass "lock: LockScreen działa" || fail "lock: LockScreen nie działa"
if pgrep -U "$(id -u)" -f CMCR_ATTENTION >/dev/null 2>&1; then pass "lock: zaplanowano automatyczne odblokowanie"
else fail "lock: brak procesu automatycznego odblokowania"; fi
out="$(ctlpw unlock 1)"
expect "unlock: odblokowano" "$out" "Ekran odblokowany"
[ ! -e "$WORK/lockscreen.running" ] && pass "unlock: LockScreen zamknięty" || fail "unlock: LockScreen nadal działa"
sleep 0.3
if pgrep -U "$(id -u)" -f CMCR_ATTENTION >/dev/null 2>&1; then fail "unlock: automatyczne odblokowanie nadal czeka"
else pass "unlock: automatyczne odblokowanie anulowane"; fi
out="$(ctlpw unlock 1)"
expect "unlock: nic nie było zablokowane" "$out" "nie był zablokowany"

: > "$WORK/lockscreen.fail"
clear_fakelog
out="$(ctlpw lock 1 --minutes 0)"; code=$?
expect_code "lock (zastępczo): kod 0" "$code" 0 "$out"
expect "lock: komunikat pełnoekranowy, gdy LockScreen nie działa" "$out" "LockScreen niedostępny" "CMCR:LOCK:overlay"
expect "lock: nakładka JXA w sesji użytkownika" "$(fakelog)" "attention-overlay: osascript JXA CMCR_ATTENTION"
out="$(ctlpw lock 1 --mode lockScreen)"; code=$?
expect_code "lock (tylko LockScreen): błąd" "$code" 1 "$out"
expect "lock (tylko LockScreen): czytelny komunikat" "$out" "nie uruchomiła się"
out="$(ctlpw lock 1 --mode overlay --minutes 0)"
expect "lock (tryb komunikatu): bez LockScreen" "$out" "CMCR:LOCK:overlay"
expect_not "lock (tryb komunikatu): bez ostrzeżenia o LockScreen" "$out" "LockScreen niedostępny"
out="$(ctlpw unlock 1)"
expect "unlock: komunikat zdjęty" "$out" "Ekran odblokowany"
rm -f "$WORK/lockscreen.fail"
out="$(ctl lock 1)"; code=$?
expect_code "lock: bez hasła administratora – kod 91" "$code" 91 "$out"

section "Zajęcia: pytania do uczniów"
echo "Zadanie 3 gotowe" > "$WORK/ask.answer"
out="$(ctlpw ask "Czy skończyłeś zadanie?" 1 --timeout 30)"
expect "ask: odpowiedź tekstowa" "$out" "imac01 ($ME): Zadanie 3 gotowe"
out="$(ctlpw ask "Gotowe?" 1 --buttons "Tak, Nie, Pomocy")"
expect "ask: odpowiedź przyciskiem" "$out" "imac01 ($ME): Tak"
: > "$WORK/ask.timeout"
out="$(ctlpw ask "Jest tam ktoś?" 1 --timeout 10)"
expect "ask: brak odpowiedzi w czasie" "$out" "brak odpowiedzi (minął czas)"
rm -f "$WORK/ask.timeout" "$WORK/ask.answer"

section "Harmonogram zasilania (pmset repeat)"
clear_fakelog
out="$(ctlpw schedule set 1 --on MTWRF@07:45 --off MTWRF@16:30)"; code=$?
expect_code "schedule set: kod 0" "$code" 0 "$out"
expect "schedule set: pmset repeat i zasady" "$(fakelog)" \
  "pmset repeat wakeorpoweron MTWRF 07:45:00 sleep MTWRF 16:30:00" "pmset -a autorestart 1" "pmset -a womp 1"
out="$(ctl schedule show 1)"
expect "schedule show: odczyt i tłumaczenie" "$out" "Obudź lub włącz o 7:45 – dni robocze (Pn–Pt)" "Uśpij o 16:30" \
  "po zaniku zasilania: tak" "Wake-on-LAN: tak"
clear_fakelog
out="$(ctlpw schedule set 1 --off SU@12:00 --off-type shutdown --no-autorestart)"
expect "schedule set: tylko wyłączanie w weekend" "$(fakelog)" "pmset repeat shutdown SU 12:00:00"
expect_not "schedule set: bez autorestart" "$(fakelog)" "autorestart"
out="$(ctl schedule show 1)"
expect "schedule show: wyłączanie w weekendy" "$out" "Wyłącz o 12:00 – weekendy"
out="$(ctlpw schedule clear 1)"
out="$(ctl schedule show 1)"
expect "schedule clear: harmonogram usunięty" "$out" "brak harmonogramu"
out="$(ctlpw schedule set 1 --on XQ@07:45)"; code=$?
expect_code "schedule set: błędne dni odrzucone" "$code" 2 "$out"

section "Zasilanie: opóźnione akcje i FileVault"
out="$(ctl filevault 1)"
expect "filevault: wyłączony" "$out" "FileVault wyłączony"
: > "$WORK/filevault.on"
out="$(ctl filevault 1)"
expect "filevault: włączony" "$out" "FileVault włączony"
rm -f "$WORK/filevault.on"
if [ "$U8_BG_OK" = 1 ]; then
  clear_fakelog
  out="$(ctlpw power-later shutdown 5 1 --warn "Zapisz pracę – wyłączam za 5 minut")"; code=$?
  expect_code "power-later: kod 0" "$code" 0 "$out"
  expect "power-later: komunikat" "$out" "Wyłącz: za 5 min"
  expect "power-later: ostrzeżenie dla ucznia" "$(fakelog)" "gui-stdin:" "Zapisz pracę – wyłączam za 5 minut"
  waiting="$(pgrep -U "$(id -u)" -fl cmcr-delayed-power 2>/dev/null)"
  expect "power-later: czeka proces z akcją" "$waiting" "cmcr-delayed-power 300 shutdown"
  expect_not "power-later: nic nie wyłączono od razu" "$(fakelog)" "shutdown -h"
  out="$(ctlpw power-cancel 1)"
  expect "power-cancel: anulowano" "$out" "Anulowano zaplanowane"
  sleep 0.3
  if pgrep -U "$(id -u)" -f cmcr-delayed-power >/dev/null 2>&1; then fail "power-cancel: proces nadal czeka"
  else pass "power-cancel: oczekujący proces usunięty"; fi
  expect "power-cancel: także shutdown +N" "$(fakelog)" "killall shutdown"
  out="$(ctlpw power-cancel 1)"
  expect "power-cancel: nic nie było zaplanowane" "$out" "Nic nie było zaplanowane"
fi

section "Nazwy komputerów"
clear_fakelog
out="$(ctlpw rename 1 --name "Pracownia ą 01")"; code=$?
expect_code "rename: kod 0" "$code" 0 "$out"
expect "rename: nowa nazwa i adres" "$out" "Pracownia-a-01.local" "CMCR:LHN:Pracownia-a-01"
expect "rename: scutil i odświeżenie Bonjour" "$(fakelog)" "scutil --set ComputerName Pracownia ą 01" \
  "scutil --set LocalHostName Pracownia-a-01" "scutil --set HostName Pracownia-a-01" "dscacheutil -flushcache" \
  "killall -HUP mDNSResponder"
out="$(ctlpw rename 1 --name "!!!")"; code=$?
expect "rename: niepoprawna nazwa odrzucona" "$out" "niepoprawna nazwa"
out="$(ctl rename 1 --dry-run)"
expect "rename: podgląd z nazwy na liście" "$out" "„imac01” → imac01.local"

section "Wersje aplikacji"
mkdir -p "$WORK/Applications/CMCR Test.app/Contents"
cat > "$WORK/Applications/CMCR Test.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>45</string>
</dict></plist>
PLIST
out="$(ctl app-version "CMCR Test" 1)"
expect "app-version: wersja i położenie" "$out" "imac01: 1.2.3 (45)" "CMCR Test.app"
out="$(ctl app-version "cmcr test.app" 1)"
expect "app-version: wielkość liter i .app bez znaczenia" "$out" "imac01: 1.2.3 (45)"
out="$(ctl app-version "Nie Ma Takiej Aplikacji" 1)"
expect "app-version: brak aplikacji" "$out" "imac01: brak"

section "Zajęcia: rozpoczęcie i zakończenie"
mkdir -p "$WORK/materials/Lekcja 1"
echo "zadanie" > "$WORK/materials/Lekcja 1/zadanie ą.txt"
echo "karta" > "$WORK/materials/karta pracy.txt"
python3 - "$WORK/config/classroom.json" "$WORK/materials" <<'PY'
import json, sys
cfg = {
  "start": {"wake": True, "wakeWaitMinutes": 1, "sendMaterials": True, "materialsFolder": sys.argv[2],
            "destination": "sharedFolder", "openApps": True, "apps": "Kalkulator Test", "greet": True,
            "greetingTitle": "Cześć", "greetingText": "Witajcie na lekcji", "greetingAsDialog": False},
  "end": {"warn": True, "warnMinutes": 1, "warnText": "Koniec za chwilę – zapisz pracę", "collect": True,
          "collectLabel": "3A", "quitApps": True, "quitAllApps": False, "apps": "CMCRDummy", "cleanShared": True,
          "cleanDownloads": False, "logout": True, "power": "none"},
}
json.dump(cfg, open(sys.argv[1], "w"), ensure_ascii=False)
PY
clear_fakelog
out="$(ctlpw lesson start 1)"; code=$?
expect_code "lesson start: kod 0" "$code" 0 "$out"
expect "lesson start: wszystkie kroki" "$out" "komputer jest włączony" "materiały w $WORK/remote/Public/cmcr" \
  "uruchomiono: Kalkulator Test" "powitanie wyświetlone"
[ -f "$WORK/remote/Public/cmcr/Lekcja 1/zadanie ą.txt" ] && [ -f "$WORK/remote/Public/cmcr/karta pracy.txt" ] \
  && pass "lesson start: materiały w folderze ucznia" || fail "lesson start: brak materiałów" "$(ls -laR "$WORK/remote/Public/cmcr")"
expect "lesson start: aplikacja i powitanie w sesji ucznia" "$(fakelog)" "gui-exec: /usr/bin/open -a Kalkulator Test" \
  "Witajcie na lekcji"

echo "praca ucznia" > "$WORK/remote/Public/cmcr/praca.txt"
"$WORK/CMCRDummy.app/Contents/MacOS/CMCRDummy" 300 &
DUMMY2=$!
sleep 0.5
clear_fakelog
out="$(ctlpw lesson end 1 --no-wait)"; code=$?
expect_code "lesson end: kod 0" "$code" 0 "$out"
expect "lesson end: wszystkie kroki" "$out" "ostrzeżenie wyświetlone" "zebrano" "zamknięto: CMCRDummy" \
  "wyczyszczono $WORK/remote/Public/cmcr" "użytkownik wylogowany"
collected="$(find "$WORK/local/zebrane" -path "*3A/imac01/praca.txt" 2>/dev/null | head -1)"
[ -n "$collected" ] && pass "lesson end: prace w folderze z datą i klasą" || fail "lesson end: brak zebranych prac" "$(find "$WORK/local" 2>&1)"
[ -z "$(ls -A "$WORK/remote/Public/cmcr" 2>/dev/null)" ] && pass "lesson end: folder ucznia wyczyszczony" \
  || fail "lesson end: folder ucznia nie jest pusty" "$(ls -la "$WORK/remote/Public/cmcr")"
sleep 0.3
if kill -0 "$DUMMY2" 2>/dev/null; then fail "lesson end: aplikacja nadal działa"; kill "$DUMMY2"; else pass "lesson end: aplikacja zamknięta"; fi
expect "lesson end: ostrzeżenie i wylogowanie" "$(fakelog)" "Koniec za chwilę – zapisz pracę" "launchctl bootout gui/"

rm -rf "$WORK/remote/Public/cmcr"
out="$(ctlpw lesson end 1 --no-wait)"; code=$?
expect_code "lesson end bez folderu ucznia: błąd zbierania" "$code" 1 "$out"
expect "lesson end: bez zebranych prac folder nie jest czyszczony" "$out" "pominięto, bo zbieranie prac się nie udało"
mkdir -p "$WORK/remote/Public/cmcr"
rm -f "$WORK/config/classroom.json"

section "Raport CSV"
out="$(ctl report "$WORK/raport.csv")"
expect "report: zapisano" "$out" "Zapisano raport"
csv="$(cat "$WORK/raport.csv" 2>/dev/null)"
expect "report: nagłówek i komputery" "$csv" "Nazwa;Adres;Konto SSH;Stan" "imac01;127.0.0.1;$ME;online" "imac99;"
[ "$(head -c 3 "$WORK/raport.csv" | od -An -tx1 | tr -d ' ')" = efbbbf ] && pass "report: UTF-8 z BOM (Excel)" \
  || fail "report: brak BOM"
rm -f "$WORK"/lockscreen.* "$WORK"/attention.* "$WORK"/pmset.*
