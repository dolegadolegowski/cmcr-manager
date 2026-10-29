# shellcheck shell=bash
# Review fixes of `cmcrctl rename KOMP` (AUDIT REV, group R5-rename): a new name repeated among the renamed Macs is
# reported before the order of a renumbering or a swap, and the advice for names that go round gives the whole order.
# Only --dry-run: the addresses are .local names, and no test may connect to one; the checks run before the dry-run
# ends, the same for a real rename. Between the steps the suite writes to the list what --update-list writes there.
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $ME $PORT come from there). Own config folder, so later suites
# see the original configuration.

R5="$WORK/cfg-rev-r5-rename"
mkdir -p "$R5"
cp "$WORK/config/settings.json" "$R5/"
r5() { CMCR_CONFIG_DIR="$R5" "$CTL" "$@" </dev/null 2>&1; }
# r5_hosts "ID NAME ADDRESS"… – the suite's host list.
r5_hosts() {
  python3 - "$R5/hosts.json" "$ME" "$PORT" "$@" <<'PY'
import json, sys
path, me, port, entries = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:]
hosts = []
for e in entries:
    i, name, address = e.split()
    hosts.append({"id": i, "name": name, "address": address, "user": me, "port": port})
json.dump(hosts, open(path, "w"))
PY
}
A=e1111111-1111-1111-1111-111111111111
B=e2222222-2222-2222-2222-222222222222
C=e3333333-3333-3333-3333-333333333333
D=e4444444-4444-4444-4444-444444444444

section "REV R5 cmcrctl – rename: nazwa powtarzająca się wśród zmienianych komputerów przed radą o kolejności (AUDIT REV-62)"
# A third Mac whose list name gives the same .local name (imąc02 → imac02) as one Mac of a swap: both are reported as
# repeated – as in the app's „Zmień nazwy komputerów” – and none gets advice about the swap of two other Macs.
r5_hosts "$A imac02 imac01.local" "$B imac01 imac02.local" "$C imąc02 imac03.local"
out="$(r5 rename @1,@2,@3 --dry-run)"; code=$?
expect_code "rename, zamiana i powtórzona nazwa: kod 2" "$code" 2 "$out"
expect "rename, zamiana i powtórzona nazwa: oba komputery z tą samą nazwą" "$out" \
  "imac02: „imac02” → imac02.local – ten adres powtarza się" \
  "imąc02: „imąc02” → imac02.local – ten adres powtarza się" "nic nie zostało zmienione"
expect_not "rename, zamiana i powtórzona nazwa: bez rady o zamianie dwóch innych komputerów" "$out" \
  "Komputery imac01 i imac02 zamieniają się nazwami"
expect_not "rename, zamiana i powtórzona nazwa: komputer z powtórzoną nazwą bez rady o kolejności" "$out" \
  "imąc02: „imąc02” → imac02.local – ten adres ma teraz"
# A renumbering (imac05 → imac06 → imac07) with a third Mac that also wants imac06: the advice „najpierw imac07,
# potem imac06” would rename imac07 and then stop at the repeated name.
r5_hosts "$A imac06 imac05.local" "$B imac07 imac06.local" "$C IMAC06 imac09.local"
out="$(r5 rename @1,@2,@3 --dry-run)"; code=$?
expect_code "rename, przenumerowanie i powtórzona nazwa: kod 2" "$code" 2 "$out"
expect "rename, przenumerowanie i powtórzona nazwa: oba komputery z tą samą nazwą" "$out" \
  "imac06: „imac06” → imac06.local – ten adres powtarza się" \
  "IMAC06: „IMAC06” → IMAC06.local – ten adres powtarza się" \
  "imac07: „imac07” → imac07.local"
expect_not "rename, przenumerowanie i powtórzona nazwa: bez rady, której nie da się dokończyć" "$out" "najpierw imac07"
