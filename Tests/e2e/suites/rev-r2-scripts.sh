# Review of the audit fixes, round 2, group R2-scripts: the remote file scripts and the one-time setup script
# (AUDIT REV-39 …). Sourced by Tests/e2e/run.sh (helpers: section, pass, fail, expect, expect_not, expect_code, ctl,
# ctlpw, fakelog, clear_fakelog). Everything runs against folders inside $WORK and the fakes in fakes.sh (the setup
# script's system files under $WORK/setup-root, simulated system state in $WORK/setup-sys).

RV2="$WORK/rev-r2-scripts"
mkdir -p "$RV2"

section "REV-39: wysyłanie do folderu usuniętego konta (właściciel jako numer)"
# The remote browser sends the owner as `stat %Su` shows it: a bare uid when the account no longer exists.
RV2_UID=59999
while id -u "$RV2_UID" >/dev/null 2>&1; do RV2_UID=$((RV2_UID + 1)); done
mkdir -p "$RV2/send" "$WORK/remote/rev-r2-push"
echo rev-r2 > "$RV2/send/rev-r2-plik.txt"
# The folder belongs to that uid (fakes.sh: stat.uid): only then is a uid without an account accepted (AUDIT REV-48).
printf '%s %s\n' "$RV2_UID" "$(cd "$WORK/remote/rev-r2-push" && pwd -P)" > "$WORK/stat.uid"
clear_fakelog
out="$(ctlpw _builder push 1 "$WORK/remote/rev-r2-push" "$RV2_UID:staff" "" "$RV2/send/rev-r2-plik.txt" --root)"; code=$?
rm -f "$WORK/stat.uid"
expect_code "push: właściciel $RV2_UID:staff – kod 0" "$code" 0 "$out"
expect_not "push: numer konta nie jest odrzucany jako nieistniejące konto" "$out" "nie istnieje"
[ -f "$WORK/remote/rev-r2-push/rev-r2-plik.txt" ] && pass "push: numer konta – plik zapisany" \
  || fail "push: numer konta – brak pliku" "$out"
expect "push: numer konta – chown dostał numer" "$(fakelog)" "chown -R $RV2_UID:staff"
# A name that does not exist (a typo in „Inny…”) is still refused before anything is written (AUDIT PLI-08).
out="$(ctlpw _builder push 1 "$WORK/remote/rev-r2-push" "rev-r2-brak-konta:staff" "" "$RV2/send/rev-r2-plik.txt" --root)"; code=$?
expect_code "push: nieistniejąca nazwa konta – kod 2" "$code" 2 "$out"
expect "push: nieistniejąca nazwa konta – komunikat" "$out" "„rev-r2-brak-konta” nie istnieje"
rm -rf "$WORK/remote/rev-r2-push"

