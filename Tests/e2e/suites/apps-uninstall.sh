# Installed applications and uninstalling them (Scripts+Apps.swift): `cmcrctl apps installed`, `cmcrctl uninstall`
# with the dry run, launch daemons and agents, package receipts and files, the student's ~/Applications, Unity editors
# and the safeguards. Sourced by Tests/e2e/run.sh (helpers: section, pass, fail, expect, expect_not, expect_code, ctl,
# ctlpw, fakelog…). Everything lives in $WORK: the test sshd sets CMCR_APPS_DIR ($WORK/Applications), fakes.sh sets
# CMCR_USERS_DIR ($WORK/Users) and CMCR_FS_PREFIX ($WORK/fsroot) and fakes pkgutil and profiles.

AP_APPS="$WORK/Applications"
AP_HOME="$WORK/Users/$ME"
AP_FS="$WORK/fsroot"
AP_RC="$WORK/receipts"
mkdir -p "$AP_APPS/Utilities" "$AP_HOME/Applications" "$AP_HOME/Library/LaunchAgents" "$AP_FS/Library/LaunchDaemons" \
  "$AP_FS/Library/LaunchAgents" "$AP_FS/Library/PrivilegedHelperTools" "$AP_RC"

ap_mkapp() { # ap_mkapp FOLDER NAME BUNDLE-ID [VERSION] [EXTRA-PLIST-XML] – a bundle signed ad hoc that runs a copy of /bin/sleep
  local a="$1/$2.app"
  mkdir -p "$a/Contents/MacOS"
  cat > "$a/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$3</string>
<key>CFBundleShortVersionString</key><string>${4:-1.0}</string>
<key>CFBundleExecutable</key><string>$2</string>
${5:-}
</dict></plist>
EOF
  cp /bin/sleep "$a/Contents/MacOS/$2"
  mkdir -p "$a/Contents/Resources"
  dd if=/dev/zero of="$a/Contents/Resources/dane.bin" bs=1024 count=64 2>/dev/null
  # Signed again (ad hoc): a copy of /bin/sleep keeps Apple's signature, which the uninstaller refuses.
  codesign --force --sign - "$a/Contents/MacOS/$2" >/dev/null 2>&1
  codesign --force --sign - "$a" >/dev/null 2>&1
}
ap_plist() { # ap_plist FILE LABEL PROGRAM
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$2</string><key>Program</key><string>$3</string></dict></plist>
EOF
}
ap_start() { ( "$1" 300 >/dev/null 2>&1 & echo $! ); }
ap_json() { # ap_json JSON PYTHON-EXPRESSION – prints the expression over the parsed `apps installed --json`
  printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); apps={a['name']: a for a in d[0].get('apps', [])}; print($2)" 2>&1
}

# The calculator comes from a package (installed to /) that also put a launch daemon with its helper and data files in
# /Library; a second package shares one of those files.
# Its helper is one the bundle declares (SMPrivilegedExecutables): only such a helper goes with the app.
ap_mkapp "$AP_APPS" "Kalkulator Testowy" pl.test.kalk 1.2.3 \
  '<key>SMPrivilegedExecutables</key><dict><key>pl.test.kalk.helper</key><string>anchor apple generic</string></dict>'
ap_plist "$AP_FS/Library/LaunchDaemons/pl.test.kalk.helper.plist" pl.test.kalk.helper "$AP_FS/Library/PrivilegedHelperTools/pl.test.kalk.helper"
printf '#!/bin/sh\n' > "$AP_FS/Library/PrivilegedHelperTools/pl.test.kalk.helper"
mkdir -p "$AP_FS/Library/Application Support/KalkTest/sub"
echo dane > "$AP_FS/Library/Application Support/KalkTest/sub/dane.txt"
echo wspolny > "$AP_FS/Library/Application Support/KalkTest/wspolny.txt"
mkdir -p "$AP_RC/pl.test.kalk.pkg" "$AP_RC/pl.test.wspolny.pkg"
printf 'version: 1.2.3\nlocation: /\ninstall-time: 1767225600\n' > "$AP_RC/pl.test.kalk.pkg/info"
R="${WORK#/}"
printf '%s\n' "$R/Applications/Kalkulator Testowy.app/Contents/Info.plist" \
  "$R/Applications/Kalkulator Testowy.app/Contents/MacOS/Kalkulator Testowy" \
  "$R/fsroot/Library/LaunchDaemons/pl.test.kalk.helper.plist" \
  "$R/fsroot/Library/PrivilegedHelperTools/pl.test.kalk.helper" \
  "$R/fsroot/Library/Application Support/KalkTest/sub/dane.txt" \
  "$R/fsroot/Library/Application Support/KalkTest/wspolny.txt" > "$AP_RC/pl.test.kalk.pkg/files"
printf '%s\n' "$R/Applications" "$R/Applications/Kalkulator Testowy.app" "$R/Applications/Kalkulator Testowy.app/Contents" \
  "$R/fsroot/Library" "$R/fsroot/Library/Application Support" "$R/fsroot/Library/Application Support/KalkTest" \
  "$R/fsroot/Library/Application Support/KalkTest/sub" > "$AP_RC/pl.test.kalk.pkg/dirs"
printf 'version: 2.0\nlocation: /\ninstall-time: 1767225600\n' > "$AP_RC/pl.test.wspolny.pkg/info"
printf '%s\n' "$R/fsroot/Library/Application Support/KalkTest/wspolny.txt" > "$AP_RC/pl.test.wspolny.pkg/files"
: > "$AP_RC/pl.test.wspolny.pkg/dirs"

