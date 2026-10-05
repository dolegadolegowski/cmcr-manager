# Remote file browser and "Zbierz prace" (sourced by Tests/e2e/run.sh).
# Every deletion either targets $WORK or runs with --dry-run, so a broken safety guard cannot touch this Mac.

section "Przeglądarka plików – lista folderu"
B="$WORK/remote/przeglądarka"
mkdir -p "$B/folder ze spacją/podfolder" "$B/.ukryty folder" "$B/Aplikacja.app/Contents" "$B/zablokowany"
echo "a" > "$B/zażółć gęślą jaźń.txt"
printf 'x' > "$B/nowa
linia.txt"
printf 't' > "$B/z	tabem.txt"
echo "h" > "$B/.ukryty.txt"
echo "m" > "$B/-zaczyna-od-minusa.txt"
echo "f" > "$B/z flagą hidden.txt"
chflags hidden "$B/z flagą hidden.txt"
printf '%01000d' 0 > "$B/rozmiar.bin"
ln -s "folder ze spacją" "$B/link do folderu"
ln -s /usr/share "$B/link-poza"
chmod 000 "$B/zablokowany"

out="$(ctl ls 1 "$B" --all)"; code=$?
expect_code "ls: kod 0" "$code" 0 "$out"
expect "ls: spacje i polskie znaki" "$out" "folder ze spacją/" "zażółć gęślą jaźń.txt"
expect "ls: znak nowej linii w nazwie" "$out" 'nowa\nlinia.txt'
expect "ls: tabulator w nazwie" "$out" 'z\ttabem.txt'
expect "ls: nazwa zaczynająca się od minusa" "$out" " -zaczyna-od-minusa.txt"
expect "ls: dowiązanie do folderu" "$out" "link do folderu/ -> folder ze spacją"
expect "ls: pakiet .app jak plik" "$out" "Aplikacja.app"
expect_not "ls: pakiet .app nie jest folderem" "$out" "Aplikacja.app/"
expect "ls: rozmiar pliku" "$out" " 1000  "
expect "ls: ukryte pliki z --all" "$out" ".ukryty.txt" ".ukryty folder/" "z flagą hidden.txt"
expect "ls: właściciel" "$out" "właściciel $ME:"
out="$(ctl ls 1 "$B")"
expect_not "ls: ukryte domyślnie pominięte" "$out" ".ukryty.txt"
expect_not "ls: flaga hidden domyślnie pominięta" "$out" "z flagą hidden.txt"
expect "ls: licznik ukrytych" "$out" "ukryte: 3"
clear_fakelog
out="$(ctlpw ls 1 "$B/folder ze spacją" --root)"; code=$?
expect_code "ls --root: kod 0" "$code" 0 "$out"
expect "ls --root: zawartość" "$out" "podfolder/"
expect "ls --root: przez sudo" "$(fakelog)" "sudo /bin/bash"

L="$WORK/remote/duzy"
mkdir -p "$L"
seq 1 1500 | sed "s|^|$L/plik nr |" | tr '\n' '\0' | xargs -0 touch
t0=$(date +%s)
out="$(ctl ls 1 "$L")"
t1=$(date +%s)
expect "ls: duży folder (1500 plików)" "$out" "1500 elementów" "plik nr 1500"
[ $((t1 - t0)) -le 10 ] && pass "ls: duży folder w $((t1 - t0)) s" || fail "ls: duży folder trwał $((t1 - t0)) s"

section "Przeglądarka plików – błędy i symbole zastępcze"
out="$(ctl ls 1 "$WORK/nie ma takiego")"; code=$?
expect "ls: brak folderu" "$out" "Folder nie istnieje: $WORK/nie ma takiego"
expect_code "ls: brak folderu – kod 1" "$code" 1 "$out"
out="$(ctl ls 1 "$B/rozmiar.bin")"
expect "ls: plik zamiast folderu" "$out" "To nie jest folder"
out="$(ctl ls 1 "$B/zablokowany")"
expect "ls: brak uprawnień" "$out" "Brak dostępu do folderu"
chmod 755 "$B/zablokowany"
out="$(ctl ls 1 "/Users/{console}/.cmcr-e2e-brak")"
expect "ls: {console} → zalogowany użytkownik" "$out" "Folder nie istnieje: /Users/$ME/.cmcr-e2e-brak"
out="$(ctl ls 1 "/Users/{student}/.cmcr-e2e-brak")"
expect "ls: {student} → konto ucznia" "$out" "Folder nie istnieje: /Users/$ME/.cmcr-e2e-brak"
out="$(ctl ls 1 "~/.cmcr-e2e-brak")"
expect "ls: ~ → katalog administratora" "$out" "Folder nie istnieje: $HOME/.cmcr-e2e-brak"
out="$(ctl ls 1 "względna/ścieżka")"
expect "ls: ścieżka względna odrzucona" "$out" "musi zaczynać się od /"

