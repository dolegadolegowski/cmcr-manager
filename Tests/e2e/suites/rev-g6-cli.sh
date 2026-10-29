# shellcheck shell=bash
# Review fixes of cmcrctl (AUDIT REV, group G6-cli): rename-computer, trust and readiness. Sourced by
# Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT come from there). Own config folders, so later suites
# see the original configuration.

# The Macs of this suite have .local addresses that are never resolved or connected to: every ssh goes to the test
# sshd through ProxyCommand (nc 127.0.0.1), while the keys are checked under the .local names in the suite's own file.
G6="$WORK/cfg-rev-g6"
G6_KNOWN="$WORK/rev-g6-known_hosts"
mkdir -p "$G6"
python3 - "$WORK/config/settings.json" "$G6/settings.json" "$G6_KNOWN" "$PORT" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["extraSSHOptions"] = "UserKnownHostsFile=%s\nProxyCommand=/usr/bin/nc 127.0.0.1 %s" % (sys.argv[3], sys.argv[4])
s.update(observeAllowedUsers="", observeOnlyStandardAccounts=False)
json.dump(s, open(sys.argv[2], "w"))
PY
cat > "$G6/hosts.json" <<EOF
[
 {"id":"61111111-1111-1111-1111-111111111111","name":"imac03","address":"cmcr-e2e-g6-03.local","user":"$ME","port":$PORT},
 {"id":"62222222-2222-2222-2222-222222222222","name":"imac04","address":"cmcr-e2e-g6-04.local","user":"$ME","port":$PORT}
]
EOF
G6_KEY="$(cut -d' ' -f1-2 "$WORK/hostkey.pub")"
G6_KEY_B64="$(cut -d' ' -f2 "$WORK/hostkey.pub")"
printf '[cmcr-e2e-g6-03.local]:%s %s\n[cmcr-e2e-g6-04.local]:%s %s\n' "$PORT" "$G6_KEY" "$PORT" "$G6_KEY" > "$G6_KNOWN"
g6() { CMCR_CONFIG_DIR="$G6" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
g6_known() { ssh-keygen -F "[$1]:$PORT" -f "$G6_KNOWN" 2>/dev/null | grep -v '^#'; }

section "REV cmcrctl – przygotowanie (adresy .local przez ProxyCommand)"
out="$(g6 status 3 </dev/null)"; code=$?
expect_code "status przez ProxyCommand: kod 0" "$code" 0 "$out"
expect "status przez ProxyCommand: komputer online" "$out" "● imac03"
cp "$G6/hosts.json" "$WORK/rev-g6-hosts.orig"

section "REV cmcrctl – rename-computer: nazwa innego komputera z listy (AUDIT REV-33)"
clear_fakelog
for name in imac04 IMAC04 cmcr-e2e-g6-04 "cmcr e2e g6 04"; do
  out="$(g6 rename-computer 3 --name "$name" --update-list --yes </dev/null)"; code=$?
  expect_code "rename-computer --name „$name”: kod 2" "$code" 2 "$out"
  expect "rename-computer --name „$name”: wskazany komputer z listy" "$out" "ma już imac04" "nic nie zostało zmienione"
done
out="$(g6 rename-computer 3 --name imac04 --dry-run </dev/null)"; code=$?
expect_code "rename-computer --name imac04 --dry-run: kod 2" "$code" 2 "$out"
expect_not "rename-computer: nazwa innego komputera – scutil nie uruchomiony" "$(fakelog)" "scutil"
cmp -s "$G6/hosts.json" "$WORK/rev-g6-hosts.orig" && pass "rename-computer: nazwa innego komputera – lista bez zmian" \
  || fail "rename-computer: zmieniono listę mimo konfliktu" "$(cat "$G6/hosts.json")"
# Each Mac keeps its own name: not a conflict.
out="$(g6 rename-computer all --dry-run </dev/null)"; code=$?
expect_code "rename-computer all --dry-run (nazwy z listy): kod 0" "$code" 0 "$out"
expect "rename-computer all --dry-run: podgląd" "$out" "imac03: „imac03” → imac03.local" "imac04: „imac04” → imac04.local"
out="$(g6 rename-computer 3 --name imac05 --dry-run </dev/null)"; code=$?
expect_code "rename-computer --name wolna nazwa --dry-run: kod 0" "$code" 0 "$out"
# Two Macs renamed to the same .local name (the list names differ only in punctuation).
G6D="$WORK/cfg-rev-g6-dup"
mkdir -p "$G6D"
cp "$G6/settings.json" "$G6D/"
cat > "$G6D/hosts.json" <<EOF
[
 {"id":"64111111-1111-1111-1111-111111111111","name":"imac-05","address":"cmcr-e2e-g6-05.local","user":"$ME","port":$PORT},
 {"id":"64222222-2222-2222-2222-222222222222","name":"imac 05","address":"cmcr-e2e-g6-06.local","user":"$ME","port":$PORT}
]
EOF
out="$(CMCR_CONFIG_DIR="$G6D" "$CTL" rename-computer all --update-list --yes </dev/null 2>&1)"; code=$?
expect_code "rename-computer: ten sam adres dla dwóch komputerów – kod 2" "$code" 2 "$out"
expect "rename-computer: ten sam adres dla dwóch komputerów – komunikat" "$out" "imac-05.local – ten adres powtarza się"
expect_not "rename-computer: ten sam adres dla dwóch komputerów – scutil nie uruchomiony" "$(fakelog)" "scutil"

section "REV cmcrctl – rename-computer --update-list zachowuje zaufany klucz (AUDIT REV-01)"
cp "$WORK/rev-g6-hosts.orig" "$G6/hosts.json"
printf '[cmcr-e2e-g6-03.local]:%s %s\n[cmcr-e2e-g6-04.local]:%s %s\n' "$PORT" "$G6_KEY" "$PORT" "$G6_KEY" > "$G6_KNOWN"
clear_fakelog
out="$(g6 rename-computer 3 --name cmcr-e2e-g6-33 --update-list --yes </dev/null)"; code=$?
expect_code "rename-computer --update-list: kod 0" "$code" 0 "$out"
expect "rename-computer --update-list: nowy adres na liście" "$out" "Zaktualizowano listę komputerów: cmcr-e2e-g6-33 → cmcr-e2e-g6-33.local"
expect "rename-computer --update-list: klucz przeniesiony" "$out" "Zaufany klucz SSH obowiązuje także pod nowym adresem cmcr-e2e-g6-33.local"
expect "rename-computer --update-list: scutil" "$(fakelog)" "scutil --set LocalHostName cmcr-e2e-g6-33"
contains "" "$(g6_known cmcr-e2e-g6-33.local)" "$G6_KEY_B64" && pass "rename-computer: klucz zaufany pod nowym adresem" \
  || fail "rename-computer: brak zaufanego klucza pod nowym adresem" "$(cat "$G6_KNOWN")"
out="$(g6 status 33 </dev/null)"; code=$?
expect_code "status po zmianie nazwy: kod 0" "$code" 0 "$out"
expect "status po zmianie nazwy: połączenie bez ponownego zaufania" "$out" "● cmcr-e2e-g6-33"
expect_not "status po zmianie nazwy: klucz nie jest „nowy”" "$out" "nie jest jeszcze zaufany"

rm -f "$WORK/rev-g6-hosts.orig"
