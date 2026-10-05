# Remote script builders (U2): askpass for Homebrew, installers, push/clean guards, graceful quit and
# logout, FileVault restart, softwareupdate filtering, inventory. Sourced by Tests/e2e/run.sh.
# Every destructive path runs against folders inside $WORK, against fakes, or in dry-run mode.

section "Skrypty – atrapy dla tego zestawu"
s_guard="$(ctlpw exec 'type osascript fdesetup stat diskutil dscl networksetup 2>&1 | grep -c "is a function"' 1 | tail -1)"
s_guard_root="$(ctlpw exec 'type fdesetup shutdown launchctl stat 2>&1 | grep -c "is a function"' 1 --root | tail -1)"
if [ "$s_guard" != 6 ] || [ "$s_guard_root" != 4 ]; then
  fail "atrapy fdesetup/osascript/stat nieaktywne – pomijam zestaw (wynik: $s_guard / $s_guard_root)"
else
pass "atrapy aktywne (także w trybie root)"
mkb() { # mkb DIR NAME BUNDLE_ID – minimal application bundle running a copy of /bin/sleep
  mkdir -p "$1/$2.app/Contents/MacOS"
  cp /bin/sleep "$1/$2.app/Contents/MacOS/$2"
  codesign --force --sign - "$1/$2.app/Contents/MacOS/$2" >/dev/null 2>&1
  if [ -n "${3:-}" ]; then
    cat > "$1/$2.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$3</string>
<key>CFBundleExecutable</key><string>$2</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
</dict></plist>
EOF
  fi
}

section "Skrypty – hasło dla narzędzi uruchamianych przez with_askpass (Homebrew, mas)"
out="$(ctlpw exec 'with_askpass /usr/bin/env -u CMCR_PW /bin/sh -c "\"\$SUDO_ASKPASS\" x"' 1)"
expect "with_askpass: askpass zwraca hasło bez zmiennej CMCR_PW" "$out" "$PASSWORD"
out="$(ctlpw exec 'with_askpass /bin/sh -c "echo D=\$DISPLAY"; with_askpass true; ls -a "$CMCR_TMP"' 1)"
expect "with_askpass: DISPLAY ustawione (sudo bez terminala użyje askpass)" "$out" "D=:0"
expect_not "with_askpass: plik z hasłem usunięty po poleceniu" "$out" "askpass."
clear_fakelog
out="$(ctlpw _builder brew 1 "install oracle-jdk")"
expect "brew: askpass działa mimo filtrowania środowiska przez brew" "$(fakelog)" "brew install oracle-jdk" "brew: askpass ok"
clear_fakelog
out="$(ctlpw _builder mas-upgrade 1)"
expect "mas upgrade: askpass i DISPLAY dla sudo w mas ≥ 4" "$(fakelog)" "mas upgrade" "mas: askpass+DISPLAY ok"

section "Skrypty – instalacja programów (install / install-url)"
# The test installers are unsigned, hence --allow-unsigned; the signature check itself: suites/file-safety.sh.
mkdir -p "$WORK/pkgroot/cmcr" "$WORK/dmgsrc" "$WORK/zipsrc"
echo x > "$WORK/pkgroot/cmcr/plik.txt"
if pkgbuild --quiet --root "$WORK/pkgroot" --identifier pl.cmcr.e2e --version 1.0 --install-location /tmp/cmcr-e2e-never \
    "$WORK/in/Test Pakiet.pkg" >/dev/null 2>&1; then
  clear_fakelog
  out="$(ctlpw install "$WORK/in/Test Pakiet.pkg" 1 --allow-unsigned)"; code=$?
  expect_code "install .pkg: kod 0" "$code" 0 "$out"
  expect "install .pkg: installer -pkg … -target /" "$(fakelog)" "installer -pkg" "Test Pakiet.pkg -target /"
  expect "install .pkg: komunikat" "$out" "Zainstalowano pakiet Test Pakiet.pkg"
  cp "$WORK/in/Test Pakiet.pkg" "$WORK/in/pobrany-bez-rozszerzenia"
  clear_fakelog
  out="$(ctlpw install-url "file://$WORK/in/Test%20Pakiet.pkg" 1 --allow-unsigned)"; code=$?
  expect_code "install-url: kod 0 (file://)" "$code" 0 "$out"
  expect "install-url: pobrany pakiet zainstalowany" "$(fakelog)" "installer -pkg" "Test%20Pakiet.pkg"
  clear_fakelog
  out="$(ctlpw install-url "file://$WORK/in/pobrany-bez-rozszerzenia?token=abc" 1 --allow-unsigned)"
  expect "install-url: typ rozpoznany po zawartości (xar → .pkg)" "$(fakelog)" "pobrany-bez-rozszerzenia.pkg -target /"
  cp "$WORK/in/Test Pakiet.pkg" "$WORK/dmgsrc/Uninstall CMCR.pkg"
