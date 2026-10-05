# cmcrctl: host selection, exit codes, closed pipes, parallel ordered output and the parity commands.
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT come from there).
# Uses its own config folders for host-list changes, so later suites see the original configuration.

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
wait_fakelog() { # wait_fakelog "needle" – background jobs (power) log a moment later
  local i
  for i in $(seq 1 60); do fakelog | grep -qF -- "$1" && return 0; sleep 0.1; done
  return 1
}
json_get() { # json_get "$json" 'python expression on d'
  printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>&1
}

# Three entries for the same test sshd, with relaxed screen-preview rules (see "screenshot" below).
MULTI="$WORK/cfg-multi"
mkdir -p "$MULTI"
python3 - "$WORK/config/settings.json" "$MULTI/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["observeOnlyStandardAccounts"] = False; s["observeAllowedUsers"] = ""
json.dump(s, open(sys.argv[2], "w"))
PY
cat > "$MULTI/hosts.json" <<EOF
[
 {"name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"name":"imac02","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"name":"imac03","address":"127.0.0.1","user":"$ME","port":$PORT}
]
EOF
mctl() { CMCR_CONFIG_DIR="$MULTI" "$CTL" "$@" 2>&1; }

section "cmcrctl – wybór komputerów i kody wyjścia"
out="$(ctl exec 'echo nie-powinno' 2)"; code=$?
expect "wybór: brak komputera nr 2 – błąd zamiast innego Maca" "$out" "Nie znaleziono komputera: 2"
expect_code "wybór: kod 2 przy nieznanym komputerze" "$code" 2 "$out"
expect_not "wybór: polecenie nie zostało wykonane" "$out" "nie-powinno"
out="$(ctl exec 'echo x' 1,7)"; code=$?
expect "wybór: lista z nieznanym elementem odrzucona w całości" "$out" "Nie znaleziono komputera: 7"
expect_not "wybór: lista – nic nie wykonano" "$out" "Running command"
out="$(ctl exec 'echo pozycja-ok' '#1')"
expect "wybór: pozycja na liście (#1)" "$out" "pozycja-ok"
out="$(ctl exec 'echo nazwa-ok' imac01)"
expect "wybór: nazwa komputera" "$out" "nazwa-ok"
out="$(ctl --help)"; code=$?
expect_code "--help: kod 0" "$code" 0 "$out"
expect "--help: opis kodów wyjścia i wyboru komputerów" "$out" "Kody wyjścia" "zakres (1-5)" "updates install"
out="$(ctl polecenie-ktorego-nie-ma)"; code=$?
expect_code "nieznane polecenie: kod 2" "$code" 2 "$out"
out="$(ctl exec 'echo x' 1 --opcja-ktorej-nie-ma)"; code=$?
expect_code "nieznana opcja: kod 2" "$code" 2 "$out"
out="$(ctl exec 'echo x' 1 -j zero)"; code=$?
expect_code "-j: niepoprawna wartość – kod 2" "$code" 2 "$out"
out="$(ctl exec 'echo x' 1 -json)"; code=$?
expect "-json to nie -j: nieznana opcja" "$out" "Nieznana opcja: -json"
expect_code "-json: kod 2" "$code" 2 "$out"
# Options of other commands must not be ignored: `--host 2` would otherwise leave exec without a selection = all Macs.
out="$(mctl exec 'echo nie-powinno' --host 2)"; code=$?
expect_code "opcja innego polecenia (exec --host 2): kod 2" "$code" 2 "$out"
expect "opcja innego polecenia: czytelny błąd" "$out" "Opcja --host nie dotyczy polecenia exec"
expect_not "opcja innego polecenia: nic nie wykonano (zamiast na wszystkich)" "$out" "Running command"
out="$(mctl exec 'echo nie-powinno' 1 2)"; code=$?
expect_code "nadmiarowy argument (exec … 1 2): kod 2" "$code" 2 "$out"
expect "nadmiarowy argument: wskazówka" "$out" "Nadmiarowy argument „2”" "1,3 lub 1-5"
expect_not "nadmiarowy argument: nic nie wykonano" "$out" "Running command"
out="$(ctl power display-sleep 1 --dry-run)"; code=$?
expect_code "power --dry-run (opcja polecenia wake): kod 2" "$code" 2 "$out"
out="$(ctl password status --host 1)"; code=$?
expect_code "password status --host: kod 2" "$code" 2 "$out"
out="$(ctl apps)"; code=$?
expect_code "apps bez numeru: kod 2" "$code" 2 "$out"
out="$(ctl render 'echo "zażółć"' --root)"
expect "render: skrypt z ponownym uruchomieniem jako root" "$out" "asroot /bin/bash --noprofile --norc" "zażółć"

