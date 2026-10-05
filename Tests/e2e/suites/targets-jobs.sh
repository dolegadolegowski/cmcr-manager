# shellcheck shell=bash
# U7 – host groups in hosts.json stay compatible with every reader (app and cmcrctl).
# Sourced by Tests/e2e/run.sh (helpers: section, expect, expect_not, expect_code, ctl, ctlpw; $WORK $PORT $ME).

section "Grupy komputerów (hosts.json z polem groups)"
cp "$WORK/config/hosts.json" "$WORK/hosts.u7-backup.json"
cat > "$WORK/config/hosts.json" <<EOF
[
 {"id":"11111111-1111-1111-1111-111111111111","name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT,
  "groups":["Rząd 1","Matura"]},
 {"id":"99999999-9999-9999-9999-999999999999","name":"imac99","address":"imac99.cmcr-e2e.invalid","user":"imac99",
  "port":22,"groups":[]}
]
EOF
out="$(ctl list)"
expect "list: lista z grupami wczytana" "$out" "imac01" "imac99"
out="$(ctl exec 'echo "grupy=ok"' 1)"; code=$?
expect "exec: komputer z grupami działa" "$out" "grupy=ok"
expect_code "exec: kod 0 dla komputera z grupami" "$code" 0 "$out"
out="$(ctl status 2)"; code=$?
expect_code "status: niedostępny komputer z pustą listą grup – kod 1" "$code" 1 "$out"

# A list written by an older version (no "groups" key at all) must still load.
cat > "$WORK/config/hosts.json" <<EOF
[{"name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT}]
EOF
out="$(ctl exec 'echo "stary-format=ok"' 1)"
expect "exec: stary hosts.json bez grup" "$out" "stary-format=ok"
cp "$WORK/hosts.u7-backup.json" "$WORK/config/hosts.json"
