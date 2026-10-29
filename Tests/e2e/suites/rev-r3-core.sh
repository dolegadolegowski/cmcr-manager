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

rm -rf "$RV3"