section "cmcrctl – zamknięty potok (cmcrctl … | head)"
"$CTL" exec 'seq 1 300000' 1 2>"$WORK/epipe.err" | head -n 2 >"$WORK/epipe.out"
code=${PIPESTATUS[0]}
if [ "$code" != 134 ] && ! grep -q "Terminating app\|NSFileHandleOperationException" "$WORK/epipe.err"; then
  pass "potok: brak awarii (SIGABRT) po zamknięciu stdout (kod $code)"
else
  fail "potok: awaria po zamknięciu stdout (kod $code)" "$(cat "$WORK/epipe.err")"
fi
expect "potok: pierwsze wiersze dotarły" "$(cat "$WORK/epipe.out")" "Running command on"
out="$("$CTL" list 2>&1 | head -n 1)"
expect "potok: list | head" "$out" "imac01"

section "cmcrctl – równoległość (-j) z wynikami w kolejności listy"
t0=$(now_ms)
out="$(mctl exec 'sleep 1; echo "gotowe"' all -j 3 --prefix)"; code=$?
t1=$(now_ms)
expect_code "-j 3: kod 0" "$code" 0 "$out"
if [ $((t1 - t0)) -lt 2800 ]; then pass "-j 3: trzy komputery naraz ($((t1 - t0)) ms)"; else fail "-j 3: za wolno ($((t1 - t0)) ms)" "$out"; fi
expect "-j 3: nagłówek i wynik każdego komputera z prefiksem" "$out" \
  "[imac01] Running command on" "[imac02] gotowe" "[imac03] gotowe"
out="$(mctl exec 'sleep 0.$((RANDOM % 9 + 1)); echo "a"; sleep 0.$((RANDOM % 5)); echo "b"' 1-3 -j 3 --prefix)"
order="$(printf '%s\n' "$out" | sed -n 's/^\[\(imac0[0-9]\)\].*/\1/p' | uniq | tr '\n' ' ')"
if [ "$order" = "imac01 imac02 imac03 " ]; then pass "-j 3: bloki w kolejności listy, bez przeplatania"; else fail "-j 3: kolejność: $order" "$out"; fi
out="$(mctl exec 'exit 4' 1,3 -j 2)"; code=$?
expect_code "-j: najwyższy kod zdalnego polecenia" "$code" 4 "$out"
out="$(mctl status)"; code=$?
order="$(printf '%s\n' "$out" | sed -n 's/^● \(imac0[0-9]\):.*/\1/p' | tr '\n' ' ')"
if [ "$order" = "imac01 imac02 imac03 " ]; then pass "status: równolegle, w kolejności listy"; else fail "status: kolejność: $order" "$out"; fi

section "cmcrctl status --json"
json="$("$CTL" status 1,99 --json 2>/dev/null)"; code=$?
expect_code "status --json: kod 1, gdy komputer offline" "$code" 1 "$json"
expect "status --json: komputer online" "$(json_get "$json" 'd[0]["name"], d[0]["online"], d[0]["reachability"], bool(d[0]["info"].get("os"))')" \
  "imac01 True online True"
expect "status --json: komputer offline z opisem" "$(json_get "$json" 'd[1]["name"], d[1]["online"], d[1]["reachability"], d[1]["message"]')" \
  "imac99 False offline Nie można odnaleźć"

section "cmcrctl – aktualizacje macOS"
out="$(ctl updates list 1)"; code=$?
expect_code "updates list: kod 0" "$code" 0 "$out"
expect "updates list: tytuły z oznaczeniem restartu" "$out" "imac01: 2 aktualizacje" "macOS Testowy 99.1 (wymaga restartu)" "• Safari"
clear_fakelog
out="$(ctlpw updates install 1 --restart </dev/null)"; code=$?
expect_code "updates install --restart: bez --yes (brak terminala) – kod 2" "$code" 2 "$out"
expect "updates install --restart: prośba o potwierdzenie" "$out" "dodaj --yes"
expect_not "updates install --restart: nic nie uruchomiono" "$(fakelog)" "softwareupdate"
out="$(ctlpw updates install 1 --restart --yes)"; code=$?
expect_code "updates install --restart --yes: kod 0" "$code" 0 "$out"
expect "updates install: softwareupdate --install --all --restart" "$(fakelog)" "softwareupdate --install --all --agree-to-license --restart"
if [ "$(uname -m)" = arm64 ]; then
  expect "updates install: hasło przez --stdinpass (Apple Silicon)" "$(fakelog)" "softwareupdate stdinpass ok"