ap_mkapp "$AP_APPS/Utilities" "Narzedzie Testowe" pl.test.narzedzie 3.0
mkdir -p "$AP_APPS/Firma Testowa"
ap_mkapp "$AP_APPS/Firma Testowa" "Program Firmy" pl.test.firma 5.1
ap_mkapp "$AP_APPS/Firma Testowa" "Uninstall Program Firmy" pl.test.firma.uninstaller 5.1
mkdir -p "$AP_APPS/Jedyny Folder"
ap_mkapp "$AP_APPS/Jedyny Folder" "Jedyna" pl.test.jedyna 1.0
ap_mkapp "$AP_HOME/Applications" "Gra Ucznia" pl.test.gra 0.9
ap_plist "$AP_HOME/Library/LaunchAgents/pl.test.gra.agent.plist" pl.test.gra.agent "$AP_HOME/Applications/Gra Ucznia.app/Contents/MacOS/Gra Ucznia"
ap_mkapp "$AP_APPS" "Apple Testowa" com.apple.cmcr-e2e 1.0
ap_mkapp "$AP_APPS" "Skladnik CMCR" pl.cmcr.e2e 1.0
ap_mkapp "$AP_APPS" "Ze Sklepu" pl.test.sklep 2.2
mkdir -p "$AP_APPS/Ze Sklepu.app/Contents/_MASReceipt" && echo r > "$AP_APPS/Ze Sklepu.app/Contents/_MASReceipt/receipt"
mkdir -p "$AP_APPS/Unity/Hub/Editor/6000.9.1f1/PlaybackEngines/AndroidPlayer" "$AP_APPS/Unity/Hub/Editor/6000.8.2f1"
ap_mkapp "$AP_APPS/Unity/Hub/Editor/6000.9.1f1" Unity com.unity3d.UnityEditor5.x 6000.9.1f1
ap_mkapp "$AP_APPS/Unity/Hub/Editor/6000.8.2f1" Unity com.unity3d.UnityEditor5.x 6000.8.2f1
echo modul > "$AP_APPS/Unity/Hub/Editor/6000.9.1f1/PlaybackEngines/AndroidPlayer/modul.txt"

section "Zainstalowane aplikacje (apps installed)"
out="$(ctl apps installed 1 --json)"; code=$?
expect_code "apps installed --json: kod 0" "$code" 0 "$out"
expect "apps installed: wersja i identyfikator" "$(ap_json "$out" "apps['Kalkulator Testowy']['version'], apps['Kalkulator Testowy']['bundleID'], apps['Kalkulator Testowy']['location']")" \
  "1.2.3" "pl.test.kalk" "apps"
expect "apps installed: pakiet, z którego pochodzi aplikacja" "$(ap_json "$out" "apps['Kalkulator Testowy']['receipts']")" "pl.test.kalk.pkg"
expect "apps installed: rozmiar" "$(ap_json "$out" "apps['Kalkulator Testowy'].get('sizeKB', 0) > 0")" "True"
expect "apps installed: Utilities, folder producenta i folder ucznia" \
  "$(ap_json "$out" "apps['Narzedzie Testowe']['location'], apps['Program Firmy']['location'], apps['Gra Ucznia']['location']")" \
  "utilities" "folder" "user:$ME"
expect "apps installed: edytory Unity jako wersje" "$(ap_json "$out" "apps['Unity 6000.9.1f1']['kind'], apps['Unity 6000.8.2f1']['removable']")" \
  "unity" "True"
expect "apps installed: Apple, CMCR i App Store rozpoznane" \
  "$(ap_json "$out" "apps['Apple Testowa']['kind'], apps['Apple Testowa']['removable'], apps['Skladnik CMCR']['kind'], apps['Skladnik CMCR']['removable'], apps['Ze Sklepu']['kind']")" \
  "apple" "False" "cmcr" "appstore"
expect "apps installed: aplikacje macOS ukryte bez --system" "$(ap_json "$out" "any(a['kind'] == 'system' for a in apps.values())")" "False"
out="$(ctl apps installed 1 --system --receipts)"; code=$?
expect_code "apps installed: kod 0" "$code" 0 "$out"
expect "apps installed: tabela z wersją, identyfikatorem i ścieżką" "$out" "Kalkulator Testowy" "1.2.3" "pl.test.kalk" \
  "$AP_APPS/Kalkulator Testowy.app" "[Apple, nie do odinstalowania]"
expect "apps installed --system: aplikacje macOS" "$out" "/System/Applications/" "[systemowa, nie do odinstalowania]"
expect "apps installed --receipts: pakiety spoza Apple" "$out" "Pakiety instalacyjne spoza Apple (pkgutil): 2" "pl.test.kalk.pkg"
expect_not "apps installed: nic nie usuwa" "$(fakelog)" "--forget"

