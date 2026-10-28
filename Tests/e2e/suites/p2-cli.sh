# shellcheck shell=bash
# P2 fixes of cmcrctl (AUDIT P2, package cli): per-command help, confirmations, host lists, logging and texts.
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT come from there). Own config folders,
# so later suites see the original configuration.

P2="$WORK/cfg-p2cli"
mkdir -p "$P2"
cp "$WORK/config/settings.json" "$P2/"
cat > "$P2/hosts.json" <<EOF
[
 {"id":"21111111-1111-1111-1111-111111111111","name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"22222222-2222-2222-2222-222222222222","name":"imac02","address":"127.0.0.1","user":"$ME","port":$PORT}
]
EOF
p2() { CMCR_CONFIG_DIR="$P2" "$CTL" "$@" 2>&1; }
p2pw() { CMCR_CONFIG_DIR="$P2" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
# At a terminal (stdin, stdout and stderr on a pty), answering $P2_ANSWER after the question.
# (Typed after the question: what script(1) passes on before the program reads is lost.)
p2_tty() {
  (sleep 1; printf '%s\n' "${P2_ANSWER:-n}"; sleep 2) | CMCR_CONFIG_DIR="$P2" CMCR_PASSWORD="$PASSWORD" \
    script -q /dev/null "$CTL" "$@" 2>&1
}

section "P2 cmcrctl – przygotowanie"
out="$(p2 list)"
expect "p2: lista komputerów" "$out" "imac01" "imac02"
# Screen preview of the SSH account's own session, with nobody else to notify (see screens.sh).
python3 - "$P2/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s.update(observeAllowedUsers="", observeOnlyStandardAccounts=False, notifyOnObserve=True, screenshotMaxSize=640)
json.dump(s, open(p, "w"))
PY
rm -f "$WORK/console_user" "$WORK/screen_variant"

section "P2 cmcrctl – liczebniki w podsumowaniach (AUDIT TXT-22)"
out="$(p2pw screen-watch 1 "$WORK/p2-watch" --frames 3 --interval 2)"; code=$?
expect_code "screen-watch: kod 0" "$code" 0 "$out"
expect "screen-watch: „3 cykle, 1 nowy obraz”" "$out" "Zakończono: 3 cykle, 1 nowy obraz."