else
  fail "pkgbuild niedostępny – pominięto testy .pkg"
fi
out="$(ctlpw install-url "file://$WORK/in/nie-ma-takiego.pkg" 1)"; code=$?
expect "install-url: błąd pobierania" "$out" "Pobieranie nie powiodło się"
# The remote `exit 2` of a failed download is a failure on that Mac (1), not a usage error (2).
expect_code "install-url: kod 1 przy błędzie pobierania" "$code" 1 "$out"

mkb "$WORK/dmgsrc" CMCRDmgApp pl.cmcr.e2e.dmg
if hdiutil create -quiet -srcfolder "$WORK/dmgsrc" -volname "CMCR E2E" -format UDZO "$WORK/in/Test.dmg" 2>/dev/null; then
  clear_fakelog
  out="$(ctlpw install "$WORK/in/Test.dmg" 1 --allow-unsigned)"; code=$?
  expect_code "install .dmg: kod 0" "$code" 0 "$out"
  [ -x "$WORK/Applications/CMCRDmgApp.app/Contents/MacOS/CMCRDmgApp" ] && pass "install .dmg: aplikacja skopiowana do Applications" \
    || fail "install .dmg: brak aplikacji" "$out"
  expect "install .dmg: Uninstall*.pkg pominięty" "$out" "Pomijam Uninstall CMCR.pkg"
  expect_not "install .dmg: deinstalator nie uruchomiony" "$(fakelog)" "Uninstall CMCR.pkg"
  expect_not "install .dmg: bez ostrzeżeń hdiutil w wyniku" "$out" "deprecated"
  left="$(mount | grep -c "cmcr-mnt")"
  [ "$left" = 0 ] && pass "install .dmg: obraz odmontowany" || fail "install .dmg: obraz nadal zamontowany" "$(mount | grep cmcr-mnt)"
else
  fail "hdiutil create nie działa – pominięto test .dmg"
fi

mkb "$WORK/zipsrc" CMCRZipApp pl.cmcr.e2e.zip
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$WORK/zipsrc/CMCRZipApp.app"
(cd "$WORK/zipsrc" && ditto -c -k --keepParent CMCRZipApp.app "$WORK/in/CMCRZipApp.zip")
mkdir -p "$WORK/Applications/CMCRZipApp.app/Contents/Frameworks/Old.framework"
echo stare > "$WORK/Applications/CMCRZipApp.app/Contents/Frameworks/Old.framework/Old"
out="$(ctlpw install "$WORK/in/CMCRZipApp.zip" 1 --allow-unsigned)"; code=$?
expect_code "install .zip: kod 0" "$code" 0 "$out"
[ -x "$WORK/Applications/CMCRZipApp.app/Contents/MacOS/CMCRZipApp" ] && pass "install .zip: aplikacja zainstalowana" \
  || fail "install .zip: brak aplikacji" "$out"
[ ! -e "$WORK/Applications/CMCRZipApp.app/Contents/Frameworks/Old.framework" ] \
  && pass "install .app: stara wersja zastąpiona w całości (bez starych plików)" \
  || fail "install .app: stare pliki zostały w pakiecie" "$(find "$WORK/Applications/CMCRZipApp.app")"
if xattr -p com.apple.quarantine "$WORK/Applications/CMCRZipApp.app" >/dev/null 2>&1; then
  fail "install .app: kwarantanna nie usunięta"
else pass "install .app: kwarantanna usunięta"; fi
extra="$(ls -A "$WORK/Applications" | grep -c cmcr-)"
[ "$extra" = 0 ] && pass "install .app: brak pozostałości .cmcr-new/.cmcr-old" || fail "install .app: pozostałości" "$(ls -A "$WORK/Applications")"

