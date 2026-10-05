# cmcrctl module commands (lesson, lock, rename, rm, install, collect, …) follow the rules of the core commands:
# per-command --help that never runs anything, rejected unknown options and surplus arguments, no "all Macs"
# without a host list in scripts, confirmations, exit codes 0/1/2, and terminal-safe output of remote text.
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT come from there). Own config folder.

MM="$WORK/cfg-modules"
mkdir -p "$MM"
cp "$WORK/config/settings.json" "$MM/"
cat > "$MM/hosts.json" <<EOF
[
 {"name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"name":"imac02","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"name":"imac03","address":"127.0.0.1","user":"$ME","port":$PORT}
]
EOF
# A disruptive end of lesson (it logs the student out): needs a confirmation.
cat > "$MM/classroom.json" <<'EOF'
{"end": {"warn": false, "collect": false, "quitApps": false, "cleanShared": false, "cleanDownloads": false,
         "logout": true, "power": "none"}}
EOF
mm() { CMCR_CONFIG_DIR="$MM" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
# At a terminal (stdin, stdout and stderr on a pty).
mm_tty() { CMCR_CONFIG_DIR="$MM" CMCR_PASSWORD="$PASSWORD" script -q /dev/null "$CTL" "$@" </dev/null 2>&1; }
delayed_power() { pgrep -U "$(id -u)" -f cmcr-delayed-power 2>/dev/null; }
# Bytes a terminal would interpret: C0 controls other than tab/LF (CR LF from the pty is fine), DEL, C1 (C2 80–9F),
# and bidi overrides (U+202A–U+202E, U+2066–U+2069) that reorder what is shown.
# script(1) itself echoes the EOF of its /dev/null stdin as "^D" + two backspaces, and $(…) drops the LF of the
# last CR LF: neither comes from cmcrctl.
term_unsafe() {
  printf '%s' "$1" | python3 -c 'import sys
d = sys.stdin.buffer.read()
if d.startswith(b"^D\x08\x08"): d = d[4:]
d = d.replace(b"\r\n", b"\n")
if d.endswith(b"\r"): d = d[:-1]
bad = sorted({c for c in d if (c < 32 and c not in (9, 10)) or c == 127})
c1 = [i for i in range(len(d) - 1) if d[i] == 0xC2 and 0x80 <= d[i + 1] <= 0x9F]
bidi = [ch for ch in d.decode("utf-8", "replace") if 0x202A <= ord(ch) <= 0x202E or 0x2066 <= ord(ch) <= 0x2069]
print(" ".join("%02x" % c for c in bad) + (" C1" if c1 else "") + (" BIDI" if bidi else ""))'
}

# A regression could start delayed power actions (power-later): they run in a detached bash, which must see
# the fakes too. Without that, those checks are skipped.
mm_bg="$(ctlpw exec '/bin/bash --noprofile --norc -c "type shutdown pmset" 2>&1 | grep -c "is a function"' 1 --root | tail -1)"
MM_POWER=0
if [ "$mm_bg" = 2 ]; then MM_POWER=1; else fail "atrapy nieaktywne w procesach w tle – testy power-later pominięte" "$mm_bg"; fi
stop_delayed_power() { delayed_power | xargs kill 2>/dev/null; }

section "cmcrctl – pomoc poleceń (--help, -h niczego nie wykonują)"
clear_fakelog
MM_HELP=(lock unlock rename rename-computer "lesson end" "lesson start" "schedule clear" "schedule set" power-cancel
         filevault report "ask Pytanie" "app-version Safari" rm mkdir exists collect get ls install install-url screen-watch)
[ "$MM_POWER" = 1 ] && MM_HELP+=("power-later shutdown 5")
for cmd in "${MM_HELP[@]}"; do
  ok=1
  for h in --help -h; do
    out="$(mm $cmd $h </dev/null)"; code=$?
    if [ "$code" != 0 ] || ! contains "" "$out" "Użycie:" || ! contains "" "$out" "cmcrctl ${cmd%% *} " \
       || contains "" "$out" "imac01:"; then
      ok=0; fail "$cmd $h: zamiast pomocy (kod $code)" "$out"; break
    fi
  done
  [ "$ok" = 1 ] && pass "$cmd --help / -h: pomoc, kod 0"
done
out="$(mm lock help </dev/null)"; code=$?
expect_code "lock help: kod 0" "$code" 0 "$out"
expect "lock help: pomoc polecenia" "$out" "cmcrctl lock KOMP" "Kody wyjścia"
expect "rename --help: obie formy" "$(mm rename --help)" "rename nr ścieżka nowa-nazwa" "rename KOMP [--name"
if [ -z "$(fakelog)" ] && [ ! -e "$MM/--help" ]; then pass "--help: na żadnym komputerze nic nie wykonano"
else fail "--help: wykonano polecenia" "$(fakelog)"; fi

section "cmcrctl – opcje i argumenty poleceń modułów"
clear_fakelog
out="$(mm lock 1 --bogus)"; code=$?
expect_code "lock --bogus: kod 2" "$code" 2 "$out"
expect "lock --bogus: komunikat" "$out" "Nieznana opcja: --bogus" "Pomoc: cmcrctl lock --help"
out="$(mm lock 1 --mesage "Literówka")"; code=$?
expect_code "lock --mesage (literówka): kod 2" "$code" 2 "$out"
out="$(mm unlock 1 imac02)"; code=$?
expect_code "unlock 1 imac02: kod 2" "$code" 2 "$out"
expect "unlock 1 imac02: nadmiarowy argument" "$out" "Nadmiarowy argument „imac02”" "1,3 lub 1-5"
out="$(mm unlock 1 --bogus)"; code=$?
expect_code "unlock --bogus: kod 2" "$code" 2 "$out"
out="$(mm lock 1 --root)"; code=$?
expect "lock --root: opcja innego polecenia" "$out" "Opcja --root nie dotyczy polecenia lock"
expect_code "lock --root: kod 2" "$code" 2 "$out"
out="$(mm ask "Pytanie" 1 -j 2)"; code=$?
expect "ask -j: ask pyta wszystkie naraz" "$out" "Opcja -j nie dotyczy polecenia ask"
expect_code "ask -j: kod 2" "$code" 2 "$out"
out="$(mm lock 1 --minutes dużo)"; code=$?
expect_code "lock --minutes (nie liczba): kod 2" "$code" 2 "$out"
out="$(mm lock 1 --mode zasłona)"; code=$?
expect_code "lock --mode (nieznany tryb): kod 2" "$code" 2 "$out"
out="$(mm schedule show 1 --on MTWRF@07:45)"; code=$?
expect "schedule show --on: tylko dla set" "$out" "dotyczy tylko polecenia schedule set"
expect_code "schedule show --on: kod 2" "$code" 2 "$out"
if [ "$MM_POWER" = 1 ]; then
  out="$(mm power-later shutdown 5 1 2)"; code=$?
  expect_code "power-later … 1 2: kod 2" "$code" 2 "$out"
fi
out="$(mm ls all "$WORK/remote")"; code=$?
expect "ls all: jeden komputer" "$out" "Podaj jeden komputer"
expect_code "ls all: kod 2" "$code" 2 "$out"
if [ -z "$(fakelog)" ] && [ -z "$(delayed_power)" ]; then pass "błędne użycie: nic nie wykonano"
else fail "błędne użycie: wykonano polecenia" "$(fakelog)"; stop_delayed_power; fi

section "cmcrctl – polecenia modułów bez listy komputerów"
echo "instalator" > "$MM/plik.pkg"
clear_fakelog
MM_NOHOST=(lock unlock "lesson start" "lesson end --yes" "schedule clear" "schedule set --on MTWRF@07:45" power-cancel
           "ask Pytanie" "install $MM/plik.pkg" "install-url file:///nie-ma.pkg")
[ "$MM_POWER" = 1 ] && MM_NOHOST+=("power-later shutdown 5 --yes")
for cmd in "${MM_NOHOST[@]}"; do
  out="$(mm $cmd </dev/null)"; code=$?
  if [ "$code" = 2 ] && contains "" "$out" "Podaj komputery dla polecenia ${cmd%% *}"; then
    pass "$cmd bez komputerów w skrypcie: kod 2 z wyjaśnieniem"
  else
    fail "$cmd bez komputerów w skrypcie (kod $code)" "$out"
  fi
done
# The unquoted #3 of the README: a comment, so the script loses the host list.
if [ "$MM_POWER" = 1 ]; then
  out="$(CMCR_CONFIG_DIR="$MM" CMCR_PASSWORD="$PASSWORD" bash -c '"$0" power-later shutdown 5 --yes #3' "$CTL" </dev/null 2>&1)"
  code=$?
  expect_code "power-later … #3 w skrypcie: kod 2" "$code" 2 "$out"
fi
if [ -z "$(fakelog)" ] && [ -z "$(delayed_power)" ]; then pass "bez komputerów: na żadnym nic nie wykonano"
else fail "bez komputerów: wykonano polecenia" "$(fakelog)"; stop_delayed_power; fi
out="$(mm rename --dry-run)"; code=$?
expect_code "rename bez komputerów: kod 2" "$code" 2 "$out"
expect "rename bez komputerów: wskazówka" "$out" "Podaj komputery dla polecenia rename"
out="$(mm_tty rename --dry-run)"
expect "rename bez komputerów także w terminalu: błąd" "$out" "Podaj komputery dla polecenia rename"
expect_not "rename bez komputerów w terminalu: brak podglądu nazw" "$out" "→ imac01.local"
out="$(mm filevault </dev/null)"; code=$?
expect_code "filevault (tylko odczyt) bez komputerów: kod 0" "$code" 0 "$out"
[ "$(printf '%s\n' "$out" | grep -c 'FileVault')" = 3 ] && pass "filevault bez komputerów: wszystkie trzy" \
  || fail "filevault bez komputerów: liczba wyników" "$out"
out="$(mm_tty unlock)"
expect "unlock bez komputerów w terminalu: informacja i wszystkie komputery" "$out" \
  "Nie podano komputerów – unlock na wszystkich: imac01, imac02, imac03 (3 komputery)" "imac03:"

section "cmcrctl – potwierdzenia w poleceniach modułów"
clear_fakelog
if [ "$MM_POWER" = 1 ]; then
  out="$(mm power-later shutdown 5 1 </dev/null)"; code=$?
  expect_code "power-later bez --yes: kod 2" "$code" 2 "$out"
  expect "power-later bez --yes: pytanie z listą komputerów" "$out" "Wyłącz za 5 min: imac01" "dodaj --yes"
fi
out="$(mm lesson end 1 --no-wait </dev/null)"; code=$?
expect_code "lesson end (wylogowanie) bez --yes: kod 2" "$code" 2 "$out"
expect "lesson end bez --yes: kroki w pytaniu" "$out" "Zakończyć zajęcia na: imac01" "dodaj --yes"
out="$(mm rename 1 --name "Nowa nazwa" </dev/null)"; code=$?
expect_code "rename komputera bez --yes: kod 2" "$code" 2 "$out"
RMF="$WORK/remote/mm-do-usuniecia.txt"
echo "x" > "$RMF"
out="$(mm rm 1 "$RMF" </dev/null)"; code=$?
expect_code "rm bez --yes: kod 2" "$code" 2 "$out"
[ -f "$RMF" ] && pass "rm bez --yes: plik został" || fail "rm bez --yes: plik usunięty" "$out"
COL="$WORK/remote/mm-prace"
mkdir -p "$COL"
echo "praca" > "$COL/a.txt"
out="$(mm collect 1 --from "$COL" --to "$WORK/mm-zebrane" --clean </dev/null)"; code=$?
expect_code "collect --clean bez --yes: kod 2" "$code" 2 "$out"
[ -f "$COL/a.txt" ] && [ ! -e "$WORK/mm-zebrane" ] && pass "collect --clean bez --yes: nic nie zebrano ani nie usunięto" \
  || fail "collect --clean bez --yes" "$out"
if [ -z "$(fakelog)" ] && [ -z "$(delayed_power)" ]; then pass "bez potwierdzenia: nic nie wykonano"
else fail "bez potwierdzenia: wykonano polecenia" "$(fakelog)"; stop_delayed_power; fi
out="$(mm rm 1 "$RMF" --yes)"; code=$?
expect_code "rm --yes: kod 0" "$code" 0 "$out"
[ ! -e "$RMF" ] && pass "rm --yes: plik usunięty" || fail "rm --yes: plik został" "$out"
expect_not "rm --yes: --yes nie jest ścieżką" "$out" "podano: --yes"
out="$(mm rm 1 -y --dry-run -- "$COL/a.txt")"; code=$?
expect "rm -y --dry-run -- ścieżka" "$out" "Zostałoby usunięte"
clear_fakelog
out="$(mm lesson end 1 --no-wait --yes)"; code=$?
expect_code "lesson end --yes: kod 0" "$code" 0 "$out"
expect "lesson end --yes: wylogowanie" "$(fakelog)" "launchctl bootout gui/"

section "cmcrctl – -j i --prefix w poleceniach modułów"
out="$(mm unlock 1-3 -j 3 --prefix)"; code=$?
expect_code "unlock -j 3 --prefix: kod 0" "$code" 0 "$out"
order="$(printf '%s\n' "$out" | sed -n 's/^\[\(imac0[0-9]\)\].*/\1/p' | uniq | tr '\n' ' ')"
[ "$order" = "imac01 imac02 imac03 " ] && pass "unlock -j 3 --prefix: wiersze z nazwą, w kolejności listy" \
  || fail "unlock -j 3 --prefix: kolejność „$order”" "$out"
out="$(mm filevault all -j2 --prefix)"; code=$?
expect "filevault -j2 --prefix" "$out" "[imac02] imac02: FileVault"
out="$(mm exists all "$WORK/remote" --jobs 2)"; code=$?
expect_code "exists --jobs 2: kod 0" "$code" 0 "$out"

section "cmcrctl rename – plik czy komputer (liczba argumentów)"
clear_fakelog
for args in "1 $WORK/remote/Public/cmcr/plik.txt" "1 Desktop/a.txt b.txt" "all /x" "1 /x/a.txt b.txt --name X" \
            "1 /x/a.txt b.txt c.txt" "1 /x/a.txt b.txt --update-list" "$WORK/remote/plik.txt"; do
  out="$(mm rename $args --yes </dev/null)"; code=$?
  if [ "$code" = 2 ] && contains "" "$out" "rename nr ścieżka nowa-nazwa"; then pass "rename $args: kod 2 z wyjaśnieniem"
  else fail "rename $args: kod $code" "$out"; fi
done
expect_not "rename: pomyłka przy pliku nie zmienia nazwy komputera" "$(fakelog)" "scutil"
out="$(mm rename-computer 1 --dry-run)"; code=$?
expect_code "rename-computer --dry-run: kod 0" "$code" 0 "$out"
expect "rename-computer --dry-run: podgląd" "$out" "imac01: „imac01” → imac01.local"
out="$(mm rename all --dry-run)"; code=$?
expect "rename all --dry-run: nazwy z listy" "$out" "„imac02” → imac02.local" "„imac03” → imac03.local"
RNF="$WORK/remote/mm-zmiana nazwy.txt"
echo "x" > "$RNF"
out="$(mm rename 1 "$RNF" "mm-nowa nazwa.txt")"; code=$?
expect_code "rename pliku: kod 0" "$code" 0 "$out"
[ -f "$WORK/remote/mm-nowa nazwa.txt" ] && pass "rename pliku: nazwa zmieniona" || fail "rename pliku" "$out"
expect_not "rename pliku: bez zmiany nazwy komputera" "$(fakelog)" "scutil"

section "cmcrctl – kody wyjścia poleceń modułów (0, 1, 2)"
out="$(ctl unlock 99)"; code=$?
expect_code "unlock: niedostępny komputer – kod 1 (nie 255)" "$code" 1 "$out"
expect "unlock: niedostępny komputer – wyjaśnienie" "$out" "Nie można odnaleźć nazwy hosta"
out="$(ctl mkdir 99 /tmp/cmcr-e2e-nie-tworzyc)"; code=$?
expect_code "mkdir: niedostępny komputer – kod 1" "$code" 1 "$out"
out="$(ctl rm 1 /etc/hosts --dry-run)"; code=$?
expect_code "rm: odmowa – kod 1 (nie 65)" "$code" 1 "$out"
expect "rm: odmowa – komunikat" "$out" "Odmowa"
out="$(ctlpw collect 1 --from "$COL" --to /dev/null/cmcr-e2e)"; code=$?
expect_code "collect: nie można zapisać – kod 1 (nie 0)" "$code" 1 "$out"
expect "collect: nie można zapisać – komunikat" "$out" "Nie można utworzyć"
out="$(ctl get 1 "$COL/a.txt" /dev/null/cmcr-e2e)"; code=$?
expect_code "get: nie można zapisać – kod 1 (nie 255)" "$code" 1 "$out"

section "cmcrctl – znaki sterujące z iMaców w terminalu"
TD="$WORK/remote/mm-znaki"
mkdir -p "$TD"
touch "$TD/$(printf 'a\033]0;OWNED\007\033[2Jz')" "$TD/$(printf 'cr\rSPOOF')" "$TD/$(printf 'c1\302\23331mred')" \
  "$TD/$(printf 'bidi\342\200\256txt.exe')" "$TD/zwykły plik ą.txt" "$TD/„cytat” – notatki….txt"
# Structured listing: names are escaped always (also in a pipe or file).
out="$(ctl ls 1 "$TD")"
expect "ls nr ścieżka: znaki sterujące w nazwach jako \\x.." "$out" 'a\x1B]0;OWNED\x07\x1B[2Jz' 'cr\rSPOOF' \
  'c1\x9B31mred' 'bidi\u{202E}txt.exe' "zwykły plik ą.txt" "„cytat” – notatki….txt"
bad="$(term_unsafe "$out")"
[ -z "$bad" ] && pass "ls nr ścieżka: brak surowych znaków sterujących" || fail "ls nr ścieżka: surowe bajty $bad" "$out"
# Raw remote output (ls -la, exec) at a terminal: shown like cat -v.
out="$(script -q /dev/null "$CTL" ls "$TD" 1 </dev/null 2>&1)"
expect "ls ŚCIEŻKA KOMP (terminal): nazwy widoczne jako ^[ ^M M-^[ <U+202E>" "$out" "a^[]0;OWNED^G^[[2Jz" "cr^MSPOOF" \
  "c1M-^[31mred" "bidi<U+202E>txt.exe" "zwykły plik ą.txt" "„cytat” – notatki….txt"
bad="$(term_unsafe "$out")"
[ -z "$bad" ] && pass "ls ŚCIEŻKA KOMP (terminal): brak surowych znaków sterujących" \
  || fail "ls ŚCIEŻKA KOMP (terminal): surowe bajty $bad" "$out"
out="$(script -q /dev/null "$CTL" exec 'printf "a\033]0;T\007b\rX\n"' 1 --prefix </dev/null 2>&1)"
expect "exec (terminal): sekwencje widoczne, \\r nie nadpisuje prefiksu" "$out" "[imac01] a^[]0;T^Gb^MX"
bad="$(term_unsafe "$out")"
[ -z "$bad" ] && pass "exec (terminal): brak surowych znaków sterujących" || fail "exec (terminal): surowe bajty $bad" "$out"
out="$(ctl exec 'printf "a\033]0;T\007b\n"' 1)"
[ -n "$(term_unsafe "$out")" ] && pass "exec do potoku: wynik dosłowny (bajt po bajcie)" \
  || fail "exec do potoku: wynik zmieniony" "$out"
printf 'Odp\033[2J\033]0;X\007 koniec' > "$WORK/ask.answer"
out="$(ctlpw ask "Gotowe?" 1 --timeout 30)"
expect "ask: odpowiedź ucznia ze znakami sterującymi – widoczne" "$out" 'Odp\x1B[2J\x1B]0;X\x07 koniec'
bad="$(term_unsafe "$out")"
[ -z "$bad" ] && pass "ask: brak surowych znaków sterujących" || fail "ask: surowe bajty $bad" "$out"
rm -f "$WORK/ask.answer"
rm -rf "$TD"
stop_delayed_power
