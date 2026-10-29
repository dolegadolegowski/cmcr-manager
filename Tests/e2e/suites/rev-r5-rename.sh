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
# Nor for imac01: its swap goes through imac02, whose name repeats, and the swap advice („Przy zamianie nazw…”),
# followed, left one of them with the temporary name (AUDIT REV-64).
expect_not "rename, zamiana i powtórzona nazwa: bez rady o zamianie przez powtórzoną nazwę" "$out" "Przy zamianie nazw"
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

# r5_renamed NAME NEW – what `rename NAME [--name NEW] --update-list` writes to the list after the rename.
r5_renamed() {
  python3 - "$R5/hosts.json" "$1" "$2" <<'PY'
import json, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
hosts = json.load(open(path))
for h in hosts:
    if h["name"] == old: h["name"] = new; h["address"] = new + ".local"
json.dump(hosts, open(path, "w"))
PY
}
# r5_list – the list as „name@address …”.
r5_list() {
  python3 -c 'import json, sys; print(" ".join(h["name"] + "@" + h["address"] for h in json.load(open(sys.argv[1]))))' \
    "$R5/hosts.json"
}
# r5_steps NAME – the steps of the advice cmcrctl printed (stdin) for the Mac NAME, one per line: „MAC<tab>NEW NAME”
# (no new name: the one from the list); advice without the whole order ends with exit 1.
r5_steps() {
  python3 -c '
import re, sys
mac, out = sys.argv[1], sys.stdin.read()
line = next((l for l in out.splitlines() if l.startswith(mac + ": ") and "ten adres ma teraz" in l), "")
if ": najpierw " not in line:
    sys.exit("brak kolejności w radzie dla " + mac)
advice = line.split(": najpierw ", 1)[1].rstrip(".")
head, sep, last = advice.rpartition(", a na końcu ")
for p in (head.split(", potem ") + [last]) if sep else advice.split(", potem "):
    m = re.fullmatch(r"nadaj (\S+) nazwę tymczasową \(--name\)", p)
    t = re.fullmatch(r"nadaj komputerowi z nazwą tymczasową docelową nazwę (\S+) \(--name\)", p)
    r = re.fullmatch(r"(?:zmień nazwę )?(\S+)", p)
    if m: print(m[1] + "\ttymczasowa")
    elif t: print("tymczasowa\t" + t[1])
    elif r: print(r[1] + "\t")
    else: sys.exit("nieznany krok: " + p)
' "$1"
}
# r5_follow TITLE NAME OUTPUT LIST – follows the advice printed for NAME literally: each step a run of its own (with
# --dry-run), the list updated after it as --update-list does; LIST: the list expected at the end (r5_list).
r5_follow() {
  local steps mac name n=0 out code
  if ! steps="$(printf '%s\n' "$3" | r5_steps "$2" 2>&1)"; then fail "$1: $steps" "$3"; return; fi
  while IFS=$'\t' read -r mac name; do
    n=$((n + 1))
    if [ -n "$name" ]; then out="$(r5 rename "$mac" --name "$name" --dry-run)"; else out="$(r5 rename "$mac" --dry-run)"; fi
    code=$?
    expect_code "$1: krok $n – $mac${name:+ → $name}: kod 0" "$code" 0 "$out"
    r5_renamed "$mac" "${name:-$mac}"
  done <<< "$steps"
  expect_code "$1: lista po ostatnim kroku" "$(r5_list)" "$4" "$(cat "$R5/hosts.json")"
}

section "REV R5 cmcrctl – rename: nazwy w kółko – rada podaje całą kolejność i działa wykonana dosłownie (AUDIT REV-61)"
ROT3=("$A imac02 imac01.local" "$B imac03 imac02.local" "$C imac01 imac03.local")
r5_hosts "${ROT3[@]}"
out="$(r5 rename @1,@2,@3 --dry-run)"; code=$?
expect_code "rename, w kółko między trzema: kod 2" "$code" 2 "$out"
# A temporary name for the Mac asked about frees the name of the Mac before it in the loop: the others go backwards.
expect "rename, w kółko między trzema: cała kolejność od komputera, którego dotyczy rada" "$out" \
  "imac02: „imac02” → imac02.local – ten adres ma teraz imac03 (imac02.local), którego nazwa też jest zmieniana (macOS nadałby wtedy jednemu z nich inny adres). Komputery imac02, imac03 i imac01 zamieniają się nazwami w kółko. Zmień nazwy po kolei, za każdym razem z --update-list: najpierw nadaj imac02 nazwę tymczasową (--name), potem zmień nazwę imac01, potem imac03, a na końcu nadaj komputerowi z nazwą tymczasową docelową nazwę imac02 (--name)." \
  "najpierw nadaj imac03 nazwę tymczasową (--name), potem zmień nazwę imac02, potem imac01, a na końcu nadaj komputerowi z nazwą tymczasową docelową nazwę imac03 (--name)." \
  "najpierw nadaj imac01 nazwę tymczasową (--name), potem zmień nazwę imac03, potem imac02, a na końcu nadaj komputerowi z nazwą tymczasową docelową nazwę imac01 (--name)."
expect_not "rename, w kółko między trzema: bez „pozostałych po kolei” bez kolejności" "$out" "pozostałych po kolei"
for mac in imac02 imac03 imac01; do
  r5_hosts "${ROT3[@]}"
  out="$(r5 rename @1,@2,@3 --dry-run)"
  r5_follow "rename, w kółko między trzema, rada przy $mac" "$mac" "$out" \
    "imac02@imac02.local imac03@imac03.local imac01@imac01.local"
done
ROT4=("$A imac02 imac01.local" "$B imac03 imac02.local" "$C imac04 imac03.local" "$D imac01 imac04.local")
for mac in imac02 imac03 imac04 imac01; do
  r5_hosts "${ROT4[@]}"
  out="$(r5 rename @1,@2,@3,@4 --dry-run)"
  r5_follow "rename, w kółko między czterema, rada przy $mac" "$mac" "$out" \
    "imac02@imac02.local imac03@imac03.local imac04@imac04.local imac01@imac01.local"
done
# A renumbering: from the free end, the Mac asked about last.
REN3=("$A imac06 imac05.local" "$B imac07 imac06.local" "$C imac08 imac07.local")
r5_hosts "${REN3[@]}"
out="$(r5 rename @1,@2,@3 --dry-run)"
r5_follow "rename, przenumerowanie trzech, rada przy imac06" imac06 "$out" \
  "imac06@imac06.local imac07@imac07.local imac08@imac08.local"
r5_hosts "${REN3[@]}"
out="$(r5 rename @1,@2,@3 --dry-run)"
r5_follow "rename, przenumerowanie trzech, rada przy imac07" imac07 "$out" \
  "imac06@imac05.local imac07@imac07.local imac08@imac08.local"
