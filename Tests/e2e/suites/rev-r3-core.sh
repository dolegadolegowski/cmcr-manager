# shellcheck shell=bash
# Review of the audit fixes, round 3, group R3-core: the logout --force hint for a host name with shell characters
# (AUDIT REV-47), a numeric owner of an upload (REV-48) and the one-time setup script's report (REV-49, REV-50).
# Sourced by Tests/e2e/run.sh (helpers: section, pass, fail, expect, expect_not, expect_code, ctl, ctlpw, fakelog,
# clear_fakelog; $WORK $CTL $PASSWORD $ME $PORT). Own configuration folders, so later suites see the original one;
# the setup script's system files go to $WORK/setup-root, simulated system state to $WORK/setup-sys.

RV3="$WORK/rev-r3-core"
mkdir -p "$RV3/cfg"
cp "$WORK/config/settings.json" "$RV3/cfg/"
cat > "$RV3/cfg/hosts.json" <<EOF
[
 {"id":"b1111111-1111-1111-1111-111111111111","name":"Sala!B","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"b2222222-2222-2222-2222-222222222222","name":"=imac3","address":"127.0.0.1","user":"$ME","port":$PORT}
]
EOF
rv3() { CMCR_CONFIG_DIR="$RV3/cfg" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
# rv3_hint OUTPUT – the command of the „(cmcrctl logout … --force – …)” hint, as a teacher would copy it.
rv3_hint() {
  local line
  line="$(printf '%s\n' "$1" | grep -F '(cmcrctl logout' | head -n 1)"
  line="${line#*(}"
  printf '%s' "${line%% – *}"
}
# rv3_paste SHELL COMMAND – what an interactive zsh (the default shell of macOS) or bash prints for COMMAND pasted
# after `echo`: the words the command gets, or the shell's error (history expansion of !, zsh's =name).
rv3_paste() {
  case "$1" in
    zsh) printf 'print -r -- %s\n' "$2" | zsh -f -i 2>&1 ;;
    bash) printf 'echo %s\n' "$2" | bash --norc --noprofile -i 2>&1 ;;
  esac
}

section "REV-47: podpowiedź logout --force po wklejeniu do Terminala działa także dla nazwy z ! lub = na początku"
: > "$WORK/fake-ae-denied"
out="$(rv3 logout 'Sala!B' --yes)"; code=$?
expect_code "logout Sala!B, odmowa macOS: kod 1" "$code" 1 "$out"
expect "logout Sala!B: nazwa w podpowiedzi w cudzysłowie" "$out" "(cmcrctl logout 'Sala!B' --force – "
hint="$(rv3_hint "$out")"
for sh in zsh bash; do
  pasted="$(rv3_paste "$sh" "$hint")"
  expect "logout Sala!B: podpowiedź wklejona do $sh daje te same słowa" "$pasted" "cmcrctl logout Sala!B --force"
  expect_not "logout Sala!B: $sh bez błędu rozwijania historii" "$pasted" "event not found"
done
expect "actions.log: nazwa z ! w cudzysłowie" "$(cat "$RV3/cfg/actions.log" 2>/dev/null)" \
  "cmcrctl logout 'Sala!B' --yes → Sala!B"
out="$(rv3 logout '=imac3' --yes)"; code=$?
expect_code "logout =imac3, odmowa macOS: kod 1" "$code" 1 "$out"
expect "logout =imac3: nazwa w podpowiedzi w cudzysłowie" "$out" "(cmcrctl logout '=imac3' --force – "
pasted="$(rv3_paste zsh "$(rv3_hint "$out")")"
expect "logout =imac3: podpowiedź wklejona do zsh daje te same słowa" "$pasted" "cmcrctl logout =imac3 --force"
expect_not "logout =imac3: zsh nie szuka polecenia imac3" "$pasted" "imac3 not found"
rm -f "$WORK/fake-ae-denied"