section "Skrypty – odinstalowanie"
out="$(ctlpw _builder uninstall 1 "$WORK/Applications/CMCRDmgApp.app")"; code=$?
expect_code "uninstall: kod 0" "$code" 0 "$out"
[ ! -e "$WORK/Applications/CMCRDmgApp.app" ] && pass "uninstall: aplikacja usunięta" || fail "uninstall: nadal jest" "$out"
mkb "$WORK/in" CMCRNotApps
out="$(ctlpw _builder uninstall 1 "$WORK/Applications/../in/CMCRNotApps.app")"; code=$?
expect "uninstall: ścieżka z .. odrzucona" "$out" "Odmowa"
[ -e "$WORK/in/CMCRNotApps.app" ] && pass "uninstall: nic nie usunięto poza Applications" || fail "uninstall: usunięto plik spoza Applications"
out="$(ctlpw _builder uninstall 1 "$WORK/in/CMCRNotApps.app")"; code=$?
expect_code "uninstall: aplikacja spoza Applications – kod 2" "$code" 2 "$out"

section "Skrypty – wysyłanie plików (push)"
mkdir -p "$WORK/send/Lekcja/sub" "$WORK/remote/dest/Lekcja"
echo nowy > "$WORK/send/Lekcja/sub/a.txt"
echo nowa > "$WORK/send/b.txt"
echo stary > "$WORK/remote/dest/Lekcja/stary.txt"
echo stara > "$WORK/remote/dest/b.txt"
out="$(ctlpw _builder push 1 "$WORK/remote/dest" "" 644 "$WORK/send/Lekcja" "$WORK/send/b.txt" --root)"; code=$?
expect_code "push: kod 0" "$code" 0 "$out"
[ -f "$WORK/remote/dest/Lekcja/stary.txt" ] && [ -f "$WORK/remote/dest/Lekcja/sub/a.txt" ] \
  && pass "push: istniejący folder scalony" || fail "push: scalanie" "$(ls -laR "$WORK/remote/dest")"
[ "$(cat "$WORK/remote/dest/b.txt")" = nowa ] && pass "push: plik zastąpiony nową wersją" || fail "push: plik nie zastąpiony"
d="$(stat -f %Lp "$WORK/remote/dest/Lekcja/sub")"; f="$(stat -f %Lp "$WORK/remote/dest/Lekcja/sub/a.txt")"
[ "$d" = 755 ] && [ "$f" = 644 ] && pass "push: 644 → foldery 755, pliki 644 (foldery da się otworzyć)" || fail "push: uprawnienia 644 → $d/$f"
out="$(ctlpw _builder push 1 "$WORK/remote/dest700" "" 700 "$WORK/send/Lekcja" --root)"
d="$(stat -f %Lp "$WORK/remote/dest700/Lekcja/sub")"; f="$(stat -f %Lp "$WORK/remote/dest700/Lekcja/sub/a.txt")"
[ "$d" = 700 ] && [ "$f" = 600 ] && pass "push: 700 → foldery 700, pliki 600; nowy folder docelowy utworzony" || fail "push: uprawnienia 700 → $d/$f" "$out"
left="$(ls -A "$WORK/remote/dest" | grep -c '^\.cmcr-push')"
[ "$left" = 0 ] && pass "push: brak tymczasowego folderu w miejscu docelowym" || fail "push: pozostał .cmcr-push" "$(ls -A "$WORK/remote/dest")"

mkdir -p "$WORK/remote/Apps/CMCRZipApp.app/Contents/Stare"
echo stare > "$WORK/remote/Apps/CMCRZipApp.app/Contents/Stare/plik"
out="$(ctlpw _builder push 1 "$WORK/remote/Apps" "" "" "$WORK/zipsrc/CMCRZipApp.app" --root)"; code=$?
expect_code "push .app: kod 0" "$code" 0 "$out"
[ ! -e "$WORK/remote/Apps/CMCRZipApp.app/Contents/Stare" ] && [ -x "$WORK/remote/Apps/CMCRZipApp.app/Contents/MacOS/CMCRZipApp" ] \
  && pass "push .app: pakiet zastąpiony w całości (nie scalony)" || fail "push .app: scalony ze starą wersją" "$(find "$WORK/remote/Apps")"
if xattr -p com.apple.quarantine "$WORK/remote/Apps/CMCRZipApp.app" >/dev/null 2>&1; then
  fail "push .app: kwarantanna nie usunięta"
else pass "push .app: kwarantanna usunięta"; fi

