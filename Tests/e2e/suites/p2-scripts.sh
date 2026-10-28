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

section "P2: zakończenie zajęć bez ucznia przy ekranie (AUDIT DOD-08)"
python3 - "$WORK/config/classroom.json" <<'PY'
import json, sys
cfg = {"end": {"warn": False, "collect": False, "quitApps": True, "quitAllApps": True, "cleanShared": False,
               "cleanDownloads": False, "logout": False, "power": "none"}}
json.dump(cfg, open(sys.argv[1], "w"), ensure_ascii=False)
PY
# Real GUI sessions of other accounts on this Mac would count as sessions in the background.
others="$(ctl exec 'cmcr_gui_sessions | awk -v a="$CMCR_ADMIN_USER" "\$2 != a" | wc -l' 1 | tail -1 | tr -d ' ')"
: > "$WORK/fake-no-console"
if [ "$others" = 0 ]; then
  out="$(ctlpw lesson end 1 --no-wait --yes)"; code=$?
  expect "lesson end, nikt nie jest zalogowany: krok pominięty" "$out" "nikt nie jest zalogowany"
  expect_not "lesson end, nikt nie jest zalogowany: nie twierdzi, że zamknięto aplikacje" "$out" "aplikacje zamknięte"
  out="$(ctlpw _builder quit-app 1 P2Nic)"; code=$?
  expect "quit-app, nikt nie jest zalogowany: znacznik dla zajęć" "$out" "CMCR:NOUSER"
  expect_code "quit-app, nikt nie jest zalogowany: kod 0" "$code" 0 "$out"
else
  pass "lesson end bez sesji: pominięto (na tym Macu są sesje innych kont)"
fi
echo "502 uczen-p2" > "$WORK/ps.sessions"
out="$(ctlpw lesson end 1 --no-wait --yes)"; code=$?
expect_code "lesson end, sesja ucznia w tle: kod 1" "$code" 1 "$out"
expect_not "lesson end, sesja ucznia w tle: nie twierdzi, że zamknięto aplikacje" "$out" "aplikacje zamknięte"
out="$(ctlpw _builder quit-app 1 P2Nic)"; code=$?
expect "quit-app, sesja ucznia w tle: komunikat" "$out" "w tle działa sesja: uczen-p2"
expect_code "quit-app, sesja ucznia w tle: kod 1" "$code" 1 "$out"
rm -f "$WORK/ps.sessions" "$WORK/fake-no-console" "$WORK/config/classroom.json"

section "P2: opóźnione zasilanie – ostrzeżenie, którego nie było komu pokazać (AUDIT DOD-07)"
# The delayed action waits in a detached /bin/bash – it must see the fakes too.
p2_bg_ok() { [ "$(ctlpw exec '/bin/bash --noprofile --norc -c "type pmset shutdown pkill launchctl" 2>&1 | grep -c "is a function"' 1 --root | tail -1)" = 4 ]; }
if p2_bg_ok; then
  : > "$WORK/fake-no-console"
  out="$(ctlpw power-later shutdown 30 1 --warn "Test P2" --yes)"
  rm -f "$WORK/fake-no-console"
  ctlpw power-cancel 1 >/dev/null
  expect "power-later, nikt nie jest zalogowany: wynik mówi, że ostrzeżenia nie wyświetlono" "$out" "ostrzeżenia nie wyświetlono"
else
  fail "atrapy NIE są aktywne w procesach w tle – pominięto test opóźnionego wyłączenia"
fi

section "P2: opóźnione zasilanie – jak odwołać (AUDIT TXT-07, CLI-16)"
if p2_bg_ok; then
  out="$(ctlpw power-later sleep 30 1 --yes)"
  ctlpw power-cancel 1 >/dev/null
  expect "power-later: wskazówka, jak odwołać" "$out" "Zaplanowane na później" "„Odwołaj”" "cmcrctl power-cancel"
  expect_not "power-later: bez nieistniejącego przycisku" "$out" "Anuluj zaplanowane"