section "REV-48: właściciel podany numerem – konto o tym numerze albo właściciel folderu docelowego"
RV3_UID=59999
while id -u "$RV3_UID" >/dev/null 2>&1; do RV3_UID=$((RV3_UID + 1)); done
RV3_DEST="$WORK/remote/rev-r3-push"
mkdir -p "$RV3/send" "$RV3_DEST"
echo rev-r3 > "$RV3/send/rev-r3-plik.txt"
# A typo in „Inny…” (5011 instead of 501): no account has the number and the folder is not that uid's.
clear_fakelog
out="$(ctlpw _builder push 1 "$RV3_DEST" "$RV3_UID:staff" "" "$RV3/send/rev-r3-plik.txt" --root)"; code=$?
expect_code "push: numer bez konta, folder innego konta – kod 2" "$code" 2 "$out"
expect "push: numer bez konta – komunikat" "$out" "✘ Konto „$RV3_UID” nie istnieje na tym komputerze – nic nie wysłano"
[ ! -e "$RV3_DEST/rev-r3-plik.txt" ] && pass "push: numer bez konta – nic nie zapisano" \
  || fail "push: numer bez konta – plik zapisany" "$(ls -la "$RV3_DEST")"
expect_not "push: numer bez konta – bez chown na ten numer" "$(fakelog)" "$RV3_UID:staff"
# Above the largest uid chown takes: refused before a missing folder on the way is created.
for n in 99999999999 2147483648; do
  out="$(ctlpw _builder push 1 "$RV3_DEST/nowy/glebiej" "$n:staff" "" "$RV3/send/rev-r3-plik.txt" --root)"; code=$?
  expect_code "push: właściciel $n – kod 2" "$code" 2 "$out"
  expect "push: właściciel $n – komunikat" "$out" "✘ Konto „$n” nie istnieje na tym komputerze"
  [ ! -e "$RV3_DEST/nowy" ] && pass "push: właściciel $n – nie utworzono folderu" \
    || { fail "push: właściciel $n – utworzono folder" "$(ls -laR "$RV3_DEST")"; rm -rf "$RV3_DEST/nowy"; }
done
# The folder of a deleted account (the remote browser sends its owner as `stat %Su` shows it, a bare uid): accepted
# for the folder itself and for a new folder inside it (fakes.sh: stat.uid), also with leading zeros.
printf '%s %s\n' "$RV3_UID" "$(cd "$RV3_DEST" && pwd -P)" > "$WORK/stat.uid"
clear_fakelog
out="$(ctlpw _builder push 1 "$RV3_DEST" "$RV3_UID:staff" "" "$RV3/send/rev-r3-plik.txt" --root)"; code=$?
expect_code "push: folder usuniętego konta, jego numer – kod 0" "$code" 0 "$out"
[ -f "$RV3_DEST/rev-r3-plik.txt" ] && pass "push: folder usuniętego konta – plik zapisany" \
  || fail "push: folder usuniętego konta – brak pliku" "$out"
expect "push: folder usuniętego konta – chown dostał numer" "$(fakelog)" "chown -R $RV3_UID:staff"
out="$(ctlpw _builder push 1 "$RV3_DEST/nowy" "0$RV3_UID:staff" "" "$RV3/send/rev-r3-plik.txt" --root)"; code=$?
expect_code "push: nowy folder w folderze usuniętego konta (numer z zerem na początku) – kod 0" "$code" 0 "$out"
[ -f "$RV3_DEST/nowy/rev-r3-plik.txt" ] && pass "push: nowy folder w folderze usuniętego konta – plik zapisany" \
  || fail "push: nowy folder w folderze usuniętego konta – brak pliku" "$out"
rm -f "$WORK/stat.uid"
# A number of an existing account works for any folder, as before.
out="$(ctlpw _builder push 1 "$RV3_DEST" "$(id -u):staff" "" "$RV3/send/rev-r3-plik.txt" --root)"; code=$?
expect_code "push: numer istniejącego konta – kod 0" "$code" 0 "$out"
rm -rf "$RV3_DEST"

