# One-time root setup script (setup/cmcr-imac-setup.sh) and the readiness check, run remotely through the
# real RemoteScript root wrapper. Sourced by Tests/e2e/run.sh (helpers: section, expect, ctl, fakelog…).
# Every system path is redirected to $WORK/setup-root (CMCR_SETUP_ROOT_PREFIX, exported by fakes.sh) and
# $WORK/setup-sys holds the simulated system state used by the fakes; nothing outside $WORK is written.

section "Konfiguracja iMaców – skrypt root i gotowość"
SR="$WORK/setup-root"
SS="$WORK/setup-sys"
SCONF="$WORK/config-setup"
SHOME="$SR/Users/$ME"
mkdir -p "$SHOME/Public" "$SR/etc/ssh/sshd_config.d" "$SR/private/etc/sudoers.d" "$SR/Library/Preferences" "$SS" "$SCONF"
printf '# test\nInclude /etc/ssh/sshd_config.d/*\nPasswordAuthentication yes\n' > "$SR/etc/ssh/sshd_config"
printf 'root ALL = (ALL) ALL\n#includedir /private/etc/sudoers.d\n' > "$SR/etc/sudoers"
chmod 775 "$SHOME"                                   # sshd StrictModes: the script must remove group write
printf 'womp 0\nsleep 1\ntcpkeepalive 1\n' > "$SS/pmset"
: > "$SS/off-com.openssh.sshd"                      # Remote Login "off" before the first run
: > "$SS/off-com.apple.screensharing"
echo false > "$SS/screen-preflight"
echo "FileVault is Off." > "$SS/filevault"
cp "$WORK/config/hosts.json" "$SCONF/hosts.json"
cat > "$SCONF/settings.json" <<EOF
{"identityFile":"$WORK/client","extraSSHOptions":"UserKnownHostsFile=$WORK/known_hosts",
 "sharedFolder":"/Users/{student}/Public/cmcr","localFolder":"$WORK/local","studentUser":"$ME","connectTimeout":3}
