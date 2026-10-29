# shellcheck shell=bash
# Review fixes of `cmcrctl rename KOMP` (AUDIT REV, group R6-rename): no order of a renumbering or a swap is given when
# it runs through a Mac whose new name is wrong whatever the order (repeated, taken by another Mac on the list,
# invalid) – followed, it would stop at that Mac, or leave a Mac of a swap with the temporary name. Only --dry-run: the
# addresses are .local names, and no test may connect to one; the checks run before the dry-run ends, the same for a
# real rename. Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $ME $PORT come from there). Own config folder, so
# later suites see the original configuration.

R6="$WORK/cfg-rev-r6-rename"
mkdir -p "$R6"
cp "$WORK/config/settings.json" "$R6/"
r6() { CMCR_CONFIG_DIR="$R6" "$CTL" "$@" </dev/null 2>&1; }
# r6_hosts "ID NAME ADDRESS"… – the suite's host list.
r6_hosts() {
  python3 - "$R6/hosts.json" "$ME" "$PORT" "$@" <<'PY'
import json, sys
path, me, port, entries = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:]
hosts = []
for e in entries:
    i, name, address = e.split()
    hosts.append({"id": i, "name": name, "address": address, "user": me, "port": port})
json.dump(hosts, open(path, "w"))
PY
}
A=f1111111-1111-1111-1111-111111111111
B=f2222222-2222-2222-2222-222222222222
C=f3333333-3333-3333-3333-333333333333
D=f4444444-4444-4444-4444-444444444444
E=f5555555-5555-5555-5555-555555555555
HELD="którego nazwa też jest zmieniana (macOS nadałby wtedy jednemu z nich inny adres)."

section "REV R6 cmcrctl – rename: bez kolejności, która przechodzi przez komputer z błędną nową nazwą (AUDIT REV-64)"
# The swap of imac01 and imac02 runs through imac02, whose name repeats (imąc02 → imac02.local). The swap advice for
# imac01, followed, left one of the two Macs with the temporary name: its last step was refused as taken by imąc02.
r6_hosts "$A imac02 imac01.local" "$B imac01 imac02.local" "$C imąc02 imac03.local"
out="$(r6 rename @1,@2,@3 --dry-run)"; code=$?
expect_code "rename, zamiana przez powtórzoną nazwę: kod 2" "$code" 2 "$out"
expect "rename, zamiana przez powtórzoną nazwę: najpierw poprawić tę nazwę, bez kolejności" "$out" \
  "imac01: „imac01” → imac01.local – ten adres ma teraz imac02 (imac01.local), $HELD Najpierw popraw nazwę imac02 (adres powtarza się) – dopiero wtedy da się podać kolejność." \
  "imac02: „imac02” → imac02.local – ten adres powtarza się" "imąc02: „imąc02” → imac02.local – ten adres powtarza się" \
  "nic nie zostało zmienione"
expect_not "rename, zamiana przez powtórzoną nazwę: bez rady o zamianie" "$out" "Przy zamianie nazw"
expect_not "rename, zamiana przez powtórzoną nazwę: bez nazwy tymczasowej" "$out" "tymczasow"

# A renumbering whose free end repeats (imac07 and IMAC07): „najpierw imac07, potem imac06” was refused at once.
r6_hosts "$A imac06 imac05.local" "$B imac07 imac06.local" "$C IMAC07 imac09.local"
out="$(r6 rename @1,@2,@3 --dry-run)"; code=$?
expect_code "rename, przenumerowanie przez powtórzoną nazwę: kod 2" "$code" 2 "$out"
expect "rename, przenumerowanie przez powtórzoną nazwę: najpierw poprawić tę nazwę" "$out" \
  "imac06: „imac06” → imac06.local – ten adres ma teraz imac07 (imac06.local), $HELD Najpierw popraw nazwę imac07 (adres powtarza się) – dopiero wtedy da się podać kolejność."
expect_not "rename, przenumerowanie przez powtórzoną nazwę: bez kolejności" "$out" "najpierw imac07"

# A renumbering whose free end another Mac on the list has (imac08 at imac07.local, not renamed here).
r6_hosts "$A imac06 imac05.local" "$B imac07 imac06.local" "$C imac08 imac07.local"
out="$(r6 rename imac06,imac07 --dry-run)"; code=$?
expect_code "rename, przenumerowanie do zajętej nazwy: kod 2" "$code" 2 "$out"
expect "rename, przenumerowanie do zajętej nazwy: najpierw poprawić tę nazwę" "$out" \
  "imac07: „imac07” → imac07.local – ten adres ma już imac08 z listy komputerów" \
  "imac06: „imac06” → imac06.local – ten adres ma teraz imac07 (imac06.local), $HELD Najpierw popraw nazwę imac07 (adres ma już imac08) – dopiero wtedy da się podać kolejność."
expect_not "rename, przenumerowanie do zajętej nazwy: bez kolejności" "$out" "najpierw imac07"

# Names in a loop of three, two of them wrong: both are named, in the order of the steps.
r6_hosts "$A imac02 imac01.local" "$B imac03 imac02.local" "$C imac01 imac03.local" "$D IMAC03 imac04.local" \
  "$E IMAC01 imac09.local"
out="$(r6 rename @1,@2,@3,@4 --dry-run)"; code=$?
expect_code "rename, w kółko przez dwie błędne nazwy: kod 2" "$code" 2 "$out"
expect "rename, w kółko przez dwie błędne nazwy: obie do poprawienia" "$out" \
  "imac02: „imac02” → imac02.local – ten adres ma teraz imac03 (imac02.local), $HELD Najpierw popraw nazwy imac01 (adres ma już IMAC01) i imac03 (adres powtarza się) – dopiero wtedy da się podać kolejność."
expect_not "rename, w kółko przez dwie błędne nazwy: bez kolejności" "$out" "zamieniają się nazwami"

# A wrong name outside the order does not hide it: the swap of imac01 and imac02 still gets its advice.
r6_hosts "$A imac02 imac01.local" "$B imac01 imac02.local" "$C imac05 imac03.local" "$D IMAC05 imac04.local"
out="$(r6 rename @1,@2,@3,@4 --dry-run)"; code=$?
expect_code "rename, zamiana obok powtórzonej nazwy: kod 2" "$code" 2 "$out"
expect "rename, zamiana obok powtórzonej nazwy: rada o zamianie zostaje" "$out" \
  "imac02: „imac02” → imac02.local – ten adres ma teraz imac01 (imac02.local), $HELD Przy zamianie nazw" \
  "imac01: „imac01” → imac01.local – ten adres ma teraz imac02 (imac01.local), $HELD Przy zamianie nazw" \
  "imac05: „imac05” → imac05.local – ten adres powtarza się"
expect_not "rename, zamiana obok powtórzonej nazwy: bez poprawiania nazw spoza zamiany" "$out" "Najpierw popraw"