else
  fail "atrapy NIE są aktywne w procesach w tle – pominięto test opóźnionego uśpienia"
fi

section "P2: harmonogram zasilania wyłącza autorestart i Wake-on-LAN (AUDIT KOM-03)"
clear_fakelog
out="$(ctlpw schedule set 1 --on MTWRF@07:45 --no-autorestart --no-womp)"; code=$?
expect_code "schedule set --no-autorestart --no-womp: kod 0" "$code" 0 "$out"
expect "schedule set: wyłączone przełączniki wyłączają ustawienia" "$(fakelog)" "pmset -a autorestart 0" "pmset -a womp 0"
expect "schedule set: wynik pokazuje wyłączone Wake-on-LAN" "$out" "womp=0" "autorestart=0"
clear_fakelog
out="$(ctlpw schedule set 1 --on MTWRF@07:45)"
expect "schedule set: domyślnie włącza oba" "$(fakelog)" "pmset -a autorestart 1" "pmset -a womp 1"
ctlpw schedule clear 1 >/dev/null
rm -f "$WORK/pmset.womp" "$WORK/pmset.autorestart"

section "P2: wysyłanie – nieudana zmiana właściciela to błąd (AUDIT PLI-08)"
mkdir -p "$P2/send" "$WORK/remote/p2push"
echo p2 > "$P2/send/p2-plik.txt"
out="$(ctlpw _builder push 1 "$WORK/remote/p2push" "p2-nie-ma-takiego-konta" "" "$P2/send/p2-plik.txt" --root)"; code=$?
expect "push: nieistniejące konto – komunikat" "$out" "p2-nie-ma-takiego-konta" "nie istnieje"
[ "$code" != 0 ] && pass "push: nieistniejące konto – błąd" || fail "push: nieistniejące konto – kod 0" "$out"
[ ! -e "$WORK/remote/p2push/p2-plik.txt" ] && pass "push: nieistniejące konto – nic nie zapisano" \
  || fail "push: plik zapisany z niezmienionym właścicielem" "$out"
: > "$WORK/chown.fail"
out="$(ctlpw _builder push 1 "$WORK/remote/p2push" "$ME" "" "$P2/send/p2-plik.txt" --root)"; code=$?
rm -f "$WORK/chown.fail"
expect_code "push: chown odmówił – kod 1" "$code" 1 "$out"
expect "push: chown odmówił – komunikat" "$out" "Nie udało się ustawić właściciela"
[ ! -e "$WORK/remote/p2push/p2-plik.txt" ] && pass "push: chown odmówił – pliku nie zapisano" \
  || fail "push: chown odmówił – plik zapisany z właścicielem root" "$out"
out="$(ctlpw _builder push 1 "$WORK/remote/p2push" "$ME" "" "$P2/send/p2-plik.txt" --root)"; code=$?
expect_code "push: poprawny właściciel – kod 0" "$code" 0 "$out"
[ -f "$WORK/remote/p2push/p2-plik.txt" ] && pass "push: poprawny właściciel – plik zapisany" || fail "push: brak pliku" "$out"

section "P2: ~ w ścieżce folderu (AUDIT PLI-09)"
out="$(ctl ls '~' 1)"; code=$?
expect_code "ls ~: kod 0" "$code" 0 "$out"
expect_not "ls ~: ~ rozwinięte" "$out" "No such file"
expect "ls ~: zawartość katalogu domowego" "$out" "Library"
out="$(ctlpw clean "~/cmcr-p2-nie-istnieje-$$" 1 --yes)"; code=$?
expect "clean ~: odmowa z właściwym powodem" "$out" "folder domowy administratora"
expect_not "clean ~: bez mylącej rady o pełnej ścieżce" "$out" "podaj pełną ścieżkę"

