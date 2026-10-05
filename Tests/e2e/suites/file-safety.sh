# File safety (F2): root file operations must not follow links a student planted, and installers need a valid
# Apple signature. Sourced by Tests/e2e/run.sh.
#
# In this harness the "student", the "victim" and the administrator are all the user running the tests, so a
# link created here is owned by that user, not by root – exactly like a link a student would plant on an iMac.
# Every victim folder lives in $WORK; the fake sudo runs as this user and chown only logs.

F2="$WORK/f2"
f2_victim() { # f2_victim DIR – a folder of "another account" with known contents
  rm -rf "$1"; mkdir -p "$1/Stare/ukryte"
  echo "dane ofiary" > "$1/dokument.txt"
  echo "plan" > "$1/plan.txt"
  echo "tajne" > "$1/Stare/ukryte/sekret.txt"
  chmod 700 "$1/Stare/ukryte"; chmod 600 "$1/Stare/ukryte/sekret.txt"
}
f2_intact() { # f2_intact NAME DIR – the victim folder is exactly as f2_victim left it
  local d="$2" got
  got="$(cd "$d" 2>/dev/null && find . | LC_ALL=C sort | tr '\n' ' ')"
  if [ "$got" = ". ./Stare ./Stare/ukryte ./Stare/ukryte/sekret.txt ./dokument.txt ./plan.txt " ] \
     && [ "$(cat "$d/plan.txt")" = plan ] && [ "$(stat -f %Lp "$d/Stare/ukryte")" = 700 ] \
     && [ "$(stat -f %Lp "$d/Stare/ukryte/sekret.txt")" = 600 ]; then
    pass "$1"
  else
    fail "$1" "$(ls -laR "$d" 2>&1)"
  fi
}
mkdir -p "$F2"

section "Bezpieczeństwo plików – czyszczenie przez dowiązanie ucznia"
f2_victim "$F2/ofiara/Documents"
mkdir -p "$F2/uczen/Public"
ln -s "$F2/ofiara/Documents" "$F2/uczen/Public/cmcr"
out="$(ctlpw _builder clean-folder 1 "$F2/uczen/Public/cmcr")"; code=$?
expect_code "clean: folder ucznia podmieniony na dowiązanie – kod 2" "$code" 2 "$out"
expect "clean: odmowa z nazwą dowiązania" "$out" "Odmowa" "dowiązanie" "$F2/uczen/Public/cmcr"
f2_intact "clean: pliki innego konta nietknięte" "$F2/ofiara/Documents"
out="$(ctlpw _builder clean-folder 1 "$F2/uczen/Public/cmcr" --dry-run)"; code=$?
expect_code "clean --dry-run: odmowa także przy podglądzie" "$code" 2 "$out"
expect_not "clean --dry-run: bez listy cudzych plików" "$out" "dokument.txt"
f2_victim "$F2/ofiara/Documents"
out="$(ctlpw clean "$F2/uczen/Public/cmcr" 1 --yes)"; code=$?
[ "$code" != 0 ] && pass "cmcrctl clean: odmowa (kod $code)" || fail "cmcrctl clean: wyczyszczono przez dowiązanie" "$out"
f2_intact "cmcrctl clean: pliki innego konta nietknięte" "$F2/ofiara/Documents"
# A link in the middle of the path (the student swapped Public itself).
f2_victim "$F2/ofiara/Documents"
mkdir -p "$F2/uczen2"
ln -s "$F2/ofiara" "$F2/uczen2/Public"
out="$(ctlpw _builder clean-folder 1 "$F2/uczen2/Public/Documents")"; code=$?
expect_code "clean: dowiązanie w środku ścieżki – kod 2" "$code" 2 "$out"
f2_intact "clean: dowiązanie w środku ścieżki – pliki nietknięte" "$F2/ofiara/Documents"
# The guard must not block ordinary folders reached through root's own links (/tmp → /private/tmp).
mkdir -p "$F2/zwykly/sub" && echo x > "$F2/zwykly/sub/x"
out="$(ctlpw _builder clean-folder 1 "$F2/zwykly")"; code=$?
expect_code "clean: zwykły folder (przez systemowe /tmp) – kod 0" "$code" 0 "$out"
[ -d "$F2/zwykly" ] && [ -z "$(ls -A "$F2/zwykly")" ] && pass "clean: zwykły folder wyczyszczony" || fail "clean: zwykły folder" "$(ls -la "$F2/zwykly")"