fi
clear_fakelog
out="$(ctlpw updates install 1 --download --recommended)"
expect "updates install --download --recommended" "$(fakelog)" "softwareupdate --download --recommended"
expect_not "updates install --download: bez instalacji" "$(fakelog)" "--install"
out="$(ctlpw updates history 1)"
expect "updates history" "$out" "macOS Testowy  99.0"
out="$(ctl updates usun 1)"; code=$?
expect_code "updates: nieznane podpolecenie – kod 2" "$code" 2 "$out"

section "cmcrctl – Homebrew, adresy, procesy, deinstalacja"
clear_fakelog
out="$(ctlpw brew "install --cask firefox" 1)"
expect "brew: argumenty przekazane" "$out" "brew (fake) install --cask firefox"
expect "brew: wywołanie Homebrew" "$(fakelog)" "brew install --cask firefox"
clear_fakelog
out="$(ctlpw open-url "https://example.com/?a=1&b=2 x" 1)"
expect "open-url: komunikat" "$out" "Otwarto: https://example.com/?a=1&b=2 x"
expect "open-url: open w sesji użytkownika" "$(fakelog)" "gui-exec: /usr/bin/open https://example.com/?a=1&b=2 x"
# Detached (not jobs of this shell), so killing them prints no job notices.
P1="$(sleep 300 >/dev/null 2>&1 & echo $!)"
P2="$(sleep 300 >/dev/null 2>&1 & echo $!)"
clear_fakelog
out="$(ctlpw kill "$P1" 1)"; code=$?
expect_code "kill: kod 0" "$code" 0 "$out"
sleep 0.3
if kill -0 "$P1" 2>/dev/null; then fail "kill: proces nadal działa" "$out"; kill "$P1"; else pass "kill: proces zakończony (SIGTERM)"; fi
expect "kill: przez sudo" "$(fakelog)" "sudo kill -TERM $P1"
out="$(ctlpw kill "$P2" 1 --force)"
sleep 0.3
if kill -0 "$P2" 2>/dev/null; then fail "kill --force: proces nadal działa" "$out"; kill -9 "$P2"; else pass "kill --force: proces zakończony (SIGKILL)"; fi
out="$(ctl kill abc 1)"; code=$?
expect_code "kill: niepoprawny PID – kod 2" "$code" 2 "$out"
APPX="/Applications/Nieistniejąca Gra CMCR e2e.app"
if [ ! -e "$APPX" ]; then
  out="$(ctlpw uninstall "$APPX" 1 </dev/null)"; code=$?
  expect_code "uninstall: bez --yes – kod 2" "$code" 2 "$out"
  out="$(ctlpw uninstall "$APPX" 1 --yes)"; code=$?
  expect "uninstall: brak aplikacji – komunikat" "$out" "Nie znaleziono: $APPX"
  expect_code "uninstall: brak aplikacji – kod 0" "$code" 0 "$out"
fi
out="$(ctlpw uninstall "$WORK/Gra.app" 1 --yes)"; code=$?
expect "uninstall: tylko z /Applications" "$out" "Odinstalowywać można tylko"
expect_code "uninstall: odmowa – kod 1" "$code" 1 "$out"

