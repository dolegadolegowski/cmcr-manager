# P2 audit fixes in the remote scripts (package „scripts”): processes, uninstalling, disk images, updates, lesson
# end, delayed power, energy schedule, uploads, folders, readiness, the setup script and the screen preview.
# Sourced by Tests/e2e/run.sh (helpers: section, pass, fail, expect, expect_not, expect_code, ctl, ctlpw, fakelog…).
# Everything runs against folders inside $WORK and the fakes in fakes.sh (control files in $WORK).

P2="$WORK/p2"
mkdir -p "$P2"
p2_mkapp() { # p2_mkapp DIR NAME – minimal application bundle running a copy of /bin/sleep
  mkdir -p "$1/$2.app/Contents/MacOS"
  cp /bin/sleep "$1/$2.app/Contents/MacOS/$2"
  codesign --force --sign - "$1/$2.app/Contents/MacOS/$2" >/dev/null 2>&1
}
p2_start() { # p2_start EXECUTABLE – starts it detached (no job notices) and prints its PID
  ( "$1" 300 >/dev/null 2>&1 & echo $! )
}
p2_alive() { kill -0 "$1" 2>/dev/null; }

section "P2: zamykanie procesu po PID (AUDIT APL-06)"
ROOTPID="$(ps -axo pid=,user= | awk '$2 == "root" && $1 > 1 {print $1; exit}')"
clear_fakelog
out="$(ctlpw kill "$ROOTPID" 1 --force)"; code=$?
expect "kill: proces innego konta – odmowa" "$out" "Odmowa" "nie do zalogowanego użytkownika"
expect_code "kill: proces innego konta – kod 1" "$code" 1 "$out"
expect_not "kill: proces innego konta – nic nie wysłano przez sudo" "$(fakelog)" "sudo kill"

section "P2: odinstalowanie – dowiązania, ochrona i kolejność (AUDIT APL-07)"
mkdir -p "$P2/cel"
p2_mkapp "$P2/cel" P2Link
ln -s "$P2/cel/P2Link.app" "$WORK/Applications/P2Link.app"
pid="$(p2_start "$P2/cel/P2Link.app/Contents/MacOS/P2Link")"
sleep 0.3
out="$(ctlpw _builder uninstall 1 "$WORK/Applications/P2Link.app")"; code=$?
expect "uninstall: dowiązanie (jak Safari) odrzucone" "$out" "dowiązanie"
expect_code "uninstall: dowiązanie – kod 2" "$code" 2 "$out"
if p2_alive "$pid"; then pass "uninstall: dowiązanie – aplikacja nie została zamknięta"
else fail "uninstall: dowiązanie – aplikację zamknięto, choć jej nie usunięto" "$out"; fi
[ -L "$WORK/Applications/P2Link.app" ] && pass "uninstall: dowiązanie zostało" || fail "uninstall: dowiązanie usunięte"
kill "$pid" 2>/dev/null

p2_mkapp "$WORK/Applications" P2Sys
echo "$WORK/Applications/P2Sys.app" > "$WORK/restricted.paths"
pid="$(p2_start "$WORK/Applications/P2Sys.app/Contents/MacOS/P2Sys")"
sleep 0.3
out="$(ctlpw _builder uninstall 1 "$WORK/Applications/P2Sys.app")"; code=$?
rm -f "$WORK/restricted.paths"
expect "uninstall: aplikacja chroniona przez SIP odrzucona" "$out" "chroniona przez macOS"
expect_code "uninstall: aplikacja chroniona – kod 2" "$code" 2 "$out"
if p2_alive "$pid"; then pass "uninstall: aplikacja chroniona – nie została zamknięta"
else fail "uninstall: aplikacja chroniona – zamknięta, choć nie da się jej usunąć" "$out"; fi
kill "$pid" 2>/dev/null

mkdir -p "$WORK/Applications/P2Blok"
p2_mkapp "$WORK/Applications/P2Blok" P2Stuck
pid="$(p2_start "$WORK/Applications/P2Blok/P2Stuck.app/Contents/MacOS/P2Stuck")"
sleep 0.3
chmod 555 "$WORK/Applications/P2Blok"
out="$(ctlpw _builder uninstall 1 "$WORK/Applications/P2Blok/P2Stuck.app")"; code=$?
chmod 755 "$WORK/Applications/P2Blok"
expect "uninstall: nie da się usunąć – komunikat" "$out" "Nie udało się usunąć"
expect_code "uninstall: nie da się usunąć – kod 1" "$code" 1 "$out"
if p2_alive "$pid"; then pass "uninstall: nie da się usunąć – aplikacji nie zamknięto"
else fail "uninstall: aplikację zamknięto przed sprawdzeniem, czy da się ją usunąć" "$out"; fi
[ -x "$WORK/Applications/P2Blok/P2Stuck.app/Contents/MacOS/P2Stuck" ] && pass "uninstall: nie da się usunąć – pakiet nietknięty" \
  || fail "uninstall: nie da się usunąć – pakiet częściowo usunięty" "$(find "$WORK/Applications/P2Blok" 2>&1)"
kill "$pid" 2>/dev/null

p2_mkapp "$WORK/Applications" P2Gone
pid="$(p2_start "$WORK/Applications/P2Gone.app/Contents/MacOS/P2Gone")"
sleep 0.3
out="$(ctlpw _builder uninstall 1 "$WORK/Applications/P2Gone.app")"; code=$?
expect_code "uninstall: uruchomiona aplikacja – kod 0" "$code" 0 "$out"
sleep 0.3
[ ! -e "$WORK/Applications/P2Gone.app" ] && pass "uninstall: uruchomiona aplikacja usunięta" || fail "uninstall: aplikacja nadal jest" "$out"
if p2_alive "$pid"; then fail "uninstall: proces usuniętej aplikacji nadal działa"; kill "$pid"; else pass "uninstall: proces aplikacji zakończony"; fi
left="$(ls -A "$WORK/Applications" | grep -c cmcr-)"
[ "$left" = 0 ] && pass "uninstall: brak pozostałości" || fail "uninstall: pozostałości" "$(ls -A "$WORK/Applications")"