out="$(ctlpw _builder push 1 "/Users/cmcr-e2e-brak-konta/Desktop" "" "" "$WORK/send/b.txt" --root)"; code=$?
expect "push: brak katalogu domowego – nie tworzy /Users/…" "$out" "nie istnieje"
expect_code "push: brak katalogu domowego – kod 2" "$code" 2 "$out"
[ ! -e "/Users/cmcr-e2e-brak-konta" ] && pass "push: /Users/cmcr-e2e-brak-konta nie powstał" || fail "push: utworzono katalog w /Users"
for p in "/users/cmcr-e2e-brak-konta/Desktop" "/USERS/cmcr-e2e-brak-konta/Desktop"; do
  out="$(ctlpw _builder push 1 "$p" "" "" "$WORK/send/b.txt" --root)"; code=$?
  expect_code "push: $p (inna wielkość liter) – kod 2" "$code" 2 "$out"
done
for v in /Volumes/*; do
  if [ "$(cd "$v" 2>/dev/null && /bin/pwd -P)" = / ]; then
    out="$(ctlpw _builder push 1 "$v/Users/cmcr-e2e-brak-konta/Desktop" "" "" "$WORK/send/b.txt" --root)"; code=$?
    expect_code "push: $v/Users/… (dysk startowy przez /Volumes) – kod 2" "$code" 2 "$out"
    break
  fi
done
[ ! -e "/Users/cmcr-e2e-brak-konta" ] && pass "push: warianty ścieżki nie utworzyły katalogu w /Users" || fail "push: utworzono katalog w /Users"
out="$(ctlpw _builder push 1 "Desktop" "" "" "$WORK/send/b.txt" --root)"; code=$?
expect "push: ścieżka względna odrzucona" "$out" "pełną ścieżką"
out="$(ctlpw _builder push 1 "$WORK/remote/dest" "" "777; rm -rf /" "$WORK/send/b.txt" --root)"; code=$?
expect "push: niepoprawne uprawnienia odrzucone" "$out" "Niepoprawne uprawnienia"
touch "$WORK/fake-no-console"
out="$(ctlpw _builder push 1 "$WORK/remote/{console}/Desktop" "" "" "$WORK/send/b.txt" --root)"; code=$?
expect "push {console}: nikt nie jest zalogowany – czytelny błąd" "$out" "Nikt nie jest zalogowany"
expect_code "push {console}: kod 3" "$code" 3 "$out"
[ ! -e "$WORK/remote/Desktop" ] && pass "push {console}: nic nie zapisano" || fail "push {console}: utworzono $WORK/remote/Desktop"
out="$(ctlpw _builder clean-folder 1 "/Users/{console}/Desktop" --dry-run)"; code=$?
expect_code "clean {console}: kod 3 bez zalogowanego użytkownika" "$code" 3 "$out"
out="$(ctlpw _builder message 1 "Tytuł" "Treść")"; code=$?
expect_code "message: kod 3 bez zalogowanego użytkownika" "$code" 3 "$out"
rm -f "$WORK/fake-no-console"

section "Skrypty – czyszczenie folderu (zabezpieczenia)"
mkdir -p "$WORK/clean/sub" && echo x > "$WORK/clean/sub/x" && echo y > "$WORK/clean/.ukryty"
out="$(ctlpw _builder clean-folder 1 "$WORK/clean")"; code=$?
expect_code "clean: kod 0" "$code" 0 "$out"
[ -d "$WORK/clean" ] && [ -z "$(ls -A "$WORK/clean")" ] && pass "clean: zawartość usunięta, folder pozostał" || fail "clean: zawartość" "$(ls -A "$WORK/clean")"
ln -s /Applications "$WORK/link-do-apps"
for p in "$WORK/link-do-apps" "/Users/$ME/.ssh" "/Users/$ME/Library" "/Users//Desktop" "/private/tmp" "/tmp" \
         "$WORK/clean/../clean" "/Applications" "/" "tmp/x" "/Users/$ME"; do
  case "$p" in */.ssh) [ -d "$p" ] || continue ;; esac
  out="$(ctlpw _builder clean-folder 1 "$p" --dry-run)"; code=$?
  if [ "$code" = 2 ] && contains "" "$out" "Odmowa"; then pass "clean: odmowa dla $p"; else fail "clean: brak odmowy dla $p (kod $code)" "$out"; fi