section "cmcrctl – foldery (ls, clean)"
echo "x" > "$WORK/remote/Public/cmcr/plik ls ą.txt"
out="$(ctl ls "$WORK/remote/Public/cmcr" 1)"
expect "ls: zawartość folderu" "$out" "plik ls ą.txt"
out="$(ctlpw ls "$WORK/remote/Public/cmcr" 1 --root)"
expect "ls --root" "$out" "plik ls ą.txt"
out="$(ctl ls "/Users/{console}" 1)"
expect "ls: {console} = zalogowany użytkownik" "$out" "Library"
CLEAN="$WORK/remote/do czyszczenia"
mkdir -p "$CLEAN/podfolder z spacją"
touch "$CLEAN/a.txt" "$CLEAN/.ukryty" "$CLEAN/podfolder z spacją/b.txt"
out="$(ctlpw clean "$CLEAN" 1 </dev/null)"; code=$?
expect_code "clean: bez --yes – kod 2" "$code" 2 "$out"
[ -e "$CLEAN/a.txt" ] && pass "clean: bez potwierdzenia nic nie usunięto" || fail "clean: usunięto bez potwierdzenia"
out="$(ctlpw clean "$CLEAN/" 1 --yes)"; code=$?
expect "clean: komunikat" "$out" "Wyczyszczono $CLEAN"
if [ -d "$CLEAN" ] && [ -z "$(ls -A "$CLEAN")" ]; then pass "clean: folder pusty (także pliki ukryte)"; else fail "clean: zostały pliki" "$(ls -lA "$CLEAN")"; fi
out="$(ctlpw clean "$WORK/remote/../remote/do czyszczenia" 1 --yes)"; code=$?
expect "clean: ścieżka z .. odrzucona" "$out" "Odmowa"
expect_code "clean: odmowa – kod 1" "$code" 1 "$out"
out="$(ctlpw clean "/Library/cmcr-e2e-nie-istnieje-$$" 1 --yes)"
expect "clean: folder poza dozwolonymi miejscami odrzucony" "$out" "Odmowa: czyszczenie dozwolone tylko"

section "cmcrctl – wiadomość, wylogowanie, zasilanie"
clear_fakelog
out="$(ctlpw message "Tytuł e2e" "Treść z 'apostrofem' i \"cudzysłowem\" zażółć" 1)"; code=$?
expect_code "message: kod 0" "$code" 0 "$out"
expect "message: wysłano do zalogowanego użytkownika" "$out" "Wiadomość wysłana do $ME"
expect "message: okno dialogowe z poprawnie zacytowaną treścią" "$(fakelog)" \
  "display dialog \"Treść z 'apostrofem' i \\\"cudzysłowem\\\" zażółć\" with title \"Tytuł e2e\""
clear_fakelog
out="$(ctlpw message "T" "Powiadomienie e2e" 1 --notification)"
expect "message --notification" "$(fakelog)" "display notification \"Powiadomienie e2e\" with title \"T\""
clear_fakelog
out="$(ctlpw message "Uwaga" "-5 minut do końca lekcji" 1 --notification)"; code=$?
expect_code "message: treść zaczynająca się od „-” – kod 0" "$code" 0 "$out"
expect "message: treść zaczynająca się od „-” przekazana" "$(fakelog)" "display notification \"-5 minut do końca lekcji\""
out="$(ctl message "Tylko tytuł" 1)"; code=$?
expect_code "message: brak treści – kod 2" "$code" 2 "$out"
clear_fakelog
out="$(ctlpw logout 1 </dev/null)"; code=$?
expect_code "logout: bez --yes – kod 2" "$code" 2 "$out"
out="$(ctlpw logout 1 --yes)"
expect "logout: launchctl bootout sesji GUI" "$(fakelog)" "launchctl bootout gui/$(id -u)"
expect "logout: komunikat" "$out" "Wylogowano $ME"

# The power scripts detach `nohup /bin/sh -c '…'`: make sure that child also sees the fakes.
pg="$(ctlpw exec 'nohup /bin/sh -c "type shutdown pmset" </dev/null 2>&1 | grep -c "is a function"' 1 --root 2>&1 | tail -1)"
if [ "$pg" != 2 ]; then
  fail "power: atrapy niewidoczne w procesie w tle – testy zasilania pominięte" "$pg"
else
  clear_fakelog
  out="$(ctlpw power restart 1 </dev/null)"; code=$?
  expect_code "power restart: bez --yes – kod 2" "$code" 2 "$out"
  out="$(ctlpw power restart 1 --yes)"; code=$?
  expect_code "power restart: kod 0" "$code" 0 "$out"
  expect "power restart: komunikat" "$out" "Ponowne uruchamianie"
  if wait_fakelog "shutdown -r now"; then pass "power restart: shutdown -r now"; else fail "power restart" "$(fakelog)"; fi
  out="$(ctlpw power shutdown 1 --yes)"
  if wait_fakelog "shutdown -h now"; then pass "power shutdown: shutdown -h now"; else fail "power shutdown" "$(fakelog)"; fi
  out="$(ctlpw power sleep 1 --yes)"
  if wait_fakelog "pmset sleepnow"; then pass "power sleep: pmset sleepnow"; else fail "power sleep" "$(fakelog)"; fi
  out="$(ctl power display-sleep 1 </dev/null)"; code=$?
  expect_code "power display-sleep: bez potwierdzenia i bez hasła" "$code" 0 "$out"
  expect "power display-sleep: pmset displaysleepnow" "$(fakelog)" "pmset displaysleepnow"