EOF
sctl() { CMCR_CONFIG_DIR="$SCONF" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
setup_run() { # setup_run EXTRA-FLAGS… – the same options every time (idempotency)
  sctl setup 1 --no-ssh-acl --no-sleep --sudo-nopasswd --power-schedule "MTWRF 07:30 17:00" "$@"
}

clear_fakelog
out="$(setup_run --dry-run)"; code=$?
if ! contains "" "$out" "(TEST: pliki systemowe przekierowane do $SR)"; then
  fail "setup: przekierowanie ścieżek nieaktywne – pomijam testy zapisujące" "$out"
  rm -rf "$SS"
  return 0 2>/dev/null
fi
pass "setup: ścieżki systemowe przekierowane do katalogu testowego"
expect_code "setup --dry-run: kod 0" "$code" 0 "$out"
expect "setup --dry-run: plan zmian i raport JSON" "$out" \
  "[próba] launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist" "Wymaga zmiany: zainstalować klucz SSH" \
  "-----BEGIN CMCR SETUP JSON-----" '"mode": "dry-run"' "→ imac01: Do zmiany:"
[ ! -e "$SHOME/.ssh" ] && [ ! -e "$SR/Library/Application Support/CMCR/setup.json" ] \
  && pass "setup --dry-run: nic nie zapisano" || fail "setup --dry-run: zapisano pliki" "$(find "$SR" | head -20)"
expect_not "setup --dry-run: bez zmian w systemie" "$(fakelog)" "pmset -a"

sctl setup-script > "$WORK/standalone.sh"
out="$(ctlpw exec "/bin/bash $WORK/standalone.sh --no-guide" 1)"; code=$?
expect_code "skrypt bez roota: kod 3" "$code" 3 "$out"
expect "skrypt bez roota: komunikat" "$out" "trzeba uruchomić jako root"
out="$(ctlpw exec "/bin/bash $WORK/standalone.sh --power-schedule 'MTWXF 07:30' --verify" 1 --root)"; code=$?
expect_code "skrypt: błędne opcje – kod 2" "$code" 2 "$out"
out="$(sctl setup 1 --power-schedule "MTWXF 07:30")"; code=$?
expect_code "cmcrctl setup: błędne opcje odrzucone przed połączeniem" "$code" 2 "$out"

clear_fakelog
out="$(setup_run)"; code=$?
expect_code "setup: pierwsze uruchomienie – kod 0" "$code" 0 "$out"
expect "setup: zmiany w raporcie" "$out" "Włączono zdalne logowanie (SSH)" "Klucz SSH menedżera zainstalowany" \
  "050-cmcr-manager.conf" "Harmonogram ustawiony: pn wt śr cz pt: włączenie 07:30, wyłączenie 17:00" \
  "sudo bez hasła WŁĄCZONE" "Do zrobienia ręcznie" "→ imac01: Zmieniono"
expect "setup: polecenia systemowe przez atrapy" "$(fakelog)" \
  "launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist" "pmset -a womp 1" "pmset -a sleep 0" \
  "pmset repeat wakeorpoweron MTWRF 07:30:00 shutdown MTWRF 17:00:00" "visudo -cf" "sshd -t -f $SR/etc/ssh/sshd_config"
AK="$SHOME/.ssh/authorized_keys"
if grep -qF "$(awk '{print $2}' "$WORK/client.pub")" "$AK" 2>/dev/null; then pass "setup: klucz w authorized_keys"
else fail "setup: brak klucza w authorized_keys" "$(ls -la "$SHOME/.ssh" 2>&1)"; fi
perms="$(stat -f %Lp "$SHOME/.ssh") $(stat -f %Lp "$AK") $(stat -f %Lp "$SHOME")"
[ "$perms" = "700 600 755" ] && pass "setup: uprawnienia .ssh/authorized_keys/katalogu domowego" || fail "setup: uprawnienia $perms"
D="$SHOME/Public/cmcr"
if [ "$(stat -f %Lp "$D" 2>/dev/null)" = 777 ] && ls -led "$D" | grep -q "user:$ME allow .*directory_inherit"; then
  pass "setup: folder ucznia 777 z dziedziczonym ACL"
else fail "setup: folder ucznia" "$(ls -led "$D" 2>&1)"; fi
expect "setup: drop-in sshd" "$(cat "$SR/etc/ssh/sshd_config.d/050-cmcr-manager.conf" 2>&1)" "ClientAliveInterval 30"
expect "setup: reguła sudoers" "$(cat "$SR/private/etc/sudoers.d/cmcr-manager" 2>&1)" "$ME ALL=(ALL) NOPASSWD: ALL"
[ "$(stat -f %Lp "$SR/private/etc/sudoers.d/cmcr-manager" 2>/dev/null)" = 440 ] && pass "setup: sudoers 0440" || fail "setup: sudoers uprawnienia"
MARK="$SR/Library/Application Support/CMCR/setup.json"
marker="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("v=%s plan=%s ssh=%s fail=%s" % (d["version"], d["power_schedule"], d["via_ssh"], d["fail_count"]))' "$MARK" 2>&1)"
expect "setup: znacznik setup.json (poprawny JSON, wersja, harmonogram)" "$marker" \
  "v=1." "plan=MTWRF 07:30 17:00 shutdown" "ssh=True" "fail=0"
[ -s "$SR/Library/Logs/CMCR/cmcr-imac-setup.log" ] && pass "setup: dziennik zapisany" || fail "setup: brak dziennika"
left="$(find /tmp -maxdepth 1 -name 'cmcr-setup.*' -user "$ME" 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = 0 ] && pass "setup: brak plików tymczasowych" || fail "setup: zostały katalogi cmcr-setup.* ($left)"

clear_fakelog
out="$(setup_run)"; code=$?
expect_code "setup: drugie uruchomienie – kod 0" "$code" 0 "$out"
expect "setup: idempotentność – brak zmian" "$out" "✚ 0" '"changed_count": 0,' "Bez zmian – wszystko było już skonfigurowane"
expect_not "setup: idempotentność – bez poleceń zmieniających" "$(fakelog)" "pmset -a"
out="$(setup_run --verify)"; code=$?
expect_code "setup --verify: kod 0" "$code" 0 "$out"
expect "setup --verify: nic do zmiany" "$out" '"mode": "verify"' '"pending_count": 0,'

cp -p "$SR/etc/ssh/sshd_config.d/050-cmcr-manager.conf" "$WORK/sshd-before.conf"
: > "$SS/sshd-t-fails"
out="$(setup_run --ssh-key-only)"; code=$?
rm -f "$SS/sshd-t-fails"
expect_code "setup: sshd -t odrzuca – kod 1" "$code" 1 "$out"
expect "setup: sshd -t odrzuca – komunikat" "$out" "sshd -t odrzucił konfigurację – przywrócono poprzednią"
cmp -s "$WORK/sshd-before.conf" "$SR/etc/ssh/sshd_config.d/050-cmcr-manager.conf" \
  && pass "setup: poprzedni drop-in sshd przywrócony" || fail "setup: drop-in sshd zmieniony mimo błędu"

out="$(sctl setup 1 --no-ssh-acl --no-sudo-nopasswd --verify)"
expect "setup --verify: planowane usunięcie sudo bez hasła" "$out" "Wymaga zmiany: usunąć sudo bez hasła."
out="$(sctl setup 1 --no-ssh-acl --no-sudo-nopasswd)"; code=$?
expect_code "setup --no-sudo-nopasswd: kod 0" "$code" 0 "$out"
[ ! -e "$SR/private/etc/sudoers.d/cmcr-manager" ] && pass "setup: reguła sudo bez hasła usunięta" || fail "setup: reguła sudoers została"

: > "$SS/blockall"
out="$(sctl setup 1 --no-ssh-acl --verify)"; code=$?
expect_code "zapora blokuje wszystko: kod 1" "$code" 1 "$out"
expect "zapora blokuje wszystko: wskazówka" "$out" "Zapora blokuje wszystkie połączenia przychodzące"
out="$(sctl setup 1 --no-ssh-acl --fix-firewall)"; code=$?
expect_code "setup --fix-firewall: kod 0" "$code" 0 "$out"
[ ! -e "$SS/blockall" ] && pass "setup --fix-firewall: blokada wyłączona" || fail "setup --fix-firewall" "$out"

section "Gotowość iMaców (readiness)"
out="$(sctl readiness 1)"
expect "readiness: stan po konfiguracji" "$out" "SSH i klucz" "klucz" "sudo" "Folder ucznia" "Wake-on-LAN" "włączony" \
  "Udostępnianie ekranu" "wyłączone" "FileVault" "Konfiguracja" "v1."
expect "readiness: kroki ręczne (TCC) wykryte" "$out" "Nagrywanie ekranu" "ręcznie" "Pełny dostęp do dysku"
expect "readiness: sprawdzenie nagrywania bez pytania o zgodę" "$(fakelog)" "osascript: screen-capture preflight"
TCCDIR="$SR/Library/Application Support/com.apple.TCC"
mkdir -p "$TCCDIR"
sqlite3 "$TCCDIR/TCC.db" "CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER);
  INSERT INTO access VALUES ('kTCCServiceSystemPolicyAllFiles','/usr/libexec/sshd-keygen-wrapper',2);
  INSERT INTO access VALUES ('kTCCServiceScreenCapture','/usr/libexec/sshd-keygen-wrapper',2);"
out="$(sctl readiness 1)"; code=$?
expect_code "readiness: wszystko gotowe – kod 0" "$code" 0 "$out"
expect "readiness: gotowy" "$out" "● imac01 – gotowy" "zezwolono"
out="$(setup_run --verify)"
expect "setup --verify: uprawnienia TCC odczytane z bazy" "$out" '"fda_remote": "yes"' '"screen_capture_remote": "yes"' '"todo_count": 0,'
rm -rf "$TCCDIR"
out="$(CMCR_CONFIG_DIR="$SCONF" CMCR_PASSWORD="zle-haslo" "$CTL" readiness 1 2>&1)"
expect "readiness: błędne hasło sudo" "$out" "złe hasło"
rm -rf "$SHOME/Public/cmcr"
out="$(sctl readiness 1)"
expect "readiness: brak folderu ucznia" "$out" "✘ Folder ucznia" "brak"

out="$(ctlpw exec "/bin/bash $WORK/standalone.sh --verify --no-guide --no-ssh-acl" 1 --root)"; code=$?
expect "skrypt zapisany z aplikacji: wbudowany klucz rozpoznany" "$out" "Klucz SSH menedżera jest już zainstalowany"
expect "skrypt zapisany z aplikacji: folder z ustawień" "$out" "Wymaga zmiany" "$SHOME/Public/cmcr"

rm -rf "$SS"
