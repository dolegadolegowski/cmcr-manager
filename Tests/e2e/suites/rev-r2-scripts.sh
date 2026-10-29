# Review of the audit fixes, round 2, group R2-scripts: uploading into a folder of a deleted account (numeric
# owner) (AUDIT REV-39). Sourced by Tests/e2e/run.sh (helpers: section, pass, fail, expect, expect_not,
# expect_code, ctl, ctlpw, fakelog, clear_fakelog). Everything runs against folders inside $WORK and the fakes in
# fakes.sh (the setup script's system files under $WORK/setup-root, simulated system state in $WORK/setup-sys).

RV2="$WORK/rev-r2-scripts"
mkdir -p "$RV2"

section "REV-39: wysyłanie do folderu usuniętego konta (właściciel jako numer)"
# The remote browser sends the owner as `stat %Su` shows it: a bare uid when the account no longer exists.
RV2_UID=59999
while id -u "$RV2_UID" >/dev/null 2>&1; do RV2_UID=$((RV2_UID + 1)); done
mkdir -p "$RV2/send" "$WORK/remote/rev-r2-push"
echo rev-r2 > "$RV2/send/rev-r2-plik.txt"
clear_fakelog
out="$(ctlpw _builder push 1 "$WORK/remote/rev-r2-push" "$RV2_UID:staff" "" "$RV2/send/rev-r2-plik.txt" --root)"; code=$?
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

rm -rf "$RV2"