section "Odinstalowanie – podgląd (--dry-run)"
AP_PID="$(ap_start "$AP_APPS/Kalkulator Testowy.app/Contents/MacOS/Kalkulator Testowy")"
sleep 0.3
clear_fakelog
out="$(ctlpw uninstall "Kalkulator Testowy" 1 --dry-run)"; code=$?
expect_code "dry-run: kod 0" "$code" 0 "$out"
expect "dry-run: aplikacja, usługa, program pomocniczy i pakiet" "$out" \
  "Do usunięcia – aplikację: $AP_APPS/Kalkulator Testowy.app" \
  "usługę systemową (LaunchDaemon) pl.test.kalk.helper" \
  "program pomocniczy: $AP_FS/Library/PrivilegedHelperTools/pl.test.kalk.helper" \
  "Do wyrejestrowania – pakiet pl.test.kalk.pkg"
expect "dry-run: uruchomiona aplikacja zostanie zamknięta" "$out" "Aplikacja jest uruchomiona – konto: $ME"
expect "dry-run: pliki pakietu zostają bez --with-package-files" "$out" "Zostaje 2 pliki pakietu poza aplikacją" "--with-package-files"
expect "dry-run: podsumowanie" "$out" "Podgląd: do usunięcia" "nic jeszcze nie zmieniono"
expect_not "dry-run: bez błędów basha (składnia)" "$out" "syntax error"
expect_not "dry-run: bez błędów basha (polecenia)" "$out" "command not found"
[ -d "$AP_APPS/Kalkulator Testowy.app" ] && [ -f "$AP_FS/Library/LaunchDaemons/pl.test.kalk.helper.plist" ] && [ -d "$AP_RC/pl.test.kalk.pkg" ] \
  && pass "dry-run: nic nie zostało usunięte" || fail "dry-run: coś usunięto" "$out"
kill -0 "$AP_PID" 2>/dev/null && pass "dry-run: aplikacja dalej działa" || fail "dry-run: aplikację zamknięto"
expect_not "dry-run: bez bootout i --forget" "$(fakelog)" "bootout"
out="$(ctlpw uninstall "Kalkulator Testowy" 1 --dry-run --with-package-files)"
expect "dry-run --with-package-files: plik tylko tego pakietu" "$out" "Do usunięcia – plik pakietu: $AP_FS/Library/Application Support/KalkTest/sub/dane.txt"
expect "dry-run --with-package-files: wspólny plik zostaje" "$out" "KalkTest/wspolny.txt – należy też do innego pakietu"
expect_not "actions.log: podgląd bez wpisu" "$(cat "$WORK/config/actions.log" 2>/dev/null)" "uninstall"

section "Odinstalowanie – aplikacja z pakietu, usługą i plikami"
out="$(ctlpw uninstall "Kalkulator Testowy" 1 </dev/null)"; code=$?
expect_code "uninstall: bez --yes poza terminalem – kod 2" "$code" 2 "$out"
[ -d "$AP_APPS/Kalkulator Testowy.app" ] && pass "uninstall: bez potwierdzenia nic nie usunięto" || fail "uninstall: usunięto bez potwierdzenia"
clear_fakelog
out="$(ctlpw uninstall "Kalkulator Testowy" 1 --with-package-files --yes)"; code=$?
expect_code "uninstall: kod 0" "$code" 0 "$out"
[ ! -e "$AP_APPS/Kalkulator Testowy.app" ] && pass "uninstall: aplikacja usunięta" || fail "uninstall: aplikacja nadal jest" "$out"
sleep 0.3
if kill -0 "$AP_PID" 2>/dev/null; then fail "uninstall: aplikacja nadal działa" "$out"; kill "$AP_PID" 2>/dev/null
else pass "uninstall: uruchomiona aplikacja zamknięta"; fi
expect_not "uninstall: bez błędów basha" "$out" "syntax error"
expect "uninstall: raport" "$out" "Zamknięto uruchomioną aplikację" "Usunięto aplikację: $AP_APPS/Kalkulator Testowy.app" \
  "Usunięto usługę systemową (LaunchDaemon) pl.test.kalk.helper" "Wyrejestrowano pakiet pl.test.kalk.pkg" "Wynik: usunięto"
expect "uninstall: usługa zatrzymana przed usunięciem" "$(fakelog)" "launchctl bootout system $AP_FS/Library/LaunchDaemons/pl.test.kalk.helper.plist"
expect "uninstall: pkgutil --forget" "$(fakelog)" "pkgutil --forget pl.test.kalk.pkg"
[ ! -e "$AP_FS/Library/LaunchDaemons/pl.test.kalk.helper.plist" ] && [ ! -e "$AP_FS/Library/PrivilegedHelperTools/pl.test.kalk.helper" ] \
  && pass "uninstall: plik usługi i program pomocniczy usunięte" || fail "uninstall: usługa została" "$out"
[ ! -e "$AP_FS/Library/Application Support/KalkTest/sub" ] && pass "uninstall: plik pakietu i pusty folder usunięte" \
  || fail "uninstall: plik pakietu został" "$(ls -R "$AP_FS/Library/Application Support/KalkTest")"
[ -f "$AP_FS/Library/Application Support/KalkTest/wspolny.txt" ] && pass "uninstall: plik innego pakietu został" || fail "uninstall: usunięto wspólny plik"
[ ! -d "$AP_RC/pl.test.kalk.pkg" ] && [ -d "$AP_RC/pl.test.wspolny.pkg" ] && pass "uninstall: wyrejestrowano tylko pakiet aplikacji" \
  || fail "uninstall: pakiety" "$(ls "$AP_RC")"