section "Wybór folderu – czy istnieje na komputerach"
out="$(ctl exists 1 "$B/folder ze spacją")"; code=$?
expect "exists: folder jest" "$out" "imac01: jest"
expect_code "exists: kod 0" "$code" 0 "$out"
out="$(ctl exists 1 "$B/nie ma takiego")"; code=$?
expect "exists: brak folderu" "$out" "imac01: brak folderu"
expect_code "exists: brak – kod 1" "$code" 1 "$out"
out="$(ctl exists 1 "$B/rozmiar.bin")"
expect "exists: plik zamiast folderu" "$out" "to plik, nie folder"
chmod 000 "$B/zablokowany"
out="$(ctl exists 1 "$B/zablokowany/w środku")"
expect "exists: brak dostępu bez sudo" "$out" "brak dostępu"
chmod 755 "$B/zablokowany"
out="$(ctl exists 1 "/Users/{student}")"
expect "exists: {student}" "$out" "imac01: jest"

section "Przeglądarka plików – nowy folder i zmiana nazwy"
out="$(ctl mkdir 1 "$B/Nowy folder ą")"; code=$?
expect_code "mkdir: kod 0" "$code" 0 "$out"
[ -d "$B/Nowy folder ą" ] && pass "mkdir: folder utworzony" || fail "mkdir: brak folderu" "$out"
out="$(ctl mkdir 1 "$B/Nowy folder ą")"; code=$?
expect "mkdir: istniejący folder" "$out" "już istnieje"
expect_code "mkdir: istniejący – kod 66" "$code" 66 "$out"
out="$(ctl mkdir 1 "$B/brak rodzica/x")"; code=$?
expect_code "mkdir: brak folderu nadrzędnego – kod 61" "$code" 61 "$out"
out="$(ctl mkdir 1 "$B/a/b/c" -p)"; code=$?
[ -d "$B/a/b/c" ] && pass "mkdir -p: cała ścieżka" || fail "mkdir -p" "$out"
out="$(ctl mkdir 1 "$B/a/b/c" -p)"; code=$?
expect_code "mkdir -p: istniejący folder – kod 0" "$code" 0 "$out"
clear_fakelog
out="$(ctlpw mkdir 1 "$B/jako root/w środku" -p --root)"; code=$?
expect_code "mkdir --root: kod 0" "$code" 0 "$out"
expect "mkdir --root: właściciel jak folder nadrzędny" "$(fakelog)" "chown -R $ME:" "$B/jako root"
out="$(ctl rename 1 "$B/nowa
linia.txt" "bez nowej linii.txt")"; code=$?
expect_code "rename: kod 0" "$code" 0 "$out"
[ -f "$B/bez nowej linii.txt" ] && [ ! -e "$B/nowa
linia.txt" ] && pass "rename: nazwa zmieniona" || fail "rename" "$(ls -la "$B")"
out="$(ctl rename 1 "$B/bez nowej linii.txt" "Bez Nowej Linii.txt")"; code=$?
expect_code "rename: tylko wielkość liter – kod 0" "$code" 0 "$out"
ls "$B" | grep -qx "Bez Nowej Linii.txt" && pass "rename: zmieniona wielkość liter" || fail "rename: wielkość liter" "$(ls "$B")"
ctl rename 1 "$B/Bez Nowej Linii.txt" "bez nowej linii.txt" >/dev/null
out="$(ctl rename 1 "$B/a" ".ukryty folder")"; code=$?
expect_code "rename: na istniejący folder – kod 66" "$code" 66 "$out"
out="$(ctl rename 1 "$B/bez nowej linii.txt" "rozmiar.bin")"; code=$?
expect_code "rename: istniejąca nazwa – kod 66" "$code" 66 "$out"
out="$(ctl rename 1 "$B/bez nowej linii.txt" "a/b")"; code=$?
expect_code "rename: ukośnik w nazwie – odmowa" "$code" 65 "$out"

section "Przeglądarka plików – usuwanie i zabezpieczenia"
out="$(ctl rm 1 "$B/zażółć gęślą jaźń.txt" "$B/z	tabem.txt")"; code=$?
expect_code "rm: kod 0" "$code" 0 "$out"
[ ! -e "$B/zażółć gęślą jaźń.txt" ] && [ ! -e "$B/z	tabem.txt" ] && pass "rm: pliki usunięte" || fail "rm" "$(ls -la "$B")"
out="$(ctl rm 1 "$B/link do folderu")"
[ ! -L "$B/link do folderu" ] && [ -d "$B/folder ze spacją/podfolder" ] \
  && pass "rm: usunięte dowiązanie, cel nietknięty" || fail "rm: dowiązanie" "$(ls -laR "$B")"
out="$(ctl rm 1 "$B/folder ze spacją" --dry-run)"; code=$?
expect "rm --dry-run: dozwolony folder" "$out" "Zostałoby usunięte: /private$B/folder ze spacją"
[ -d "$B/folder ze spacją" ] && pass "rm --dry-run: nic nie usunięto" || fail "rm --dry-run usunął folder"
for p in "/Users/$ME" "/Users/$ME/Desktop" "/Users/$ME/Documents" "/Users/$ME/Public" "/Users/$ME/.ssh" \
         "/Users/$ME/Library/Caches" "/Applications/Safari.app" "/etc/hosts" "/tmp/../etc/hosts" \
         "/Volumes/Macintosh HD/etc/hosts" "$B/link-poza/cmcr-e2e-brak" "/" "względna"; do
  out="$(ctl rm 1 "$p" --dry-run)"; code=$?
  if [ "$code" = 65 ] && contains "" "$out" "Odmowa" && ! contains "" "$out" "Zostałoby"; then
    pass "rm: odmowa dla $p"
  else
    fail "rm: brak odmowy dla $p (kod $code)" "$out"
  fi
done
out="$(ctl rm 1 "$WORK/nie ma/pliku")"; code=$?
expect_code "rm: brak folderu – kod 61" "$code" 61 "$out"

section "Przeglądarka plików – pobieranie"
mkdir -p "$WORK/pobrane"
out="$(ctl get 1 "$B/folder ze spacją" "$B/rozmiar.bin" "$WORK/pobrane")"; code=$?
expect_code "get: kod 0" "$code" 0 "$out"
[ -d "$WORK/pobrane/folder ze spacją/podfolder" ] && [ -f "$WORK/pobrane/rozmiar.bin" ] \
  && pass "get: folder i plik pobrane" || fail "get" "$(ls -laR "$WORK/pobrane")"
out="$(ctl get 1 "$B/rozmiar.bin" "$WORK/pobrane")"
[ -f "$WORK/pobrane/rozmiar (2).bin" ] && pass "get: istniejący plik nie nadpisany (kopia „ (2)”)" \
  || fail "get: brak kopii" "$(ls -la "$WORK/pobrane")"
out="$(ctl get 1 "$B/nie-ma.txt" "$WORK/pobrane")"; code=$?
expect "get: brak elementu" "$out" "Nie znaleziono"

section "Zbierz prace"
S="$WORK/remote/prace ucznia"
mkdir -p "$S/projekt 1"
echo "praca" > "$S/projekt 1/main.txt"
echo "notatka" > "$S/notatka ł.txt"
out="$(ctlpw collect 1 --from "$S" --to "$WORK/zebrane")"; code=$?
expect_code "collect: kod 0" "$code" 0 "$out"
stamp="$(ls "$WORK/zebrane" 2>/dev/null | head -1)"
case "$stamp" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9].[0-9][0-9]) pass "collect: folder z datą i godziną ($stamp)" ;;
  *) fail "collect: nazwa folderu „$stamp”" "$(ls -la "$WORK/zebrane")" ;;
