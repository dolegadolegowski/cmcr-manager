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

section "P2: anulowana instalacja z obrazu dysku odmontowuje obraz (AUDIT APL-08)"
# A name of its own: the image is mounted from the uploaded copy in the job's temporary folder.
P2DMG="$WORK/in/p2-anulowanie-$$.dmg"
p2_detach() { # p2_detach NAME – detaches what is left of image NAME, so the run never leaves a volume mounted
  local dev
  for dev in $(hdiutil info 2>/dev/null | awk -v img="/$1" '/^image-path/ {m = index($0, img) > 0} m && /^\/dev\/disk[0-9]+[ \t]/ {print $1}'); do
    hdiutil detach "$dev" -force -quiet 2>/dev/null
  done
}
mkdir -p "$P2/pkgroot/cmcr" "$P2/dmgsrc"
echo x > "$P2/pkgroot/cmcr/plik.txt"
if pkgbuild --quiet --root "$P2/pkgroot" --identifier pl.cmcr.e2e.p2 --version 1.0 --install-location /tmp/cmcr-e2e-never \
     "$P2/dmgsrc/P2.pkg" >/dev/null 2>&1 \
   && hdiutil create -quiet -srcfolder "$P2/dmgsrc" -volname "CMCR P2" -format UDZO "$P2DMG" 2>/dev/null; then
  : > "$WORK/installer.cancel"
  clear_fakelog
  out="$(ctlpw install "$P2DMG" 1 --allow-unsigned)"; code=$?
  rm -f "$WORK/installer.cancel"
  expect "dmg: instalacja przerwana w trakcie (anulowanie)" "$(fakelog)" "installer: anulowano"
  sleep 0.5
  name="$(basename "$P2DMG")"
  if hdiutil info | grep -qF "/$name"; then
    fail "dmg: po anulowaniu obraz nadal zamontowany" "$(hdiutil info | grep -F -A6 "/$name")"
  else
    pass "dmg: po anulowaniu obraz odmontowany"
  fi
  base="$(fakelog | sed -n 's/.*installer -pkg \(\/[^ ]*\/cmcr-mnt\.[A-Za-z0-9]*\)\/.*/\1/p' | head -n 1)"
  if [ -n "$base" ] && [ ! -e "$base" ]; then pass "dmg: po anulowaniu folder montowania usunięty"
  else fail "dmg: po anulowaniu został folder montowania (${base:-?})" "$(fakelog)"; fi
  p2_detach "$name"
  [ -n "$base" ] && rmdir "$base"/* "$base" 2>/dev/null
else
  fail "pkgbuild/hdiutil niedostępne – pominięto test anulowania instalacji z .dmg"
fi

section "P2: instalacja aktualizacji – błąd listy to nie „brak aktualizacji” (AUDIT APL-10)"
printf 'Software Update Tool\n\nFinding available software\nNo new software available.\n' > "$WORK/softwareupdate.list"
clear_fakelog
out="$(ctlpw _builder install-updates 1)"; code=$?
expect_code "updates: brak aktualizacji – kod 0" "$code" 0 "$out"
expect "updates: brak aktualizacji – komunikat" "$out" "Brak aktualizacji do zainstalowania"
expect_not "updates: brak aktualizacji – nic nie instalowano" "$(fakelog)" "--install"
printf 'Software Update Tool\n\nFinding available software\nCannot connect to the Software Update server (test)\n' > "$WORK/softwareupdate.list"
echo 1 > "$WORK/softwareupdate.list.rc"
out="$(ctlpw _builder install-updates 1)"; code=$?
expect_code "updates: lista niedostępna – kod 1" "$code" 1 "$out"
expect "updates: lista niedostępna – błąd z odpowiedzią softwareupdate" "$out" \
  "Nie udało się pobrać listy aktualizacji" "Cannot connect to the Software Update server (test)"
expect_not "updates: lista niedostępna – nie udaje braku aktualizacji" "$out" "Brak aktualizacji do zainstalowania"
echo 0 > "$WORK/softwareupdate.list.rc"
out="$(ctlpw _builder install-updates 1)"; code=$?
expect_code "updates: lista niedostępna (kod 0) – kod 1" "$code" 1 "$out"
expect_not "updates: lista niedostępna (kod 0) – nie udaje braku aktualizacji" "$out" "Brak aktualizacji do zainstalowania"
rm -f "$WORK/softwareupdate.list" "$WORK/softwareupdate.list.rc"