expect "actions.log: odinstalowanie zapisane" "$(cat "$WORK/config/actions.log" 2>/dev/null)" "cmcrctl uninstall 'Kalkulator Testowy' 1 --with-package-files --yes → imac01"
[ -z "$(ls -A "$AP_APPS" | grep cmcr-uninstall)" ] && pass "uninstall: brak pozostałości .cmcr-uninstall" || fail "uninstall: pozostałości" "$(ls -A "$AP_APPS")"

section "Odinstalowanie – folder Aplikacje ucznia, foldery producentów, Unity"
clear_fakelog
# {student} becomes the account from the settings; the real /Users is not an allowed folder in this test.
out="$(ctlpw uninstall "/Users/{student}/Applications/Gra Ucznia.app" 1 --yes)"
expect "uninstall {student}: konto ucznia wstawione do ścieżki" "$out" "/Users/$ME/Applications/Gra Ucznia.app" "Odinstalowywać można tylko"
# The owner (and, as after "Switch User", another account) have a GUI session: the agent is touched only in the owner's.
ME_UID="$(id -u)"; OTHER_UID=$((ME_UID + 4000))
printf '%s %s\n%s inny\n' "$ME_UID" "$ME" "$OTHER_UID" > "$WORK/ps.sessions"
out="$(ctlpw uninstall "Gra Ucznia" 1 --dry-run)"
expect "uninstall --dry-run: usługa ucznia z domeną" "$out" "gui/$ME_UID"
expect_not "uninstall --dry-run: bez cudzej domeny" "$out" "gui/$OTHER_UID"
clear_fakelog
out="$(ctlpw uninstall "Gra Ucznia" 1 --yes)"; code=$?
expect_code "uninstall: aplikacja ucznia – kod 0" "$code" 0 "$out"
expect "uninstall: agent ucznia zatrzymany w domenie właściciela" "$(fakelog)" "launchctl bootout gui/$ME_UID $AP_HOME/Library/LaunchAgents/pl.test.gra.agent.plist"
expect_not "uninstall: agent ucznia nie ruszony w cudzej domenie" "$(fakelog)" "gui/$OTHER_UID"
rm -f "$WORK/ps.sessions"
[ ! -e "$AP_HOME/Applications/Gra Ucznia.app" ] && [ ! -e "$AP_HOME/Library/LaunchAgents/pl.test.gra.agent.plist" ] \
  && pass "uninstall: aplikacja ucznia i jej agent usunięte" || fail "uninstall: aplikacja ucznia została" "$out"
expect "uninstall: agent konta zatrzymany" "$(fakelog)" "launchctl bootout gui/"

section "Odinstalowanie – agent ucznia nie wychodzi poza domenę właściciela (cross-user)"
# Evil.app in the student's ~/Applications with an agent; a second account has a GUI session too; the removal fails
# (a read-only folder with a file in the bundle). The agent may be stopped and started again only in the owner's domain.
ap_mkapp "$AP_HOME/Applications" "Evil" pl.test.evil 1.0
ap_plist "$AP_HOME/Library/LaunchAgents/pl.test.evil.agent.plist" pl.test.evil.agent "$AP_HOME/Applications/Evil.app/Contents/MacOS/Evil"
ap_plist "$AP_HOME/Library/LaunchAgents/com.vendor.cudzy.plist" com.vendor.cudzy "$AP_HOME/Applications/Evil.app/Contents/MacOS/Evil"
mkdir -p "$AP_HOME/Applications/Evil.app/Contents/Zablokowany"; echo x > "$AP_HOME/Applications/Evil.app/Contents/Zablokowany/plik"
chflags uchg "$AP_HOME/Applications/Evil.app/Contents/Zablokowany/plik" 2>/dev/null
chmod 500 "$AP_HOME/Applications/Evil.app/Contents/Zablokowany"
printf '%s %s\n%s inny\n' "$ME_UID" "$ME" "$OTHER_UID" > "$WORK/ps.sessions"
clear_fakelog
out="$(ctlpw uninstall "$AP_HOME/Applications/Evil.app" 1 --yes)"; code=$?
expect_code "cross-user: nieudane usunięcie – kod 1" "$code" 1 "$out"
[ -d "$AP_HOME/Applications/Evil.app" ] && pass "cross-user: aplikacja wróciła na miejsce" || fail "cross-user: aplikacji nie ma" "$out"
expect "cross-user: bootout w domenie właściciela" "$(fakelog)" "launchctl bootout gui/$ME_UID $AP_HOME/Library/LaunchAgents/pl.test.evil.agent.plist"
expect "cross-user: ponowne uruchomienie w domenie właściciela" "$(fakelog)" "launchctl bootstrap gui/$ME_UID $AP_HOME/Library/LaunchAgents/pl.test.evil.agent.plist"
expect_not "cross-user: żadnej akcji w cudzej domenie" "$(fakelog)" "gui/$OTHER_UID"
expect_not "cross-user: cudza etykieta nie zatrzymana" "$(fakelog)" "com.vendor.cudzy"
rm -f "$WORK/ps.sessions"
chmod -R u+w "$AP_HOME/Applications/Evil.app" 2>/dev/null
chflags -R nouchg "$AP_HOME/Applications/Evil.app" 2>/dev/null
# uchg alone no longer stops the removal.
ap_mkapp "$AP_HOME/Applications" "Zamek" pl.test.zamek 1.0
echo x > "$AP_HOME/Applications/Zamek.app/Contents/Resources/zamek.txt"; chflags uchg "$AP_HOME/Applications/Zamek.app/Contents/Resources/zamek.txt" 2>/dev/null
out="$(ctlpw uninstall "$AP_HOME/Applications/Zamek.app" 1 --yes)"; code=$?
expect_code "uchg: kod 0" "$code" 0 "$out"
[ ! -e "$AP_HOME/Applications/Zamek.app" ] && pass "uchg: aplikacja z zablokowanym plikiem usunięta" || fail "uchg: aplikacja została" "$out"
rm -rf "$AP_HOME/Applications/Evil.app" "$AP_HOME/Library/LaunchAgents/pl.test.evil.agent.plist" "$AP_HOME/Library/LaunchAgents/com.vendor.cudzy.plist"
clear_fakelog