done
ME_UP="$(printf '%s' "$ME" | tr '[:lower:]' '[:upper:]')"
for p in "/Users/$ME/LIBRARY" "/Users/$ME/library/Caches" "/users/$ME/Desktop" "/Users/$ME_UP/Desktop" "/USERS/$ME/Documents"; do
  [ -d "$p" ] || continue
  out="$(ctlpw _builder clean-folder 1 "$p" --dry-run)"; code=$?
  if [ "$code" = 2 ] && contains "" "$out" "Odmowa"; then pass "clean: odmowa dla $p (inna wielkość liter)"; else fail "clean: brak odmowy dla $p (kod $code)" "$out"; fi
done
out="$(ctlpw exec 'cmcr_realdir "/Users/$USER/LIBRARY"; cmcr_realdir "/USERS"; cmcr_canonpath "/users/cmcr-e2e-brak/Desktop"; cmcr_canonpath "/tmp/cmcr-e2e-brak/x"' 1)"
expect "cmcr_realdir/cmcr_canonpath: pisownia z dysku" "$out" "/Users/$ME/Library" "
/Users
/Users/cmcr-e2e-brak/Desktop
/private/tmp/cmcr-e2e-brak/x"
for v in /Volumes/*; do
  if [ "$(cd "$v" 2>/dev/null && pwd -P)" = / ]; then
    out="$(ctlpw exec "cmcr_realdir '$v/Users'; cmcr_canonpath '$v/cmcr-e2e-brak/x'" 1)"
    expect "cmcr_realdir: $v/Users → /Users" "$out" "/Users
/cmcr-e2e-brak/x"
    out="$(ctlpw _builder clean-folder 1 "$v/Applications" --dry-run)"; code=$?
    if [ "$code" = 2 ] && contains "" "$out" "Odmowa"; then pass "clean: odmowa dla $v/Applications (dysk startowy)"; else fail "clean: $v/Applications" "$out"; fi
    break
  fi
done

section "Skrypty – klucz SSH (authorized_keys bez końcowego znaku nowej linii)"
mkdir -p "$WORK/home/.ssh"
printf 'ssh-ed25519 AAAAEXISTING teacher@old' > "$WORK/home/.ssh/authorized_keys"
AK="$WORK/home/.ssh/authorized_keys"
out="$(ctlpw _builder distribute-key 1 "ssh-ed25519 AAAANEWKEY cmcr-manager@mac" "$AK")"
expect "distribute-key: klucz dodany" "$out" "Klucz dodany"
lines="$(grep -c . "$AK")"
if [ "$lines" = 2 ] && grep -qx 'ssh-ed25519 AAAAEXISTING teacher@old' "$AK" && grep -qx 'ssh-ed25519 AAAANEWKEY cmcr-manager@mac' "$AK"; then
  pass "distribute-key: oba klucze w osobnych liniach"
else fail "distribute-key: plik uszkodzony" "$(cat -e "$AK")"; fi
out="$(ctlpw _builder distribute-key 1 "ssh-ed25519 AAAANEWKEY inny-komentarz" "$AK")"
expect "distribute-key: ten sam klucz z innym komentarzem nie jest dublowany" "$out" "już zainstalowany"
[ "$(grep -c . "$AK")" = 2 ] && pass "distribute-key: nadal 2 linie" || fail "distribute-key: duplikat" "$(cat "$AK")"
out="$(ctlpw _builder distribute-key 1 "to nie jest klucz" "$AK")"; code=$?
expect_code "distribute-key: odrzuca tekst, który nie jest kluczem" "$code" 2 "$out"

section "Skrypty – zamykanie aplikacji (polecenie „Zakończ”)"
mkb "$WORK" CMCRQuit pl.cmcr.e2e.quit
"$WORK/CMCRQuit.app/Contents/MacOS/CMCRQuit" 300 &
QPID=$!
sleep 0.5
clear_fakelog
out="$(ctlpw _builder quit-app 1 CMCRQuit --wait 1)"; code=$?
expect "quit: wysłano Apple Event „quit” w sesji użytkownika" "$(fakelog)" "gui-exec: /usr/bin/osascript" "tell application id b to quit" "pl.cmcr.e2e.quit"
expect "quit: polecenie z HOME użytkownika (sudo -H)" "$(fakelog)" "gui-sudo: -H -u $ME"
expect "quit: aplikacja, która nie zamknęła się sama, nie jest zabijana" "$out" "nadal działa"
expect_code "quit: kod 1, gdy aplikacja nadal działa" "$code" 1 "$out"
kill -0 "$QPID" 2>/dev/null && pass "quit: proces nadal działa (bez SIGTERM)" || fail "quit: proces zabity bez prośby"
touch "$WORK/fake-ae-denied"
out="$(ctlpw _builder quit-app 1 CMCRQuit --wait 1)"; code=$?
expect "quit: odmowa Apple Event (Automatyzacja) zgłoszona wprost" "$out" "nie pozwolił" "-1743" "Wymuś zamknięcie"
expect_not "quit: odmowa nie udaje czekania na ucznia" "$out" "pyta ucznia"
expect_code "quit: odmowa Apple Event – kod 1" "$code" 1 "$out"
kill -0 "$QPID" 2>/dev/null && pass "quit: po odmowie proces nietknięty" || fail "quit: proces zabity po odmowie"
rm -f "$WORK/fake-ae-denied"
out="$(ctlpw _builder quit-app 1 CMCRQuit --wait 1 --term)"; code=$?
sleep 0.3
if kill -0 "$QPID" 2>/dev/null; then fail "quit --term: proces nadal działa" "$out"; kill "$QPID"; else pass "quit --term: SIGTERM na życzenie"; fi
expect_code "quit --term: kod 0" "$code" 0 "$out"
"$WORK/CMCRQuit.app/Contents/MacOS/CMCRQuit" 300 &
QPID=$!
sleep 0.5
out="$(ctlpw _builder quit-app 1 CMCRQuit --force)"
sleep 0.3
if kill -0 "$QPID" 2>/dev/null; then fail "quit --force: proces nadal działa" "$out"; kill "$QPID"; else pass "quit --force: SIGKILL"; fi
wait "$QPID" 2>/dev/null

section "Skrypty – sesja użytkownika"
clear_fakelog
out="$(ctlpw _builder logout 1 --wait 1)"; code=$?
sleep 0.3
expect "logout: prośba do loginwindow (aplikacje mogą zapisać zmiany)" "$(fakelog)" "gui-exec: /usr/bin/osascript" "aevtrlgo"
expect_not "logout: bez twardego launchctl bootout" "$(fakelog)" "bootout"
expect "logout: uczciwy wynik, gdy sesja trwa" "$out" "nadal zalogowany"
touch "$WORK/fake-ae-denied"
out="$(ctlpw _builder logout 1 --wait 5)"; code=$?
expect "logout: odmowa Apple Event zgłoszona wprost" "$out" "nie pozwolił poprosić o wylogowanie" "Wyloguj natychmiast"
expect_code "logout: odmowa – kod 1" "$code" 1 "$out"
rm -f "$WORK/fake-ae-denied"
clear_fakelog
out="$(ctlpw _builder message 1 "Uwaga" "Koniec lekcji")"
expect "message: okno wysunięte na wierzch (activate)" "$(fakelog)" "gui-stdin: activate" "display dialog \"Koniec lekcji\""
clear_fakelog
out="$(ctlpw _builder launch-app 1 "Kalkulator Test" '-projectPath "/Users/student/Moja gra" $(id)')"
expect "launch-app: argumenty dosłownie, nowa instancja" "$(fakelog)" "open -n -a Kalkulator Test --args -projectPath /Users/student/Moja gra \$(id)"

section "Skrypty – zasilanie i FileVault"
clear_fakelog
out="$(ctlpw _builder power 1 restart)"; code=$?
expect_code "restart: kod 0" "$code" 0 "$out"
sleep 2.6
expect "restart bez FileVault: shutdown -r now" "$(fakelog)" "shutdown -r now"
touch "$WORK/fake-filevault"
clear_fakelog
out="$(ctlpw _builder power 1 restart)"
expect "restart z FileVault: fdesetup authrestart" "$out" "jednorazowo odblokowany" "fdesetup authrestart"
expect_not "restart z FileVault: bez ostrzeżenia o ekranie odblokowania" "$out" "ekranie odblokowania"
sleep 2.6
log_fv="$(fakelog)"
expect "restart z FileVault: odblokowanie uzbrojone przed restartem (hasło w plist na stdin)" "$log_fv" \
  "fdesetup authrestart -delayminutes -1 -inputplist password ok" "shutdown -r now"
fv_order="$(printf '%s\n' "$log_fv" | grep -n -e "fdesetup authrestart" -e "shutdown -r now" | cut -d: -f2- | tr '\n' '|')"
case "$fv_order" in "fdesetup authrestart"*"|shutdown -r now|") pass "restart z FileVault: odblokowanie przed restartem" ;;
  *) fail "restart z FileVault: kolejność odblokowania i restartu" "$log_fv" ;; esac
touch "$WORK/fake-fde-refuse"
clear_fakelog
out="$(ctlpw _builder power 1 restart)"
expect "restart z FileVault: odmowa authrestart zgłoszona" "$out" "fdesetup authrestart odmówił" "Unable to restart" "ekranie odblokowania"
sleep 2.6
expect "restart z FileVault po odmowie: zwykły restart" "$(fakelog)" "shutdown -r now"
rm -f "$WORK/fake-filevault" "$WORK/fake-fde-refuse"; touch "$WORK/fake-filevault-nouser"
clear_fakelog
out="$(ctlpw _builder power 1 restart)"
expect "restart z FileVault bez uprawnień do odblokowania: ostrzeżenie" "$out" "ekranie odblokowania"
sleep 2.6
expect "restart z FileVault bez uprawnień: zwykły restart" "$(fakelog)" "shutdown -r now"
rm -f "$WORK/fake-filevault-nouser"

section "Skrypty – aktualizacje macOS"
clear_fakelog
out="$(ctlpw _builder install-updates 1)"; code=$?
expect_code "softwareupdate: kod 0" "$code" 0 "$out"
expect "softwareupdate: instaluje wybrane etykiety" "$(fakelog)" "softwareupdate --install Safari99.1-99.1 --agree-to-license"
expect_not "softwareupdate: bez przejścia na nową wersję macOS" "$(fakelog)" "--install macOS Testowy"
expect "softwareupdate: informuje o pominiętej wersji" "$out" "Pominięto przejście na nową wersję systemu: macOS Testowy 99.1"
if [ "$(uname -m)" = arm64 ]; then
  expect_not "softwareupdate: bez ostrzeżenia, gdy konto jest właścicielem woluminu" "$out" "właścicielem woluminu"
  touch "$WORK/fake-no-volume-owner"
  out="$(ctlpw _builder install-updates 1)"
  expect "softwareupdate: ostrzeżenie o braku Secure Token (właściciela woluminu)" "$out" "nie jest właścicielem woluminu"
  rm -f "$WORK/fake-no-volume-owner"
fi
clear_fakelog
out="$(ctlpw _builder install-updates 1 --major --restart)"
expect "softwareupdate --major: także nowa wersja macOS i restart" "$(fakelog)" "macOS Testowy 99.1-99A123" "--restart"
expect_not "softwareupdate z restartem bez FileVault: nic nie uzbrojono" "$(fakelog)" "fdesetup authrestart"

# FileVault: an update that restarts the Mac arms the one-time unlock first – and only then.
touch "$WORK/fake-filevault"
clear_fakelog
out="$(ctlpw _builder install-updates 1 --major --restart)"; code=$?
expect_code "softwareupdate z restartem i FileVault: kod 0" "$code" 0 "$out"
expect "softwareupdate z restartem i FileVault: odblokowanie uzbrojone" "$(fakelog)" \
  "fdesetup authrestart -delayminutes -1 -inputplist password ok"
expect "softwareupdate z restartem i FileVault: komunikat" "$out" "jednorazowo odblokowany przy restarcie po aktualizacji"
su_order="$(grep -e "fdesetup authrestart" -e "softwareupdate --install" "$WORK/fake.log" | cut -c1-20 | tr '\n' '|')"
case "$su_order" in "fdesetup authrestart|softwareupdate --ins|"*) pass "softwareupdate z FileVault: odblokowanie przed instalacją z restartem" ;;
  *) fail "softwareupdate z FileVault: kolejność ($su_order)" "$(fakelog)" ;; esac
clear_fakelog
out="$(ctlpw _builder install-updates 1 --restart)"
expect "softwareupdate bez aktualizacji wymagającej restartu: instalacja" "$(fakelog)" "softwareupdate --install Safari99.1-99.1"
expect_not "softwareupdate bez aktualizacji wymagającej restartu: nic nie uzbrojono" "$(fakelog)" "fdesetup authrestart"
clear_fakelog
out="$(ctlpw _builder install-updates 1 --major)"
expect_not "softwareupdate bez --restart: nic nie uzbrojono" "$(fakelog)" "fdesetup authrestart"
clear_fakelog
out="$(ctlpw _builder install-updates 1 --major --restart --download)"
expect_not "softwareupdate --download: nic nie uzbrojono" "$(fakelog)" "fdesetup authrestart"
touch "$WORK/fake-fde-refuse"
out="$(ctlpw _builder install-updates 1 --major --restart)"
expect "softwareupdate z FileVault: odmowa authrestart zgłoszona" "$out" "fdesetup authrestart odmówił" "ekranie odblokowania"
rm -f "$WORK/fake-filevault" "$WORK/fake-fde-refuse"
clear_fakelog
out="$(ctlpw _builder install-updates 1 --download)"
expect "softwareupdate --download: tylko pobieranie" "$(fakelog)" "softwareupdate --download Safari99.1-99.1"
expect_not "softwareupdate --download: bez licencji/instalacji" "$(fakelog)" "--agree-to-license"

section "Skrypty – stan i inwentaryzacja"
out="$(ctlpw _builder status 1)"
expect "status: rozszerzone pola" "$out" "serial=" "lhn=" "macs=" "mac_ethernet=" "filevault=off" "sip=" "fda=" "womp=1" "load="
expect_not "status: bez sudo -n przy zwykłym odświeżaniu" "$out" "sudo_nopass"
out="$(ctlpw _builder status 1 --sudo)"
expect "status --sudo: sprawdzenie sudo na żądanie" "$out" "sudo_nopass=no"

section "Skrypty – polskie locale przekazane przez ssh (SendEnv LANG LC_*)"
# cmcrctl started from a Polish Terminal: macOS ssh forwards LANG/LC_*, the test sshd accepts them like macOS.
out="$(LANG=pl_PL.UTF-8 LC_ALL=pl_PL.UTF-8 ctl exec 'echo "LANG=$LANG LC_ALL=$LC_ALL"; date -j -f %Y-%m-%d 2026-10-03 +%a; echo "zażółć gęślą jaźń"' 1)"
expect "locale: LANG z terminala dotarł do iMaca" "$out" "LANG=pl_PL.UTF-8"
expect "locale: skrypty działają w stałym locale C (angielskie daty), polski tekst bez zmian" "$out" "LC_ALL=C" "Sat" "zażółć gęślą jaźń"
out="$(LANG=pl_PL.UTF-8 LC_ALL=pl_PL.UTF-8 ctlpw _builder status 1)"
load="$(printf '%s\n' "$out" | grep '^load=')"
[ -n "$load" ] && pass "locale: status podaje obciążenie" || fail "locale: brak load=" "$out"
expect_not "locale: obciążenie z kropką dziesiętną, nie z przecinkiem" "$load" ","
login="$(printf '%s\n' "$out" | grep '^last_login=')"
case "$login" in
  "") pass "locale: brak logowania przy konsoli w historii – pominięto datę" ;;
  last_login=[0-9][0-9][0-9][0-9]-0[1-9]-[0-3][0-9]\ *|last_login=[0-9][0-9][0-9][0-9]-1[0-2]-[0-3][0-9]\ *)
    pass "locale: data ostatniego logowania z poprawnym miesiącem ($login)" ;;
  *) fail "locale: zła data ostatniego logowania ($login)" "$out" ;;
esac

section "Skrypty – folder wspólny ucznia"
out="$(ctlpw _builder prepare-shared 1 "$WORK/shared/cmcr" "$ME")"; code=$?
expect_code "prepare-shared: kod 0" "$code" 0 "$out"
[ "$(stat -f %Lp "$WORK/shared/cmcr" 2>/dev/null)" = 777 ] && pass "prepare-shared: folder 777" || fail "prepare-shared: uprawnienia" "$out"
out="$(ctlpw _builder prepare-shared 1 "/Users/cmcr-e2e-brak/Public/cmcr" "$ME")"; code=$?
expect_code "prepare-shared: brak katalogu w /Users – kod 2" "$code" 2 "$out"
out="$(ctlpw _builder prepare-shared 1 "/users/cmcr-e2e-brak/Public/cmcr" "$ME")"; code=$?
expect_code "prepare-shared: /users (inna wielkość liter) – kod 2" "$code" 2 "$out"
[ ! -e "/Users/cmcr-e2e-brak" ] && pass "prepare-shared: nie utworzono /Users/cmcr-e2e-brak" || fail "prepare-shared: utworzono /Users/cmcr-e2e-brak"
out="$(ctlpw _builder prepare-shared 1 "$WORK/shared/x" "cmcr-e2e-brak-konta")"; code=$?
expect "prepare-shared: nieistniejące konto" "$out" "nie istnieje"
fi