fi
out="$(ctl power hibernate 1)"; code=$?
expect_code "power: nieznana akcja – kod 2" "$code" 2 "$out"

section "cmcrctl hosts / wake / password (osobna konfiguracja)"
HCFG="$WORK/cfg-hosts"
mkdir -p "$HCFG"
cp "$WORK/config/settings.json" "$HCFG/"
hctl() { CMCR_CONFIG_DIR="$HCFG" "$CTL" "$@" 2>&1; }
out="$(hctl hosts)"
expect "hosts: domyślna lista jak w cmcr-helpers" "$out" "imac15@imac15.local" "wspólne"
out="$(hctl hosts generate lab --start 7 --count 4 --digits 3 --domain szkola.lan)"
expect "hosts generate: podgląd" "$out" "lab007@lab007.szkola.lan" "… lab010@lab010.szkola.lan" "tylko podgląd"
[ ! -e "$HCFG/hosts.json" ] && pass "hosts generate: podgląd niczego nie zapisuje" || fail "hosts generate: zapisano przy podglądzie"
out="$(hctl hosts generate lab --start 7 --count 4 --digits 3 --domain szkola.lan --replace </dev/null)"; code=$?
expect_code "hosts generate --replace: bez --yes – kod 2" "$code" 2 "$out"
out="$(hctl hosts generate lab --start 7 --count 4 --digits 3 --domain szkola.lan --replace --yes)"
expect "hosts generate --replace" "$(hctl list)" "lab007@lab007.szkola.lan" "lab010"
expect_not "hosts generate --replace: stara lista zastąpiona" "$(hctl list)" "imac01"
out="$(hctl hosts generate lab --start 7 --count 6 --digits 3 --domain szkola.lan --append)"
expect "hosts generate --append: tylko brakujące" "$out" "Dopisano 2 komputery"
out="$(hctl hosts add pracownia 10.0.0.5 admin --port 2222 --mac AA-BB-CC-00-11-22)"; code=$?
expect_code "hosts add: kod 0" "$code" 0 "$out"
expect "hosts add: zapisane szczegóły" "$(hctl hosts)" "admin@10.0.0.5" "2222" "aa:bb:cc:00:11:22"
out="$(hctl hosts add pracownia)"; code=$?
expect_code "hosts add: duplikat – kod 2" "$code" 2 "$out"
out="$(hctl hosts add zly --mac xyz)"; code=$?
expect_code "hosts add: zły MAC – kod 2" "$code" 2 "$out"
out="$(hctl hosts set lab007 --mac 00:11:22:33:44:55)"
expect "hosts set: MAC" "$(hctl hosts)" "00:11:22:33:44:55"
out="$(hctl wake lab007,pracownia --dry-run)"; code=$?
expect "wake --dry-run: pakiety dla adresów MAC" "$out" "lab007: pakiet Wake-on-LAN dla 00:11:22:33:44:55" "pracownia: pakiet Wake-on-LAN dla aa:bb:cc:00:11:22"
expect_code "wake --dry-run: kod 0" "$code" 0 "$out"
out="$(hctl wake 8 --dry-run)"; code=$?
expect "wake: brak adresu MAC – wskazówka" "$out" "brak adresu MAC" "hosts set lab008"
expect_code "wake: brak adresu MAC – kod 1" "$code" 1 "$out"
out="$(hctl hosts remove 8-9 --yes)"
expect "hosts remove: komunikat" "$out" "lab008, lab009"
out="$(hctl exec 'echo x' 8)"; code=$?
expect "hosts remove: komputer usunięty z listy" "$out" "Nie znaleziono komputera: 8"
out="$(hctl hosts remove 1 </dev/null)"; code=$?
expect_code "hosts remove: bez --yes – kod 2" "$code" 2 "$out"

# An unreadable hosts.json must never be replaced by the default list (loadHosts() falls back to imac01–imac15).
BAD="$WORK/cfg-bad"
mkdir -p "$BAD"
cp "$WORK/config/settings.json" "$BAD/"
printf '%s\n' '[{"name":"sala1","address":"sala1.cmcr-e2e.invalid","macAddress":"aa:bb:cc:dd:ee:ff"},' \
  ' {"name":"sala2","adress":"sala2.cmcr-e2e.invalid"}]' > "$BAD/hosts.json"