section "Bezpieczeństwo plików – Zbierz prace przez dowiązanie ucznia"
f2_victim "$F2/ofiara/Documents"
out="$(ctlpw collect 1 --from "$F2/uczen/Public/cmcr" --to "$F2/zebrane" --no-date --clean --root)"; code=$?
[ "$code" != 0 ] && pass "collect --clean --root: odmowa (kod $code)" || fail "collect --clean --root: zebrano przez dowiązanie" "$out"
expect "collect: komunikat o dowiązaniu" "$out" "dowiązanie"
f2_intact "collect --clean: pliki innego konta nietknięte" "$F2/ofiara/Documents"
[ -z "$(find "$F2/zebrane" -name 'dokument.txt' 2>/dev/null)" ] && pass "collect: cudze pliki nie trafiły do nauczyciela" \
  || fail "collect: skopiowano pliki innego konta" "$(find "$F2/zebrane" 2>&1)"
# removeCollected on its own: a collected subfolder swapped for a link to another account afterwards. The
# student even copied the victim file's size and time, so only the link guard can stop the deletion.
mkdir -p "$F2/zrodlo"
f2_victim "$F2/ofiara2"
ln -s "$F2/ofiara2/Stare/ukryte" "$F2/zrodlo/projekt"
chmod 755 "$F2/ofiara2/Stare/ukryte"; chmod 644 "$F2/ofiara2/Stare/ukryte/sekret.txt"
spec="$(stat -f '%m:%z' "$F2/ofiara2/Stare/ukryte/sekret.txt"):projekt/sekret.txt"
out="$(ctlpw _builder remove-collected 1 "$F2/zrodlo" "$spec" --root)"; code=$?
[ -f "$F2/ofiara2/Stare/ukryte/sekret.txt" ] && pass "removeCollected: plik za podmienionym dowiązaniem nietknięty" \
  || fail "removeCollected: usunięto plik innego konta przez dowiązanie" "$out"
expect "removeCollected: odmowa z nazwą dowiązania" "$out" "Odmowa" "$F2/zrodlo/projekt"
chmod 700 "$F2/ofiara2/Stare/ukryte"; chmod 600 "$F2/ofiara2/Stare/ukryte/sekret.txt"
f2_victim "$F2/ofiara/Documents"
out="$(ctlpw _builder remove-collected 1 "$F2/uczen/Public/cmcr" "$(stat -f '%m:%z' "$F2/ofiara/Documents/plan.txt"):plan.txt" --root)"; code=$?
expect_code "removeCollected: źródło podmienione na dowiązanie – kod 65" "$code" 65 "$out"
f2_intact "removeCollected: źródło-dowiązanie – pliki nietknięte" "$F2/ofiara/Documents"
# Still works on a real folder (the size and time match, so the file goes).
mkdir -p "$F2/zrodlo2/sub" && echo "praca" > "$F2/zrodlo2/sub/praca.txt"
out="$(ctlpw _builder remove-collected 1 "$F2/zrodlo2" "$(stat -f '%m:%z' "$F2/zrodlo2/sub/praca.txt"):sub/praca.txt" --root)"; code=$?
expect_code "removeCollected: zwykły folder – kod 0" "$code" 0 "$out"
[ ! -e "$F2/zrodlo2/sub/praca.txt" ] && pass "removeCollected: zebrany plik usunięty" || fail "removeCollected: plik został" "$out"

section "Bezpieczeństwo plików – Przeglądarka: usuwanie przez dowiązanie"
f2_victim "$F2/ofiara/Documents"
out="$(ctl rm 1 "$F2/uczen/Public/cmcr/dokument.txt")"; code=$?
expect_code "rm: element za dowiązaniem ucznia – kod 65" "$code" 65 "$out"
f2_intact "rm: pliki innego konta nietknięte" "$F2/ofiara/Documents"
ln -s "$F2/ofiara/Documents" "$F2/zwykly/skrot"
out="$(ctl rm 1 "$F2/zwykly/skrot")"; code=$?
expect_code "rm: samo dowiązanie można usunąć – kod 0" "$code" 0 "$out"
[ ! -L "$F2/zwykly/skrot" ] && pass "rm: dowiązanie usunięte" || fail "rm: dowiązanie zostało" "$out"
f2_intact "rm: cel dowiązania nietknięty" "$F2/ofiara/Documents"