# rv3_setup_begin – a configured iMac in $WORK/setup-root (as in suites/rev-r2-scripts.sh); fails when the
# redirection is off. Each section ends with rv3_setup_end: later suites start from a fresh state.
RV3_SR="$WORK/setup-root"
RV3_SS="$WORK/setup-sys"
RV3_CONF="$WORK/config-rev-r3-setup"
RV3_HOME="$RV3_SR/Users/$ME"
RV3_DROPIN="$RV3_SR/etc/ssh/sshd_config.d/050-cmcr-manager.conf"
rv3s() { CMCR_CONFIG_DIR="$RV3_CONF" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
rv3_setup_begin() {
  mkdir -p "$RV3_HOME/Public" "$RV3_SR/etc/ssh/sshd_config.d" "$RV3_SR/private/etc/sudoers.d" \
    "$RV3_SR/Library/Preferences" "$RV3_SS" "$RV3_CONF"
  chmod 755 "$RV3_HOME"
  printf '# test\nInclude /etc/ssh/sshd_config.d/*\nPasswordAuthentication yes\n' > "$RV3_SR/etc/ssh/sshd_config"
  printf 'root ALL = (ALL) ALL\n#includedir /private/etc/sudoers.d\n' > "$RV3_SR/etc/sudoers"
  printf 'womp 1\nsleep 1\ntcpkeepalive 1\n' > "$RV3_SS/pmset"
  echo false > "$RV3_SS/screen-preflight"
  echo "FileVault is Off." > "$RV3_SS/filevault"
  cp "$WORK/config/hosts.json" "$RV3_CONF/hosts.json"
  cat > "$RV3_CONF/settings.json" <<EOF
{"identityFile":"$WORK/client","extraSSHOptions":"UserKnownHostsFile=$WORK/known_hosts",
 "sharedFolder":"/Users/{student}/Public/cmcr","localFolder":"$WORK/local","studentUser":"$ME","connectTimeout":3}
EOF
  out="$(rv3s setup 1 --no-ssh-acl)"; code=$?
  if ! contains "" "$out" "(TEST: pliki systemowe przekierowane do $RV3_SR)"; then
    fail "setup: przekierowanie ścieżek nieaktywne – pominięto testy skryptu konfiguracyjnego" "$out"
    return 1
  fi
  expect_code "setup: przygotowanie – kod 0" "$code" 0 "$out"
}
rv3_setup_end() { rm -rf "$RV3_SS" "$RV3_SR" "$RV3_CONF"; }

section "REV-49: --ssh-key-only bez zainstalowanego klucza – raport mówi, czy logowanie hasłem jest wyłączone"
if rv3_setup_begin; then
  out="$(rv3s setup 1 --no-ssh-acl --ssh-key-only)"; code=$?
  expect_code "setup --ssh-key-only: kod 0" "$code" 0 "$out"
  grep -q '^PasswordAuthentication no' "$RV3_DROPIN" 2>/dev/null && pass "setup --ssh-key-only: logowanie hasłem wyłączone" \
    || fail "setup --ssh-key-only: brak PasswordAuthentication no" "$(cat "$RV3_DROPIN" 2>&1)"
  # ~/.ssh is a link: the key is not installed (step_ssh_key refuses), the sshd file stays as it was.
  mkdir -p "$RV3_HOME/.ssh"
  mv "$RV3_HOME/.ssh" "$RV3_HOME/ssh-prawdziwy" && ln -s ssh-prawdziwy "$RV3_HOME/.ssh"
  out="$(rv3s setup 1 --no-ssh-acl --ssh-key-only)"; code=$?
  expect_code "setup --ssh-key-only, klucz nie zainstalowany: kod 1" "$code" 1 "$out"
  expect "setup --ssh-key-only, klucz nie zainstalowany: logowanie hasłem nadal wyłączone – wprost" "$out" \
    "--ssh-key-only: klucza aplikacji nie udało się zainstalować." \
    "ustawienia sshd bez zmian, logowanie hasłem pozostaje wyłączone (SSH wyłącznie z kluczem: włączone)"
  expect_not "setup --ssh-key-only, klucz nie zainstalowany: nie twierdzi, że logowanie hasłem działa" "$out" \
    "logowanie hasłem zostaje włączone"
  grep -q '^PasswordAuthentication no' "$RV3_DROPIN" && pass "setup --ssh-key-only, klucz nie zainstalowany: plik sshd bez zmian" \
    || fail "setup --ssh-key-only, klucz nie zainstalowany: zmieniono plik sshd" "$(cat "$RV3_DROPIN" 2>&1)"
  rm -f "$RV3_HOME/.ssh" && mv "$RV3_HOME/ssh-prawdziwy" "$RV3_HOME/.ssh"
  # Without --pubkey (a script saved without the app's key, run with --ssh-key-only): the same.
  rv3s setup-script --no-key > "$RV3/bez-klucza.sh"
  out="$(ctlpw exec "/bin/bash $RV3/bez-klucza.sh --no-guide --no-ssh-acl --ssh-key-only" 1 --root)"; code=$?
  expect_code "skrypt --ssh-key-only bez klucza: kod 1" "$code" 1 "$out"
  expect "skrypt --ssh-key-only bez klucza: logowanie hasłem nadal wyłączone – wprost" "$out" \
    "--ssh-key-only wymaga podania klucza (--pubkey)." \
    "ustawienia sshd bez zmian, logowanie hasłem pozostaje wyłączone (SSH wyłącznie z kluczem: włączone)"
  expect_not "skrypt --ssh-key-only bez klucza: nie twierdzi, że logowanie hasłem działa" "$out" \
    "logowanie hasłem zostaje włączone"
  grep -q '^PasswordAuthentication no' "$RV3_DROPIN" && pass "skrypt --ssh-key-only bez klucza: plik sshd bez zmian" \
    || fail "skrypt --ssh-key-only bez klucza: zmieniono plik sshd" "$(cat "$RV3_DROPIN" 2>&1)"
  # Password login on again: then both reports say it stays on.
  out="$(rv3s setup 1 --no-ssh-acl --no-ssh-key-only)"; code=$?
  expect_code "setup --no-ssh-key-only: kod 0" "$code" 0 "$out"
  out="$(ctlpw exec "/bin/bash $RV3/bez-klucza.sh --no-guide --no-ssh-acl --ssh-key-only" 1 --root)"; code=$?
  expect "skrypt --ssh-key-only bez klucza, logowanie hasłem włączone: tak w raporcie" "$out" \
    "--ssh-key-only wymaga podania klucza (--pubkey)." \
    "logowanie hasłem zostaje włączone, inaczej utracisz dostęp (SSH wyłącznie z kluczem: wyłączone)"
  expect_not "skrypt --ssh-key-only bez klucza, logowanie hasłem włączone: nie „pozostaje wyłączone”" "$out" \
    "pozostaje wyłączone"
  mv "$RV3_HOME/.ssh" "$RV3_HOME/ssh-prawdziwy" && ln -s ssh-prawdziwy "$RV3_HOME/.ssh"
  out="$(rv3s setup 1 --no-ssh-acl --ssh-key-only)"; code=$?
  expect "setup --ssh-key-only, klucz nie zainstalowany, logowanie hasłem włączone: tak w raporcie" "$out" \
    "--ssh-key-only: klucza aplikacji nie udało się zainstalować." \
    "logowanie hasłem zostaje włączone, inaczej utracisz dostęp (SSH wyłącznie z kluczem: wyłączone)"
  grep -Eq '^(PasswordAuthentication|KbdInteractiveAuthentication)' "$RV3_DROPIN" \
    && fail "setup --ssh-key-only, klucz nie zainstalowany: wyłączono logowanie hasłem" "$(cat "$RV3_DROPIN")" \
    || pass "setup --ssh-key-only, klucz nie zainstalowany: logowanie hasłem nadal włączone"
fi
rv3_setup_end

section "REV-50: --display-sleep 0 to „bez usypiania ekranu”, nie „po 0 min”"
if rv3_setup_begin; then
  rv3s setup-script > "$RV3/standalone.sh"
  out="$(ctlpw exec "/bin/bash $RV3/standalone.sh --no-guide --no-ssh-acl --display-sleep 0" 1 --root)"; code=$?
  expect_code "--display-sleep 0: kod 0" "$code" 0 "$out"
  expect "--display-sleep 0: raport" "$out" "✚ Zasilanie: " "bez usypiania ekranu."
  expect_not "--display-sleep 0: nie „po 0 min”" "$out" "po 0 min"
  grep -qx 'displaysleep 0' "$RV3_SS/pmset" && pass "--display-sleep 0: pmset displaysleep 0" \
    || fail "--display-sleep 0: stan pmset" "$(cat "$RV3_SS/pmset")"
  out="$(ctlpw exec "/bin/bash $RV3/standalone.sh --no-guide --no-ssh-acl --display-sleep 10" 1 --root)"; code=$?
  expect "--display-sleep 10: raport" "$out" "✚ Zasilanie: " "uśpienie ekranu po 10 min."
  out="$(ctl exec "/bin/bash $RV3/standalone.sh --help" 1)"
  expect "pomoc skryptu: --display-sleep 0 – nigdy" "$out" "uśpienie ekranu po MIN minutach (0 – nigdy)"
  out="$(ctl setup --help)"
  expect "pomoc cmcrctl setup: --display-sleep 0 – nigdy" "$out" "uśpienie ekranu po MIN minutach (0 – nigdy)"
fi
rv3_setup_end

rm -rf "$RV3"