out="$(ctlpw uninstall "Program Firmy" 1 --dry-run)"
expect "uninstall: deinstalator producenta wskazany" "$out" "deinstalator producenta" "Uninstall Program Firmy.app"
out="$(ctlpw uninstall "$AP_APPS/Jedyny Folder/Jedyna.app" 1 --yes)"; code=$?
expect_code "uninstall: aplikacja w folderze – kod 0" "$code" 0 "$out"
[ ! -e "$AP_APPS/Jedyny Folder" ] && pass "uninstall: pusty folder producenta usunięty" || fail "uninstall: folder został" "$out"
out="$(ctlpw uninstall "$AP_APPS/Unity/Hub/Editor/6000.9.1f1/Unity.app" 1 --dry-run)"
expect "Unity: cała wersja z modułami" "$out" "edytor Unity (z modułami): $AP_APPS/Unity/Hub/Editor/6000.9.1f1" "Unity Hub"
out="$(ctlpw uninstall "$AP_APPS/Unity/Hub/Editor/6000.9.1f1/Unity.app" 1 --yes)"; code=$?
expect_code "Unity: kod 0" "$code" 0 "$out"
[ ! -e "$AP_APPS/Unity/Hub/Editor/6000.9.1f1" ] && [ -d "$AP_APPS/Unity/Hub/Editor/6000.8.2f1" ] \
  && pass "Unity: usunięta tylko ta wersja" || fail "Unity: wersje" "$(ls "$AP_APPS/Unity/Hub/Editor")"
out="$(ctlpw uninstall "$AP_APPS/Unity/Hub/Editor/6000.8.2f1/PlaybackEngines" 1 --yes)"; code=$?
expect "Unity: część wersji odrzucona" "$out" "całe wersje"
expect_code "Unity: część wersji – kod 1" "$code" 1 "$out"

section "Odinstalowanie – zabezpieczenia"
for name in "Apple Testowa" "Skladnik CMCR"; do
  out="$(ctlpw uninstall "$name" 1 --yes)"; code=$?
  expect_code "odmowa: $name – kod 1" "$code" 1 "$out"
  [ -d "$AP_APPS/$name.app" ] && pass "odmowa: $name nie została usunięta" || fail "odmowa: $name usunięta" "$out"
done
expect "odmowa: aplikacja Apple" "$(ctlpw uninstall "Apple Testowa" 1 --yes)" "Odmowa:" "aplikacja Apple (com.apple.cmcr-e2e)"
expect "odmowa: składnik CMCR" "$(ctlpw uninstall "Skladnik CMCR" 1 --yes)" "składnik CMCR"
out="$(ctlpw uninstall /System/Applications/Calculator.app 1 --yes)"; code=$?
expect "odmowa: /System" "$out" "System Integrity Protection"
expect_code "odmowa: /System – kod 1" "$code" 1 "$out"
out="$(ctlpw uninstall "$AP_APPS/Firma Testowa/Program Firmy.app/Contents/MacOS/Program Firmy" 1 --yes)"
expect "odmowa: plik wewnątrz aplikacji" "$out" "wewnątrz innej aplikacji"
mkdir -p "$WORK/Users/inny/Applications"
ap_mkapp "$WORK/Users/inny/Applications" Obca pl.test.obca
out="$(ctlpw uninstall "$WORK/Users/inny/Applications/Obca.app" 1 --yes)"
expect "odmowa: folder innego konta" "$out" "Odinstalowywać można tylko"
[ -d "$WORK/Users/inny/Applications/Obca.app" ] && pass "odmowa: aplikacja innego konta została" || fail "odmowa: usunięto aplikację innego konta"
mkdir -p "$WORK/in/podmiana"
ap_mkapp "$WORK/in/podmiana" Cel pl.test.cel
ln -s "$WORK/in/podmiana" "$AP_HOME/Applications/Podmiana"
out="$(ctlpw uninstall "$AP_HOME/Applications/Podmiana/Cel.app" 1 --yes)"
expect "odmowa: dowiązanie w folderze ucznia" "$out" "dowiązanie"
[ -d "$WORK/in/podmiana/Cel.app" ] && pass "odmowa: nic nie usunięto przez dowiązanie" || fail "odmowa: usunięto przez dowiązanie"
out="$(ctlpw uninstall "Nie Ma Takiej" 1 --yes)"; code=$?
expect "brak aplikacji: komunikat" "$out" "Nie znaleziono: Nie Ma Takiej.app"
expect_code "brak aplikacji: kod 0" "$code" 0 "$out"
out="$(ctlpw uninstall Applications/X.app 1 --yes)"; code=$?
expect_code "ścieżka względna: kod 2" "$code" 2 "$out"
: > "$WORK/mdm.enrolled"
out="$(ctlpw uninstall "Ze Sklepu" 1 --dry-run)"
rm -f "$WORK/mdm.enrolled"
expect "App Store i MDM: wyjaśnienia" "$out" "Aplikacja z App Store" "zarządzany przez MDM"
out="$(ctl uninstall --help)"
expect "uninstall --help" "$out" "--dry-run" "--with-package-files"
rm -rf "$WORK/Users/inny" "$WORK/in/podmiana" "$AP_HOME/Applications/Podmiana"