section "Bezpieczeństwo plików – zakończenie zajęć z podmienionym folderem ucznia"
f2_victim "$F2/ofiara/Documents"
cp "$WORK/config/settings.json" "$F2/settings.json.bak"
python3 - "$WORK/config/settings.json" "$F2/uczen/Public/cmcr" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["sharedFolder"] = sys.argv[2]; json.dump(s, open(p, "w"))
PY
python3 - "$WORK/config/classroom.json" <<'PY'
import json, sys
cfg = {"end": {"warn": False, "collect": True, "collectLabel": "F2", "quitApps": False, "cleanShared": True,
               "cleanDownloads": False, "logout": False, "power": "none"}}
json.dump(cfg, open(sys.argv[1], "w"), ensure_ascii=False)
PY
out="$(ctlpw lesson end 1 --no-wait)"; code=$?
[ "$code" != 0 ] && pass "lesson end: zbieranie przez dowiązanie odrzucone (kod $code)" || fail "lesson end: zebrano przez dowiązanie" "$out"
f2_intact "lesson end: pliki innego konta nietknięte (bez zbierania i czyszczenia)" "$F2/ofiara/Documents"
[ -z "$(find "$WORK/local" -path '*F2*' -name 'dokument.txt' 2>/dev/null)" ] && pass "lesson end: cudze pliki nie zostały zebrane" \
  || fail "lesson end: zebrano pliki innego konta" "$(find "$WORK/local" -path '*F2*' 2>&1)"
cp "$F2/settings.json.bak" "$WORK/config/settings.json"
rm -f "$WORK/config/classroom.json"

section "Bezpieczeństwo plików – wysyłanie do podmienionego folderu"
mkdir -p "$F2/wyslij/Lekcja" && echo "nowe" > "$F2/wyslij/Lekcja/notatki.txt" && echo "nowy plan" > "$F2/wyslij/plan.txt"
f2_victim "$F2/ofiara3"
mkdir -p "$F2/uczen3/Public"
ln -s "$F2/ofiara3" "$F2/uczen3/Public/cmcr"
out="$(ctlpw _builder push 1 "$F2/uczen3/Public/cmcr" "$ME" 777 "$F2/wyslij/Lekcja" "$F2/wyslij/plan.txt" --root)"; code=$?
expect_code "push: folder docelowy to dowiązanie ucznia – kod 2" "$code" 2 "$out"
expect "push: odmowa z nazwą dowiązania" "$out" "dowiązanie" "$F2/uczen3/Public/cmcr"
f2_intact "push: folder innego konta nietknięty (bez nowych plików i zmiany uprawnień)" "$F2/ofiara3"
f2_victim "$F2/ofiara4"
mkdir -p "$F2/uczen4"
ln -s "$F2/ofiara4" "$F2/uczen4/Public"
out="$(ctlpw _builder push 1 "$F2/uczen4/Public/cmcr" "$ME" 777 "$F2/wyslij/plan.txt" --root)"; code=$?
expect_code "push: dowiązanie w środku ścieżki (brak folderu cmcr) – kod 2" "$code" 2 "$out"
[ ! -e "$F2/ofiara4/cmcr" ] && pass "push: nie utworzono folderu u innego konta" || fail "push: utworzono $F2/ofiara4/cmcr" "$out"
# Hard link to another account's file planted inside an existing folder that gets merged: permissions are set
# on the new files only, never on what was already there.
mkdir -p "$F2/uczen5/cmcr/Lekcja" "$F2/ofiara5"
echo "tajne" > "$F2/ofiara5/sekret.txt"; chmod 600 "$F2/ofiara5/sekret.txt"
ln "$F2/ofiara5/sekret.txt" "$F2/uczen5/cmcr/Lekcja/sekret-link.txt"
out="$(ctlpw _builder push 1 "$F2/uczen5/cmcr" "$ME" 777 "$F2/wyslij/Lekcja" --root)"; code=$?
expect_code "push: scalanie z folderem z twardym dowiązaniem – kod 0" "$code" 0 "$out"
[ "$(stat -f %Lp "$F2/ofiara5/sekret.txt")" = 600 ] && pass "push: plik innego konta (twarde dowiązanie) bez zmiany uprawnień" \
  || fail "push: zmieniono uprawnienia pliku innego konta na $(stat -f %Lp "$F2/ofiara5/sekret.txt")" "$out"