section "P2: gotowość – ostrzeżenie sudo przed złym hasłem (AUDIT PRZ-08)"
: > "$WORK/sudo.lecture"
out="$(CMCR_PASSWORD="zle-haslo-p2" "$CTL" readiness 1 2>&1)"
rm -f "$WORK/sudo.lecture"
expect "readiness: złe hasło rozpoznane mimo ostrzeżenia sudo" "$out" "złe hasło"
expect_not "readiness: ostrzeżenie sudo nie jest pokazywane jako błąd" "$out" "Improper use"

section "P2: skrypt konfiguracyjny – katalog domowy zapisywalny dla grupy (AUDIT PRZ-15)"
SR="$WORK/setup-root"
SS="$WORK/setup-sys"
SCONF="$WORK/config-p2-setup"
SHOME="$SR/Users/$ME"
p2s() { CMCR_CONFIG_DIR="$SCONF" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
# p2_setup_begin – a configured iMac in $WORK/setup-root (as in suites/setup.sh); fails when the redirection is
# off. Each section ends with p2_setup_end: later suites (suites/setup.sh) start from a fresh state.
p2_setup_begin() {
  mkdir -p "$SHOME/Public" "$SR/etc/ssh/sshd_config.d" "$SR/private/etc/sudoers.d" "$SR/Library/Preferences" "$SS" "$SCONF"
  chmod 755 "$SHOME"
  printf '# test\nInclude /etc/ssh/sshd_config.d/*\nPasswordAuthentication yes\n' > "$SR/etc/ssh/sshd_config"
  printf 'root ALL = (ALL) ALL\n#includedir /private/etc/sudoers.d\n' > "$SR/etc/sudoers"
  printf 'womp 1\nsleep 1\ntcpkeepalive 1\n' > "$SS/pmset"
  echo false > "$SS/screen-preflight"
  echo "FileVault is Off." > "$SS/filevault"
  cp "$WORK/config/hosts.json" "$SCONF/hosts.json"
  cat > "$SCONF/settings.json" <<EOF
{"identityFile":"$WORK/client","extraSSHOptions":"UserKnownHostsFile=$WORK/known_hosts",
 "sharedFolder":"/Users/{student}/Public/cmcr","localFolder":"$WORK/local","studentUser":"$ME","connectTimeout":3}
EOF
  out="$(p2s setup 1 --no-ssh-acl)"; code=$?
  if ! contains "" "$out" "(TEST: pliki systemowe przekierowane do $SR)"; then
    fail "setup: przekierowanie ścieżek nieaktywne – pominięto testy skryptu konfiguracyjnego" "$out"
    return 1
  fi
  expect_code "setup: przygotowanie – kod 0" "$code" 0 "$out"
}
p2_setup_end() { rm -rf "$SS" "$SR" "$SCONF"; }
if p2_setup_begin; then
  # sshd (StrictModes) refuses the key while the home folder is writable for the group.
  chmod 775 "$SHOME"
  out="$(p2s setup 1 --no-ssh-acl --verify)"; code=$?
  expect "setup --verify: katalog domowy zapisywalny dla grupy – do zmiany" "$out" \
    "Wymaga zmiany: usunąć prawo zapisu grupy/innych z $SHOME" '"pending_count": 1,'
  expect_not "setup --verify: nie twierdzi, że usunięto prawo zapisu" "$out" "Usunięto prawo zapisu"
  [ "$(stat -f %Lp "$SHOME")" = 775 ] && pass "setup --verify: nic nie zmieniono" || fail "setup --verify: zmieniono uprawnienia"
  out="$(p2s setup 1 --no-ssh-acl)"; code=$?
  expect_code "setup: usunięcie prawa zapisu – kod 0" "$code" 0 "$out"
  expect "setup: usunięcie prawa zapisu policzone jako zmiana" "$out" "usunięto prawo zapisu grupy/innych z $SHOME" \
    '"changed_count": 1,'
  expect_not "setup: nie „bez zmian”" "$out" "Bez zmian – wszystko było już skonfigurowane"
  [ "$(stat -f %Lp "$SHOME")" = 755 ] && pass "setup: katalog domowy 755" || fail "setup: uprawnienia $(stat -f %Lp "$SHOME")"
fi
p2_setup_end