section "Odinstalowanie – usługi tylko tej aplikacji (identyfikator ucznia nic nie znaczy)"
# Services of other software, system-wide: MDM, an updater, a vendor's agent and helper.
AP_TOOLS="$AP_FS/Library/PrivilegedHelperTools"
ap_plist "$AP_FS/Library/LaunchDaemons/com.jamf.management.daemon.plist" com.jamf.management.daemon "$AP_TOOLS/com.jamf.management.daemon"
printf '#!/bin/sh\n' > "$AP_TOOLS/com.jamf.management.daemon"
ap_plist "$AP_FS/Library/LaunchAgents/com.jamf.management.agent.plist" com.jamf.management.agent "/Library/JamfManagement/agent"
ap_plist "$AP_FS/Library/LaunchDaemons/com.google.keystone.daemon.plist" com.google.keystone.daemon "/Library/Google/keystone"
ap_untouched() { # ap_untouched NAME – the services of other software are all still there
  [ -f "$AP_FS/Library/LaunchDaemons/com.jamf.management.daemon.plist" ] && [ -f "$AP_TOOLS/com.jamf.management.daemon" ] \
    && [ -f "$AP_FS/Library/LaunchAgents/com.jamf.management.agent.plist" ] && [ -f "$AP_FS/Library/LaunchDaemons/com.google.keystone.daemon.plist" ] \
    && pass "$1: usługi innego oprogramowania nietknięte" || fail "$1: usunięto cudzą usługę" "$(ls "$AP_FS/Library/LaunchDaemons" "$AP_FS/Library/LaunchAgents" "$AP_TOOLS")"
}
for bid in com com.jamf com.jamf.management; do
  ap_mkapp "$AP_HOME/Applications" "Zla Gra" "$bid" 1.0
  clear_fakelog
  out="$(ctlpw uninstall "Zla Gra" 1 --dry-run)"; code=$?
  expect_code "złośliwy identyfikator $bid: podgląd – kod 0" "$code" 0 "$out"
  expect_not "złośliwy identyfikator $bid: podgląd bez usług systemowych" "$out" "usługę systemową"
  expect_not "złośliwy identyfikator $bid: podgląd bez agenta systemowego" "$out" "LaunchAgent) com.jamf.management.agent"
  out="$(ctlpw uninstall "Zla Gra" 1 --yes)"; code=$?
  expect_code "złośliwy identyfikator $bid: usunięcie – kod 0" "$code" 0 "$out"
  [ ! -e "$AP_HOME/Applications/Zla Gra.app" ] && pass "złośliwy identyfikator $bid: aplikacja ucznia usunięta" || fail "złośliwy identyfikator $bid: aplikacja została" "$out"
  expect_not "złośliwy identyfikator $bid: żadnego bootout systemu" "$(fakelog)" "bootout system"
  ap_untouched "złośliwy identyfikator $bid"
done
# The same for an app in /Applications: a short id is no reason to touch other software's services.
ap_mkapp "$AP_APPS" "Krotka" com 1.0
out="$(ctlpw uninstall "Krotka" 1 --yes)"
expect_not "krótki identyfikator w /Applications: żadnego bootout systemu" "$(fakelog)" "bootout system"
ap_untouched "krótki identyfikator w /Applications"

# A real vendor service: its Program is inside the bundle (under another label); an unrelated one with the same label prefix stays.
ap_mkapp "$AP_APPS" "Producent" pl.test.producent 2.0
ap_plist "$AP_FS/Library/LaunchDaemons/pl.firma.producent.plist" pl.firma.producent "$AP_APPS/Producent.app/Contents/MacOS/Producent"
ap_plist "$AP_FS/Library/LaunchDaemons/pl.test.producent.inny.plist" pl.test.producent.inny "/Library/Inny/dziala"
clear_fakelog
out="$(ctlpw uninstall "Producent" 1 --dry-run)"
expect "usługa producenta: podgląd z ostrzeżeniem" "$out" "usługę systemową (LaunchDaemon) pl.firma.producent" "uwaga: usługa systemowa" "jej program leży w usuwanej aplikacji"
expect_not "usługa producenta: podgląd nie obejmuje cudzej usługi o podobnej etykiecie" "$out" "pl.test.producent.inny"
out="$(ctlpw uninstall "Producent" 1 --yes)"; code=$?
expect_code "usługa producenta: kod 0" "$code" 0 "$out"
[ ! -e "$AP_APPS/Producent.app" ] && [ ! -e "$AP_FS/Library/LaunchDaemons/pl.firma.producent.plist" ] \
  && pass "usługa producenta: aplikacja i usługa usunięte" || fail "usługa producenta: została" "$out"
[ -f "$AP_FS/Library/LaunchDaemons/pl.test.producent.inny.plist" ] && pass "usługa producenta: usługa o tej samej etykiecie bez programu w aplikacji została" \
  || fail "usługa producenta: usunięto cudzą usługę"