cp "$BAD/hosts.json" "$WORK/hosts-bad.orig"
bctl() { CMCR_CONFIG_DIR="$BAD" "$CTL" "$@" 2>&1; }
for cmd in "hosts add nowy 10.0.0.9 admin" "hosts set 1 --mac 00:11:22:33:44:55" "hosts remove 1 --yes" \
           "hosts generate --append" "password clear --host 1"; do
  out="$(bctl $cmd </dev/null)"; code=$?
  expect_code "nieczytelny hosts.json: $cmd – kod 1" "$code" 1 "$out"
done
expect "nieczytelny hosts.json: wskazanie błędu" "$out" "brak pola „address” (wpis nr 2)" "lista komputerów nie została zmieniona"
out="$(printf 'tajne\n' | bctl password set --host 1)"; code=$?
expect_code "nieczytelny hosts.json: password set --host – kod 1" "$code" 1 "$out"
if security find-generic-password -s "$CMCR_KEYCHAIN_SERVICE" >/dev/null 2>&1; then
  fail "nieczytelny hosts.json: password set --host zapisał hasło"
else
  pass "nieczytelny hosts.json: password set --host niczego nie zapisał"
fi
cmp -s "$BAD/hosts.json" "$WORK/hosts-bad.orig" && pass "nieczytelny hosts.json: plik nie został zmieniony" \
  || fail "nieczytelny hosts.json: plik zmieniony" "$(cat "$BAD/hosts.json")"
expect "nieczytelny hosts.json: ostrzeżenie przy liście domyślnej" "$(bctl list)" "Uwaga: nie można odczytać" "domyślna lista"
out="$(bctl hosts generate sala --count 2 --replace --yes)"; code=$?
expect_code "nieczytelny hosts.json: generate --replace naprawia listę" "$code" 0 "$out"
expect "nieczytelny hosts.json: nowa lista" "$(bctl list)" "sala01@sala01.local" "sala02"

# Keychain: a throw-away service name, never the app's own items.
KS="pl.cmcr.manager.e2e-$$-$RANDOM"
kctl() { CMCR_KEYCHAIN_SERVICE="$KS" CMCR_CONFIG_DIR="$HCFG" "$CTL" "$@" 2>&1; }
out="$(kctl password set </dev/null)"; code=$?
expect_code "password set: pusty stdin – kod 2" "$code" 2 "$out"
out="$(printf '%s\n' "$PASSWORD" | kctl password set)"; code=$?
expect_code "password set: kod 0" "$code" 0 "$out"
expect "password set: komunikat" "$out" "Zapisano wspólne hasło"
expect_not "password set: hasło nie jest wypisywane" "$out" "Hasło 'z'"
expect "password status: zapisane" "$(kctl password status)" "Wspólne hasło administratora: zapisane"
out="$(CMCR_KEYCHAIN_SERVICE="$KS" "$CTL" exec 'echo "z-peku-kluczy"' 1 --root 2>&1)"
expect "password set: zapisane hasło działa z sudo (exec --root)" "$out" "z-peku-kluczy"
out="$(printf 'inne haslo\n' | kctl password set --host lab007)"
expect "password set --host: własne hasło" "$out" "Zapisano własne hasło administratora komputera lab007"
expect "password status: własne hasło komputera" "$(kctl password status)" "lab007: własne hasło – zapisane"
expect "hosts: oznaczenie własnego hasła" "$(hctl hosts | grep lab007)" "własne"
out="$(kctl password clear --host lab007)"
expect "password clear --host: powrót do hasła wspólnego" "$(hctl hosts | grep lab007)" "wspólne"
out="$(kctl password clear)"
expect "password clear: usunięte" "$(kctl password status)" "Wspólne hasło administratora: brak"
while security delete-generic-password -s "$KS" >/dev/null 2>&1; do :; done

section "cmcrctl screenshot – zapis do niedostępnego pliku"
out="$(CMCR_PASSWORD="$PASSWORD" CMCR_CONFIG_DIR="$MULTI" "$CTL" screenshot 1 "$WORK/brak/katalogu/x.jpg" 2>&1)"; code=$?
expect "screenshot: czytelny błąd zapisu" "$out" "Nie można zapisać"
expect_not "screenshot: brak awarii" "$out" "Fatal error"
expect_code "screenshot: kod 1" "$code" 1 "$out"
