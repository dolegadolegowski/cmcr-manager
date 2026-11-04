# shellcheck shell=bash
# Review findings in the app's views (AUDIT REV-27, group G5-views). Sourced by Tests/e2e/run.sh (helpers and
# $WORK $CTL $PASSWORD $ME come from there).
# After an install the app (UpdatesView, UpdateInfo.remaining) keeps offering what Scripts.installUpdates did not
# install, reading the install's „→ label” lines. These checks hold the script to that: one line for every
# installed label and none for a skipped one.

section "Instalacja aktualizacji: „→ etykieta” tylko przy zainstalowanych (AUDIT REV-27)"
rm -f "$WORK/softwareupdate.list" "$WORK/softwareupdate.list.rc"
clear_fakelog
out="$(ctlpw updates install 1)"; code=$?
expect_code "bez nowej wersji macOS: kod 0" "$code" 0 "$out"
expect "bez nowej wersji macOS: zainstalowana etykieta wypisana" "$out" "→ Safari99.1-99.1"
expect "bez nowej wersji macOS: pominięcie wypisane" "$out" "↷ Pominięto przejście na nową wersję systemu: macOS Testowy 99.1"
expect_not "bez nowej wersji macOS: pominięta etykieta bez „→”" "$out" "→ macOS Testowy 99.1-99A123"

out="$(ctlpw updates install 1 --major --yes)"; code=$?
expect_code "z nową wersją macOS: kod 0" "$code" 0 "$out"
expect "z nową wersją macOS: obie etykiety wypisane" "$out" "→ macOS Testowy 99.1-99A123" "→ Safari99.1-99.1"

# An optional update (without „Recommended: YES”) is skipped by „Tylko zalecane” without a word: only its missing
# „→” line tells the app that it is still pending.
cat > "$WORK/softwareupdate.list" <<'LIST'
Software Update Tool

Finding available software
Software Update found the following new or updated software:
* Label: Safari99.1-99.1
	Title: Safari, Version: 99.1, Size: 123456KiB, Recommended: YES,
* Label: Dodatek-1.0
	Title: Dodatek, Version: 1.0, Size: 12KiB,
LIST
clear_fakelog
out="$(ctlpw updates install 1 --recommended)"; code=$?
expect_code "tylko zalecane: kod 0" "$code" 0 "$out"
expect "tylko zalecane: zalecana etykieta wypisana" "$out" "→ Safari99.1-99.1"
expect_not "tylko zalecane: dodatkowa etykieta bez „→”" "$out" "→ Dodatek-1.0"
expect_not "tylko zalecane: dodatkowa nie jest instalowana" "$(fakelog)" "Dodatek-1.0"

# Only a new major version on the list: nothing is installed and the run still succeeds.
cat > "$WORK/softwareupdate.list" <<'LIST'
Software Update Tool

Finding available software
Software Update found the following new or updated software:
* Label: macOS Testowy 99.1-99A123
	Title: macOS Testowy 99.1, Version: 99.1, Size: 1234567KiB, Recommended: YES, Action: restart,
LIST
clear_fakelog
out="$(ctlpw updates install 1)"; code=$?
expect_code "tylko nowa wersja macOS: kod 0 mimo braku instalacji" "$code" 0 "$out"
expect "tylko nowa wersja macOS: pominięcie i brak instalacji wypisane" "$out" "↷ Pominięto" "✔ Brak aktualizacji do zainstalowania."
expect_not "tylko nowa wersja macOS: bez „→” przy etykiecie" "$out" "→ macOS Testowy"
expect_not "tylko nowa wersja macOS: softwareupdate --install nie uruchomiony" "$(fakelog)" "softwareupdate --install"
rm -f "$WORK/softwareupdate.list" "$WORK/softwareupdate.list.rc"