expect "usługa producenta: zatrzymana przed usunięciem" "$(fakelog)" "launchctl bootout system $AP_FS/Library/LaunchDaemons/pl.firma.producent.plist"
expect_not "usługa producenta: cudza usługa nie zatrzymana" "$(fakelog)" "pl.test.producent.inny"
rm -f "$AP_FS/Library/LaunchDaemons/pl.test.producent.inny.plist"
ap_untouched "usługa producenta"

section "Odinstalowanie – kopia uruchomiona z AppTranslocation i pliki usług pakietu"
ap_mkapp "$AP_APPS" "Translokowana" pl.test.translokowana 1.0
mkdir -p "$WORK/AppTranslocation/UUID/d"
cp -R "$AP_APPS/Translokowana.app" "$WORK/AppTranslocation/UUID/d/Translokowana.app"
TR_PID="$(ap_start "$WORK/AppTranslocation/UUID/d/Translokowana.app/Contents/MacOS/Translokowana")"
sleep 0.3
out="$(ctlpw uninstall "Translokowana" 1 --dry-run)"
expect "translokacja: podgląd widzi uruchomioną kopię" "$out" "Aplikacja jest uruchomiona – konto: $ME"
out="$(ctlpw uninstall "Translokowana" 1 --yes)"; code=$?
expect_code "translokacja: kod 0" "$code" 0 "$out"
sleep 0.3
if kill -0 "$TR_PID" 2>/dev/null; then fail "translokacja: kopia z AppTranslocation nadal działa" "$out"; kill "$TR_PID" 2>/dev/null
else pass "translokacja: kopia z AppTranslocation zamknięta"; fi
rm -rf "$WORK/AppTranslocation"

# The package installed an app, a launch daemon under a label that has nothing to do with the app's id, and its helper.
ap_mkapp "$AP_APPS" "Z Pakietu" pl.test.zpakietu 1.0
printf '#!/bin/sh\n' > "$AP_TOOLS/pl.firma.aktualizator"
ap_plist "$AP_FS/Library/LaunchDaemons/pl.firma.aktualizator.plist" pl.firma.aktualizator "$AP_TOOLS/pl.firma.aktualizator"
mkdir -p "$AP_RC/pl.test.zpakietu.pkg"
printf 'version: 1.0\nlocation: /\ninstall-time: 1767225600\n' > "$AP_RC/pl.test.zpakietu.pkg/info"
printf '%s\n' "$R/Applications/Z Pakietu.app/Contents/Info.plist" "$R/Applications/Z Pakietu.app/Contents/MacOS/Z Pakietu" \
  "$R/fsroot/Library/LaunchDaemons/pl.firma.aktualizator.plist" "$R/fsroot/Library/PrivilegedHelperTools/pl.firma.aktualizator" \
  > "$AP_RC/pl.test.zpakietu.pkg/files"
printf '%s\n' "$R/Applications" "$R/Applications/Z Pakietu.app" > "$AP_RC/pl.test.zpakietu.pkg/dirs"
clear_fakelog
out="$(ctlpw uninstall "Z Pakietu" 1 --dry-run)"
expect_not "usługa pakietu bez --with-package-files: nie jest planowana" "$out" "pl.firma.aktualizator (najpierw"
out="$(ctlpw uninstall "Z Pakietu" 1 --dry-run --with-package-files)"
expect "usługa pakietu: podgląd jako usługa, nie plik" "$out" "usługę systemową (LaunchDaemon) pl.firma.aktualizator" "uwaga: usługa systemowa" "plik pakietu usuwanego razem z aplikacją"
expect_not "usługa pakietu: plist nie jest zwykłym plikiem pakietu" "$out" "plik pakietu: $AP_FS/Library/LaunchDaemons/pl.firma.aktualizator.plist"
out="$(ctlpw uninstall "Z Pakietu" 1 --with-package-files --yes)"; code=$?
expect_code "usługa pakietu: kod 0" "$code" 0 "$out"
expect "usługa pakietu: zatrzymana przed usunięciem" "$(fakelog)" "launchctl bootout system $AP_FS/Library/LaunchDaemons/pl.firma.aktualizator.plist"
[ ! -e "$AP_FS/Library/LaunchDaemons/pl.firma.aktualizator.plist" ] && [ ! -e "$AP_TOOLS/pl.firma.aktualizator" ] \
  && pass "usługa pakietu: plik usługi i program usunięte" || fail "usługa pakietu: została" "$out"
ap_untouched "usługa pakietu"

section "Odinstalowanie – dowiązanie w /Applications na zewnątrz"
mkdir -p "$WORK/Shared"
ap_mkapp "$WORK/Shared" Narzedzie2 pl.test.narzedzie2
ln -s "$WORK/Shared/Narzedzie2.app" "$AP_APPS/Narzedzie2.app"
out="$(ctl apps installed 1 --json)"
expect "dowiązanie na zewnątrz: lista nie oferuje usunięcia" "$(ap_json "$out" "apps['Narzedzie2']['location'], apps['Narzedzie2']['removable']")" "link" "False"
out="$(ctlpw uninstall "$AP_APPS/Narzedzie2.app" 1 --yes)"
expect "dowiązanie na zewnątrz: odmowa z tym samym powodem" "$out" "Odmowa:" "dowiązanie"
[ -d "$WORK/Shared/Narzedzie2.app" ] && pass "dowiązanie na zewnątrz: cel nietknięty" || fail "dowiązanie na zewnątrz: cel usunięty"
rm -rf "$AP_APPS/Narzedzie2.app" "$WORK/Shared"