esac
[ -f "$WORK/zebrane/$stamp/imac01/projekt 1/main.txt" ] && [ -f "$WORK/zebrane/$stamp/imac01/notatka ł.txt" ] \
  && pass "collect: prace w <data>/<host>" || fail "collect: brak plików" "$(ls -laR "$WORK/zebrane")"
expect "collect: podsumowanie" "$out" "Zebrano 2 pliki"
[ -f "$S/notatka ł.txt" ] && pass "collect: bez --clean folder ucznia nietknięty" || fail "collect: zniknęły pliki ucznia"
out="$(ctlpw collect 1 --from "$S" --to "$WORK/zebrane")"
n="$(find "$WORK/zebrane" -mindepth 2 -maxdepth 2 -type d -name 'imac01*' | wc -l | tr -d ' ')"
[ "$n" = 2 ] && pass "collect: kolejne zebranie nie nadpisuje poprzedniego" || fail "collect: $n folderów hosta" "$(ls -laR "$WORK/zebrane")"
out="$(ctlpw collect 1 --from "$S" --to "$WORK/zebrane-bez-daty" --no-date --clean)"; code=$?
expect_code "collect --clean: kod 0" "$code" 0 "$out"
[ -f "$WORK/zebrane-bez-daty/imac01/projekt 1/main.txt" ] && pass "collect --no-date: <katalog>/<host>" \
  || fail "collect --no-date" "$(ls -laR "$WORK/zebrane-bez-daty")"