[ "$(stat -f %Lp "$F2/uczen5/cmcr/Lekcja/notatki.txt" 2>/dev/null)" = 666 ] && pass "push: nowy plik w scalonym folderze ma 666" \
  || fail "push: uprawnienia nowego pliku" "$(ls -la "$F2/uczen5/cmcr/Lekcja")"
[ -z "$(ls -A "$F2/uczen5/cmcr" | grep '^\.cmcr')" ] && pass "push: brak plików tymczasowych w folderze ucznia" \
  || fail "push: pozostałości w folderze ucznia" "$(ls -la "$F2/uczen5/cmcr")"
f2_victim "$F2/ofiara6"
chmod 700 "$F2/ofiara6"
mkdir -p "$F2/uczen6/Public"
ln -s "$F2/ofiara6" "$F2/uczen6/Public/cmcr"
out="$(ctlpw _builder prepare-shared 1 "$F2/uczen6/Public/cmcr" "$ME")"; code=$?
expect_code "prepare-shared: folder to dowiązanie ucznia – kod 2" "$code" 2 "$out"
[ "$(stat -f %Lp "$F2/ofiara6")" = 700 ] && pass "prepare-shared: folder innego konta bez chmod 777" \
  || fail "prepare-shared: chmod 777 na folderze innego konta" "$out"

