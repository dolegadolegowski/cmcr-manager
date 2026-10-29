# shellcheck shell=bash
# Review fixes of cmcrctl (AUDIT REV, group R4-cli): `rename KOMP` – the names other Macs on the list have (the same
# rule as the app's „Zmień nazwy komputerów”), the advice for names moved round three or more Macs, and --update-list
# in the advice for renames in steps. Only --dry-run: the addresses are .local names, and no test may connect to one;
# the checks run before the dry-run ends, the same for a real rename. Between the steps the suite writes to the list
# what --update-list writes there.
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $ME $PORT come from there). Own config folder, so later suites
# see the original configuration.

R4="$WORK/cfg-rev-r4"
mkdir -p "$R4"
cp "$WORK/config/settings.json" "$R4/"
r4() { CMCR_CONFIG_DIR="$R4" "$CTL" "$@" 2>&1; }
# r4_hosts "ID NAME ADDRESS"… – the suite's host list.
r4_hosts() {
  python3 - "$R4/hosts.json" "$ME" "$PORT" "$@" <<'PY'
import json, sys
path, me, port, entries = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:]
hosts = []
for e in entries:
    i, name, address = e.split()
    hosts.append({"id": i, "name": name, "address": address, "user": me, "port": port})
json.dump(hosts, open(path, "w"))
PY
}
# r4_renamed ID NAME – what `rename … --update-list` writes after renaming that Mac to NAME.
r4_renamed() {
  python3 - "$R4/hosts.json" "$1" "$2" <<'PY'
import json, sys
path, i, name = sys.argv[1], sys.argv[2], sys.argv[3]
hosts = json.load(open(path))
for h in hosts:
    if h["id"] == i: h["name"] = name; h["address"] = name + ".local"
json.dump(hosts, open(path, "w"))
PY
}
# r4_lines NAME OUTPUT NEEDLE COUNT – NEEDLE is in exactly COUNT lines.
r4_lines() {
  local n
  n="$(printf '%s\n' "$2" | grep -cF -- "$3")"
  expect_code "$1" "$n" "$4" "$2"
}
A=d1111111-1111-1111-1111-111111111111
B=d2222222-2222-2222-2222-222222222222
C=d3333333-3333-3333-3333-333333333333

section "REV R4 cmcrctl – rename: nazwa z listy komputera z adresem IP, ta sama reguła co w aplikacji (AUDIT REV-58)"
r4_hosts "$A imac03 192.0.2.13" "$B imac05 imac05.local" "$C imac06 imac06.local"
out="$(r4 rename imac05 --name imac03 --dry-run)"; code=$?
expect_code "rename, nazwa z listy innego komputera (adres IP): kod 2" "$code" 2 "$out"
expect "rename, nazwa z listy innego komputera: komunikat" "$out" \
  "imac05: „imac03” → imac03.local – ten adres ma już imac03 z listy komputerów" "nic nie zostało zmienione"
out="$(r4 rename imac05 --name IMAC06 --dry-run)"; code=$?
expect_code "rename, adres .local innego komputera (wielkość liter): kod 2" "$code" 2 "$out"
expect "rename, adres .local innego komputera: komunikat" "$out" "ten adres ma już imac06 z listy komputerów"
out="$(r4 rename imac05 --name imac04 --dry-run)"; code=$?
expect_code "rename, wolna nazwa: kod 0" "$code" 0 "$out"