[ -d "$S" ] && [ -z "$(ls -A "$S")" ] && pass "collect --clean: folder ucznia wyczyszczony (sam folder został)" \
  || fail "collect --clean" "$(ls -la "$S" 2>&1)"
S2="$WORK/remote/prace w toku"
mkdir -p "$S2/gotowe/głębiej" "$S2/w toku"
echo "a" > "$S2/gotowe/głębiej/a.txt"
echo "b" > "$S2/b ą.txt"
: > "$S2/w toku/log.txt"
echo "poza" > "$WORK/poza.txt"
ln -s "$WORK/poza.txt" "$S2/link poza"
( while :; do echo x >> "$S2/w toku/log.txt"; sleep 0.05; done ) &
WRITER=$!
out="$(ctlpw collect 1 --from "$S2" --to "$WORK/zebrane-w-toku" --no-date --clean)"; code=$?
kill "$WRITER" 2>/dev/null; wait "$WRITER" 2>/dev/null
expect_code "collect --clean w trakcie pracy: kod 0" "$code" 0 "$out"
[ ! -e "$S2/b ą.txt" ] && [ ! -e "$S2/gotowe" ] \
  && pass "collect --clean: zebrane pliki i opróżnione foldery usunięte" || fail "collect --clean: pozostałości" "$(ls -laR "$S2")"
[ -f "$S2/w toku/log.txt" ] && pass "collect --clean: plik zmieniony w trakcie zbierania został" \
  || fail "collect --clean: usunięto plik zmieniony po zebraniu" "$out"
expect "collect --clean: informacja o pozostawionych" "$out" "Pozostawiono plików zmienionych w międzyczasie: 1"
[ ! -L "$S2/link poza" ] && [ -f "$WORK/poza.txt" ] \
  && pass "collect --clean: dowiązanie usunięte, plik docelowy nietknięty" || fail "collect --clean: dowiązanie" "$(ls -la "$S2" "$WORK")"
[ -f "$WORK/zebrane-w-toku/imac01/gotowe/głębiej/a.txt" ] && pass "collect --clean: kopia kompletna" \
  || fail "collect --clean: brak kopii" "$(ls -laR "$WORK/zebrane-w-toku")"

out="$(ctlpw collect 1 --from "$S" --to "$WORK/zebrane-puste")"; code=$?
expect "collect: pusty folder" "$out" "nic do zebrania"
[ ! -e "$WORK/zebrane-puste" ] || [ -z "$(find "$WORK/zebrane-puste" -mindepth 2)" ] \
  && pass "collect: pusty folder nie tworzy folderu hosta" || fail "collect: pusty folder" "$(ls -laR "$WORK/zebrane-puste")"
out="$(ctl collect 1 --from "$WORK/nie ma" --to "$WORK/zebrane-brak")"; code=$?
expect "collect: brak folderu źródłowego" "$out" "Brak folderu"