# rv2_setup_begin – a configured iMac in $WORK/setup-root (as in suites/p2-scripts.sh); fails when the redirection
# is off. Each section ends with rv2_setup_end: later suites start from a fresh state.
RV2_SR="$WORK/setup-root"
RV2_SS="$WORK/setup-sys"
RV2_CONF="$WORK/config-rev-r2-setup"
RV2_HOME="$RV2_SR/Users/$ME"
RV2_DROPIN="$RV2_SR/etc/ssh/sshd_config.d/050-cmcr-manager.conf"
rv2s() { CMCR_CONFIG_DIR="$RV2_CONF" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
rv2_setup_begin() {
  mkdir -p "$RV2_HOME/Public" "$RV2_SR/etc/ssh/sshd_config.d" "$RV2_SR/private/etc/sudoers.d" \
    "$RV2_SR/Library/Preferences" "$RV2_SS" "$RV2_CONF"
  chmod 755 "$RV2_HOME"
  printf '# test\nInclude /etc/ssh/sshd_config.d/*\nPasswordAuthentication yes\n' > "$RV2_SR/etc/ssh/sshd_config"
  printf 'root ALL = (ALL) ALL\n#includedir /private/etc/sudoers.d\n' > "$RV2_SR/etc/sudoers"
  printf 'womp 1\nsleep 1\ntcpkeepalive 1\n' > "$RV2_SS/pmset"
  echo false > "$RV2_SS/screen-preflight"
  echo "FileVault is Off." > "$RV2_SS/filevault"
  cp "$WORK/config/hosts.json" "$RV2_CONF/hosts.json"
  cat > "$RV2_CONF/settings.json" <<EOF
{"identityFile":"$WORK/client","extraSSHOptions":"UserKnownHostsFile=$WORK/known_hosts",
 "sharedFolder":"/Users/{student}/Public/cmcr","localFolder":"$WORK/local","studentUser":"$ME","connectTimeout":3}
EOF
  out="$(rv2s setup 1 --no-ssh-acl)"; code=$?
  if ! contains "" "$out" "(TEST: pliki systemowe przekierowane do $RV2_SR)"; then
    fail "setup: przekierowanie ścieżek nieaktywne – pominięto testy skryptu konfiguracyjnego" "$out"
    return 1
  fi
  expect_code "setup: przygotowanie – kod 0" "$code" 0 "$out"
}
rv2_setup_end() { rm -rf "$RV2_SS" "$RV2_SR" "$RV2_CONF"; }

section "REV-40: wyłączenie „SSH wyłącznie z kluczem” razem z keepalive przywraca logowanie hasłem"
if rv2_setup_begin; then
  out="$(rv2s setup 1 --no-ssh-acl --ssh-key-only)"; code=$?
  expect_code "setup --ssh-key-only: kod 0" "$code" 0 "$out"
  grep -q '^PasswordAuthentication no' "$RV2_DROPIN" 2>/dev/null && pass "setup --ssh-key-only: logowanie hasłem wyłączone" \
    || fail "setup --ssh-key-only: brak PasswordAuthentication no" "$(cat "$RV2_DROPIN" 2>&1)"
  # Both toggles off in the app (cmcrctl: --no-ssh-tuning --no-ssh-key-only): the script gets --no-ssh-tuning only.
  out="$(rv2s setup 1 --no-ssh-acl --no-ssh-tuning --no-ssh-key-only --verify)"; code=$?
  expect "setup --verify bez keepalive i bez klucza: plan włączenia logowania hasłem" "$out" \
    "Wymaga zmiany: zapisać ustawienia sshd (" "SSH wyłącznie z kluczem: wyłączone – logowanie hasłem znów zadziała"
  expect_not "setup --verify bez keepalive i bez klucza: nie „bez zmian”" "$out" "Ustawienia sshd bez zmian"
  grep -q '^PasswordAuthentication no' "$RV2_DROPIN" && pass "setup --verify: plik sshd nie zmieniony" \
    || fail "setup --verify: zmieniono plik sshd" "$(cat "$RV2_DROPIN" 2>&1)"
  # sshd -t refuses the new file: the old one comes back and the step fails.
  : > "$RV2_SS/sshd-t-fails"
  out="$(rv2s setup 1 --no-ssh-acl --no-ssh-tuning --no-ssh-key-only)"; code=$?
  rm -f "$RV2_SS/sshd-t-fails"
  expect_code "setup bez keepalive i bez klucza, sshd -t odmawia: kod 1" "$code" 1 "$out"
  expect "setup bez keepalive i bez klucza, sshd -t odmawia: przywrócono" "$out" "sshd -t odrzucił konfigurację"
  grep -q '^PasswordAuthentication no' "$RV2_DROPIN" && pass "setup: po odmowie sshd -t poprzedni plik wrócił" \
    || fail "setup: po odmowie sshd -t plik zmieniony" "$(cat "$RV2_DROPIN" 2>&1)"
  out="$(rv2s setup 1 --no-ssh-acl --no-ssh-tuning --no-ssh-key-only)"; code=$?
  expect_code "setup bez keepalive i bez klucza: kod 0" "$code" 0 "$out"
  expect "setup bez keepalive i bez klucza: zmiana nazwana wprost" "$out" \
    "✚ Zapisano $RV2_DROPIN (" "SSH wyłącznie z kluczem: wyłączone – logowanie hasłem znów działa" "keepalive bez zmian"
  grep -Eq '^(PasswordAuthentication|KbdInteractiveAuthentication)' "$RV2_DROPIN" \
    && fail "setup bez keepalive i bez klucza: logowanie hasłem nadal wyłączone" "$(cat "$RV2_DROPIN")" \
    || pass "setup bez keepalive i bez klucza: logowanie hasłem włączone"
  grep -q '^ClientAliveInterval' "$RV2_DROPIN" && pass "setup bez keepalive: keepalive zostawiony bez zmian" \
    || fail "setup bez keepalive: usunięto keepalive" "$(cat "$RV2_DROPIN" 2>&1)"
  out="$(rv2s setup 1 --no-ssh-acl --no-ssh-tuning --no-ssh-key-only)"; code=$?
  expect "setup bez keepalive i bez klucza, drugi raz: bez zmian" "$out" \
    "Ustawienia sshd bez zmian (SSH wyłącznie z kluczem: wyłączone)"
fi
rv2_setup_end

section "REV-41: --display-sleep z zerem na początku nie jest błędem pmset"
if rv2_setup_begin; then
  rv2s setup-script > "$RV2/standalone.sh"
  # pmset keeps the minutes as a number (fakes.sh: „05” is stored and shown as 5, like the real pmset).
  out="$(ctlpw exec "/bin/bash $RV2/standalone.sh --no-guide --no-ssh-acl --display-sleep 05" 1 --root)"; code=$?
  expect_code "--display-sleep 05: kod 0" "$code" 0 "$out"
  expect_not "--display-sleep 05: bez błędu pmset" "$out" "pmset nie zmienił"
  expect "--display-sleep 05: ustawiono 5 minut" "$out" "✚ Zasilanie: " "uśpienie ekranu po 5 min."
  grep -qx 'displaysleep 5' "$RV2_SS/pmset" && pass "--display-sleep 05: pmset displaysleep 5" \
    || fail "--display-sleep 05: stan pmset" "$(cat "$RV2_SS/pmset")"
  out="$(ctlpw exec "/bin/bash $RV2/standalone.sh --no-guide --no-ssh-acl --display-sleep 005" 1 --root)"; code=$?
  expect_code "--display-sleep 005 drugi raz: kod 0" "$code" 0 "$out"
  expect "--display-sleep 005 drugi raz: bez zmian" "$out" "✔ Zasilanie: " "uśpienie ekranu po 5 min."
  expect_not "--display-sleep 005 drugi raz: nie zmienia ponownie" "$out" "✚ Zasilanie: "
  out="$(ctlpw exec "/bin/bash $RV2/standalone.sh --no-guide --no-ssh-acl --display-sleep 00" 1 --root)"; code=$?
  expect_code "--display-sleep 00: kod 0" "$code" 0 "$out"
  expect "--display-sleep 00: 0 minut" "$out" "uśpienie ekranu po 0 min."
  grep -qx 'displaysleep 0' "$RV2_SS/pmset" && pass "--display-sleep 00: pmset displaysleep 0" \
    || fail "--display-sleep 00: stan pmset" "$(cat "$RV2_SS/pmset")"
fi
rv2_setup_end

rm -rf "$RV2"