section "Wersje aplikacji na dwóch komputerach"
# A second test iMac (imac03): another sshd of this run, the same fakes, its own Applications folder.
AP2="$WORK/mac2"
AP2_PORT=$((PORT + 1))
mkdir -p "$AP2/Applications"
sed -e "s/^Port .*/Port $AP2_PORT/" -e "s#^PidFile .*#PidFile $AP2/sshd.pid#" \
  -e "s#CMCR_APPS_DIR=[^ ]*#CMCR_APPS_DIR=$AP2/Applications#" "$WORK/sshd_config" > "$AP2/sshd_config"
/usr/sbin/sshd -D -e -f "$AP2/sshd_config" 2>"$AP2/sshd.log" &
AP2_PID=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 "$AP2_PORT" 2>/dev/null && break; sleep 0.1; done
cp "$WORK/config/hosts.json" "$AP2/hosts.json.bak"
python3 - "$WORK/config/hosts.json" "$ME" "$AP2_PORT" <<'PY'
import json, sys
p, me, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
hosts = json.load(open(p))
hosts.append({"id": "33333333-3333-3333-3333-333333333333", "name": "imac03", "address": "127.0.0.1", "user": me, "port": port})
json.dump(hosts, open(p, "w"))
PY
out="$("$CTL" trust 3 --yes 2>&1)"
expect "drugi komputer: klucz zaufany" "$out" "imac03: zaufano"
ap_mkapp "$AP_APPS" "Wersje Test" pl.test.wersje 1.0
ap_mkapp "$AP2/Applications" "Wersje Test" pl.test.wersje 2.0
# Without CFBundleShortVersionString: CFBundleVersion is the version; without both: none („—”, null in JSON).
ap_mkapp "$AP2/Applications" "Tylko Build" pl.test.build 9.9
plutil -remove CFBundleShortVersionString "$AP2/Applications/Tylko Build.app/Contents/Info.plist"
plutil -insert CFBundleVersion -string 77 "$AP2/Applications/Tylko Build.app/Contents/Info.plist"
ap_mkapp "$AP_APPS" "Bez Wersji" pl.test.bez 9.9
plutil -remove CFBundleShortVersionString "$AP_APPS/Bez Wersji.app/Contents/Info.plist"
out="$(ctl apps installed 1,3 --json)"; code=$?
expect_code "dwa komputery: apps installed --json – kod 0" "$code" 0 "$out"
ap_json2() { # ap_json2 JSON HOST-INDEX APP – version of APP on that host ("None" when missing)
  printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); a={x['name']: x for x in d[$2]['apps']}; print(repr(a['$3']['version']) if '$3' in a else 'brak')" 2>&1
}
expect "dwa komputery: każdy ze swoją wersją" "$(ap_json2 "$out" 0 "Wersje Test") $(ap_json2 "$out" 1 "Wersje Test")" "'1.0' '2.0'"
expect "wersja z CFBundleVersion, gdy brak CFBundleShortVersionString" "$(ap_json2 "$out" 1 "Tylko Build")" "'77'"
expect "brak obu kluczy: wersja null w JSON" "$(ap_json2 "$out" 0 "Bez Wersji")" "None"
out="$(ctl apps installed 1,3)"
expect "apps installed: kolumna Wersja" "$out" "Aplikacja" "Wersja" "Rozmiar" "Identyfikator"
expect "apps installed: wersje w wierszach obu komputerów" "$(printf '%s\n' "$out" | grep 'Wersje Test')" "1.0" "2.0"
expect "apps installed: brak wersji jako —" "$(printf '%s\n' "$out" | grep 'Bez Wersji')" "—"
expect "apps installed: wersja z CFBundleVersion" "$(printf '%s\n' "$out" | grep 'Tylko Build')" " 77 "
out="$(ctlpw uninstall "Wersje Test" 1,3 --dry-run)"; code=$?
expect_code "podgląd na dwóch komputerach: kod 0" "$code" 0 "$out"
expect "podgląd: usuwana wersja na każdym komputerze" "$out" \
  "== imac01" "▸ Wersje Test – wersja 1.0, pl.test.wersje" "== imac03" "▸ Wersje Test – wersja 2.0, pl.test.wersje"
expect "podgląd: aplikacja bez wersji" "$(ctlpw uninstall "Bez Wersji" 1 --dry-run)" "▸ Bez Wersji – wersja —"
out="$(ctlpw uninstall "Wersje Test" 1,3 --yes)"; code=$?
expect_code "odinstalowanie na dwóch komputerach: kod 0" "$code" 0 "$out"
expect "odinstalowanie: raport z wersją z każdego komputera" "$out" "wersja 1.0" "wersja 2.0" "Wynik: usunięto"
[ ! -e "$AP_APPS/Wersje Test.app" ] && [ ! -e "$AP2/Applications/Wersje Test.app" ] \
  && pass "odinstalowanie: usunięte na obu komputerach" || fail "odinstalowanie: aplikacja została" "$out"
kill "$AP2_PID" 2>/dev/null
wait "$AP2_PID" 2>/dev/null
cp "$AP2/hosts.json.bak" "$WORK/config/hosts.json"
rm -rf "$AP_APPS/Bez Wersji.app"