section "Bezpieczeństwo instalacji – podpis i https"
mkdir -p "$F2/pkgroot/x" "$F2/in"
echo x > "$F2/pkgroot/x/plik.txt"
if pkgbuild --quiet --root "$F2/pkgroot" --identifier pl.cmcr.e2e.f2 --version 1.0 --install-location /tmp/cmcr-e2e-never \
    "$F2/in/Niepodpisany.pkg" >/dev/null 2>&1; then
  clear_fakelog
  out="$(ctlpw install "$F2/in/Niepodpisany.pkg" 1)"; code=$?
  [ "$code" != 0 ] && pass "install: pakiet bez podpisu odrzucony (kod $code)" || fail "install: zainstalowano pakiet bez podpisu" "$out"
  expect "install: komunikat o braku podpisu i o opcji" "$out" "podpisu" "--allow-unsigned"
  expect_not "install: installer nie uruchomiony" "$(fakelog)" "installer -pkg"
  clear_fakelog
  out="$(ctlpw install "$F2/in/Niepodpisany.pkg" 1 --allow-unsigned)"; code=$?
  expect_code "install --allow-unsigned: kod 0" "$code" 0 "$out"
  expect "install --allow-unsigned: ostrzeżenie" "$out" "bez podpisu"
  expect "install --allow-unsigned: installer uruchomiony" "$(fakelog)" "installer -pkg" "Niepodpisany.pkg"
  clear_fakelog
  out="$(ctlpw install-url "file://$F2/in/Niepodpisany.pkg" 1)"; code=$?
  [ "$code" != 0 ] && pass "install-url: pakiet bez podpisu odrzucony (kod $code)" || fail "install-url: zainstalowano bez podpisu" "$out"
  expect_not "install-url: installer nie uruchomiony" "$(fakelog)" "installer -pkg"
  SUM="$(shasum -a 256 "$F2/in/Niepodpisany.pkg" | awk '{print $1}')"
  clear_fakelog
  out="$(ctlpw install-url "file://$F2/in/Niepodpisany.pkg" 1 --allow-unsigned --sha256 0000000000000000000000000000000000000000000000000000000000000000)"; code=$?
  expect_code "install-url --sha256: zła suma – kod 2" "$code" 2 "$out"
  expect "install-url --sha256: komunikat" "$out" "SHA-256"
  expect_not "install-url --sha256: zła suma – installer nie uruchomiony" "$(fakelog)" "installer -pkg"
  clear_fakelog
  out="$(ctlpw install-url "file://$F2/in/Niepodpisany.pkg" 1 --allow-unsigned --sha256 "$(printf '%s' "$SUM" | tr a-f A-F)")"; code=$?
  expect_code "install-url --sha256: zgodna suma – kod 0" "$code" 0 "$out"
  expect "install-url --sha256: zgodna suma – instalacja" "$(fakelog)" "installer -pkg"
  # Plain http is refused even when the server answers (a LAN attacker could swap the file).
  HTTP_PORT=$((PORT + 20000))
  ( cd "$F2/in" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  HTTPD=$!
  for _ in $(seq 1 50); do nc -z 127.0.0.1 "$HTTP_PORT" 2>/dev/null && break; sleep 0.1; done
  clear_fakelog
  out="$(ctlpw install-url "http://127.0.0.1:$HTTP_PORT/Niepodpisany.pkg" 1 --allow-unsigned)"; code=$?
  [ "$code" != 0 ] && pass "install-url: http:// odrzucony (kod $code)" || fail "install-url: zainstalowano z http://" "$out"
  expect "install-url: komunikat https" "$out" "https://"
  expect_not "install-url: http – installer nie uruchomiony" "$(fakelog)" "installer -pkg"
  out="$(ctlpw _builder install-url 1 "http://127.0.0.1:$HTTP_PORT/Niepodpisany.pkg")"; code=$?
  expect_code "installFromURL: http:// odrzucony także na iMacu – kod 2" "$code" 2 "$out"
  kill "$HTTPD" 2>/dev/null; wait "$HTTPD" 2>/dev/null
else
  fail "pkgbuild niedostępny – pominięto testy podpisu .pkg"
fi
mkdir -p "$F2/appsrc/F2Adhoc.app/Contents/MacOS"
cp /bin/sleep "$F2/appsrc/F2Adhoc.app/Contents/MacOS/F2Adhoc"
codesign --force --sign - "$F2/appsrc/F2Adhoc.app/Contents/MacOS/F2Adhoc" >/dev/null 2>&1
(cd "$F2/appsrc" && ditto -c -k --keepParent F2Adhoc.app "$F2/in/F2Adhoc.zip")
out="$(ctlpw install "$F2/in/F2Adhoc.zip" 1)"; code=$?
[ "$code" != 0 ] && pass "install .zip: aplikacja bez notaryzacji odrzucona (kod $code)" || fail "install .zip: zainstalowano aplikację bez podpisu" "$out"
[ ! -e "$WORK/Applications/F2Adhoc.app" ] && pass "install .zip: aplikacja nie skopiowana" || fail "install .zip: aplikacja w Applications"
out="$(ctlpw install "$F2/in/F2Adhoc.zip" 1 --allow-unsigned)"; code=$?
expect_code "install .zip --allow-unsigned: kod 0" "$code" 0 "$out"
[ -d "$WORK/Applications/F2Adhoc.app" ] && pass "install .zip --allow-unsigned: aplikacja zainstalowana" || fail "install .zip --allow-unsigned" "$out"
rm -rf "$WORK/Applications/F2Adhoc.app"
# A notarized app (if this Mac has a small one) passes without the override.
signed=""
for a in /Applications/*.app; do
  [ -d "$a" ] || continue
  [ "$(du -sm "$a" 2>/dev/null | cut -f1)" -lt 80 ] 2>/dev/null || continue
  /usr/sbin/spctl --assess --type execute "$a" >/dev/null 2>&1 || continue
  signed="$a"; break
done
if [ -n "$signed" ]; then
  sname="$(basename "$signed")"
  (cd "$(dirname "$signed")" && ditto -c -k --keepParent "$sname" "$F2/in/podpisana.zip")
  out="$(ctlpw install "$F2/in/podpisana.zip" 1)"; code=$?
  expect_code "install: aplikacja z notaryzacją ($sname) – kod 0" "$code" 0 "$out"
  expect "install: podpis sprawdzony" "$out" "Podpis sprawdzony"
  [ -d "$WORK/Applications/$sname" ] && pass "install: podpisana aplikacja zainstalowana" || fail "install: brak $sname" "$out"
  rm -rf "$WORK/Applications/$sname"
else
  echo "  (brak małej aplikacji z notaryzacją w /Applications – pominięto test pozytywny)"
fi
rm -rf "$F2"
