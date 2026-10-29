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

rm -rf "$RV3"
