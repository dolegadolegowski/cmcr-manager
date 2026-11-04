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

section "REV R4 cmcrctl – rename: rada „w dwóch krokach” i przy zamianie nazw wymienia --update-list (AUDIT REV-55)"
r4_hosts "$A imac06 imac05.local" "$B imac07 imac06.local"
out="$(r4 rename imac06,imac07 --dry-run)"; code=$?
expect_code "rename, przenumerowanie: kod 2" "$code" 2 "$out"
expect "rename, przenumerowanie: dwa kroki z --update-list" "$out" \
  "imac06: „imac06” → imac06.local – ten adres ma teraz imac07 (imac06.local)" \
  "Zmień nazwy w dwóch krokach, za każdym razem z --update-list: najpierw imac07, potem imac06."
out="$(r4 rename imac07 --dry-run)"; code=$?
expect_code "rename, przenumerowanie, krok 1: kod 0" "$code" 0 "$out"
# Without --update-list the list still says imac07 is at imac06.local: the second step is refused (that is why the
# advice names the option).
out="$(r4 rename imac06 --dry-run)"; code=$?
expect_code "rename, przenumerowanie, krok 2 bez aktualizacji listy: kod 2" "$code" 2 "$out"
expect "rename, przenumerowanie, krok 2 bez aktualizacji listy: komunikat" "$out" "ten adres ma już imac07 z listy komputerów"
r4_renamed "$B" imac07
out="$(r4 rename imac06 --dry-run)"; code=$?
expect_code "rename, przenumerowanie, krok 2 po --update-list: kod 0" "$code" 0 "$out"

r4_hosts "$A imac02 imac01.local" "$B imac01 imac02.local"
out="$(r4 rename @1,@2 --dry-run)"; code=$?
expect_code "rename, zamiana nazw: kod 2" "$code" 2 "$out"
expect "rename, zamiana nazw: nazwa tymczasowa, docelowa na końcu, z --update-list" "$out" \
  "Przy zamianie nazw nadaj najpierw jednemu z nich nazwę tymczasową (--name), potem zmień nazwę drugiego, a na końcu nadaj pierwszemu docelową nazwę (--name), za każdym razem z --update-list."
r4_lines "rename, zamiana nazw: rada przy obu komputerach" "$out" "nazwę tymczasową (--name)" 2
# The advice, followed step by step.
out="$(r4 rename @1 --name tymczasowa --dry-run)"; code=$?
expect_code "rename, zamiana, krok 1 (nazwa tymczasowa): kod 0" "$code" 0 "$out"
r4_renamed "$A" tymczasowa
out="$(r4 rename @2 --dry-run)"; code=$?
expect_code "rename, zamiana, krok 2 (drugi komputer): kod 0" "$code" 0 "$out"
r4_renamed "$B" imac01
out="$(r4 rename @1 --name imac02 --dry-run)"; code=$?
expect_code "rename, zamiana, krok 3 (docelowa nazwa przez --name): kod 0" "$code" 0 "$out"
expect "rename, zamiana, krok 3: nowa nazwa" "$out" "tymczasowa: „imac02” → imac02.local"

section "REV R4 cmcrctl – rename: nazwy przesuwane w kółko między trzema komputerami (AUDIT REV-54)"
r4_hosts "$A imac02 imac01.local" "$B imac03 imac02.local" "$C imac01 imac03.local"
out="$(r4 rename @1,@2,@3 --dry-run)"; code=$?
expect_code "rename, nazwy w kółko: kod 2" "$code" 2 "$out"
expect "rename, nazwy w kółko: każdy komputer wskazany" "$out" \
  "imac02: „imac02” → imac02.local – ten adres ma teraz imac03 (imac02.local)" \
  "imac03: „imac03” → imac03.local – ten adres ma teraz imac01 (imac03.local)" \
  "imac01: „imac01” → imac01.local – ten adres ma teraz imac02 (imac01.local)" "nic nie zostało zmienione"
# The whole order in the advice (AUDIT REV-61): followed literally in Tests/e2e/suites/rev-r5-rename.sh.
expect "rename, nazwy w kółko: rada z nazwą tymczasową" "$out" \
  "Komputery imac02, imac03 i imac01 zamieniają się nazwami w kółko. Zmień nazwy po kolei, za każdym razem z --update-list: najpierw nadaj imac02 nazwę tymczasową (--name)" \
  "Komputery imac03, imac01 i imac02 zamieniają się nazwami w kółko" \
  "Komputery imac01, imac02 i imac03 zamieniają się nazwami w kółko" \
  "a na końcu nadaj komputerowi z nazwą tymczasową docelową nazwę imac02 (--name)."
expect_not "rename, nazwy w kółko: bez rady „w dwóch krokach”, której nie da się wykonać" "$out" "w dwóch krokach"
# The advice works: a temporary name first, then the others in the order cmcrctl gives, the target name last.
out="$(r4 rename @1 --name tymczasowa --dry-run)"; code=$?
expect_code "rename, w kółko, krok 1 (nazwa tymczasowa): kod 0" "$code" 0 "$out"
r4_renamed "$A" tymczasowa
out="$(r4 rename @2,@3 --dry-run)"; code=$?
expect_code "rename, w kółko, pozostałe razem: kod 2" "$code" 2 "$out"
expect "rename, w kółko, pozostałe: kolejność" "$out" "najpierw imac01, potem imac03."
out="$(r4 rename @3 --dry-run)"; code=$?
expect_code "rename, w kółko, krok 2: kod 0" "$code" 0 "$out"
r4_renamed "$C" imac01
out="$(r4 rename @2 --dry-run)"; code=$?
expect_code "rename, w kółko, krok 3: kod 0" "$code" 0 "$out"
r4_renamed "$B" imac03
out="$(r4 rename @1 --name imac02 --dry-run)"; code=$?
expect_code "rename, w kółko, krok 4 (docelowa nazwa przez --name): kod 0" "$code" 0 "$out"

section "REV R4 cmcrctl – rename: przenumerowanie trzech komputerów – cała kolejność (AUDIT REV-54)"
r4_hosts "$A imac06 imac05.local" "$B imac07 imac06.local" "$C imac08 imac07.local"
out="$(r4 rename imac06,imac07,imac08 --dry-run)"; code=$?
expect_code "rename, przenumerowanie trzech: kod 2" "$code" 2 "$out"
expect "rename, przenumerowanie trzech: kolejność od wolnej nazwy" "$out" \
  "imac06: „imac06” → imac06.local – ten adres ma teraz imac07 (imac06.local)" \
  "Zmień nazwy po kolei, za każdym razem z --update-list: najpierw imac08, potem imac07, potem imac06." \
  "imac07: „imac07” → imac07.local – ten adres ma teraz imac08 (imac07.local)" \
  "Zmień nazwy w dwóch krokach, za każdym razem z --update-list: najpierw imac08, potem imac07." \
  "imac08: „imac08” → imac08.local"
out="$(r4 rename imac08 --dry-run)"; code=$?
expect_code "rename, przenumerowanie trzech, krok 1: kod 0" "$code" 0 "$out"
r4_renamed "$C" imac08
out="$(r4 rename imac07 --dry-run)"; code=$?
expect_code "rename, przenumerowanie trzech, krok 2: kod 0" "$code" 0 "$out"
r4_renamed "$B" imac07
out="$(r4 rename imac06 --dry-run)"; code=$?
expect_code "rename, przenumerowanie trzech, krok 3: kod 0" "$code" 0 "$out"
