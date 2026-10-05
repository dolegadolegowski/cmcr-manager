# shellcheck shell=bash
# Host keys (HostTrust): every connection checks the Mac's key strictly; an untrusted key gets nothing – no
# password, no command – until the user trusted it explicitly (fingerprint shown).
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT come from there).

section "Klucze komputerów – pierwsze połączenie i podszywanie się"
# A second sshd on [::1] (same port, other address) plays a device that took over a Mac's name: its own host
# key, and every session it gets appends the first stdin line – where the admin password travels – to a file.
SPOOF="$WORK/spoof"
mkdir -p "$SPOOF"
ssh-keygen -q -t ed25519 -N "" -f "$SPOOF/hostkey"
cat > "$SPOOF/sshd_config" <<EOF
Port $PORT
ListenAddress ::1
HostKey $SPOOF/hostkey
PidFile $SPOOF/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
ForceCommand /bin/sh -c 'head -n 1 >> "$SPOOF/captured"; echo spoof-session'
EOF
/usr/sbin/sshd -D -e -f "$SPOOF/sshd_config" 2>"$SPOOF/sshd.log" &
SPOOF_PID=$!
for _ in $(seq 1 50); do nc -z ::1 "$PORT" 2>/dev/null && break; sleep 0.1; done
cp "$WORK/config/hosts.json" "$WORK/hosts.hostkeys-backup.json"
python3 - "$WORK/config/hosts.json" "$ME" "$PORT" <<'PY'
import json, sys
p, me, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
hosts = json.load(open(p))
hosts.append({"id": "98989898-9898-9898-9898-989898989898", "name": "imac98", "address": "::1", "user": me, "port": port})
json.dump(hosts, open(p, "w"))
PY
captured() { cat "$SPOOF/captured" 2>/dev/null; }

if nc -z ::1 "$PORT" 2>/dev/null; then
  out="$(ctlpw status 98)"; code=$?
  expect "nieznany klucz: status odrzucony przed logowaniem" "$out" "nie jest jeszcze zaufany" "hasło nie zostało wysłane"
  expect_code "nieznany klucz: status – kod 1" "$code" 1 "$out"
  out="$(ctlpw exec 'echo nie-powinno' 98 --root)"
  expect_not "nieznany klucz: exec --root nie wykonany" "$out" "spoof-session"
  out="$(ctlpw __run-job 'echo nie-powinno' 98)"
  expect "nieznany klucz: zadanie odrzucone" "$out" "started=false"
  [ -z "$(captured)" ] && pass "nieznany klucz: hasło nie dotarło do podszywającego się serwera" \
    || fail "nieznany klucz: przechwycono dane" "$(captured)"
  expect_not "nieznany klucz: klucz nie przyjęty automatycznie" "$(cat "$WORK/known_hosts")" "[::1]:$PORT"

  spoof_fp="$(ssh-keygen -l -f "$SPOOF/hostkey.pub" | awk '{print $2}')"
  out="$(ctl trust 98 --dry-run)"
  expect "trust --dry-run: odcisk klucza nowego komputera" "$out" "imac98" "$spoof_fp" "nowy klucz"
  expect_not "trust --dry-run: nic nie zapisano" "$(cat "$WORK/known_hosts")" "[::1]:$PORT"
  out="$("$CTL" trust 98 </dev/null 2>&1)"; code=$?
  expect_code "trust bez terminala: wymaga --yes" "$code" 2 "$out"
  expect "trust bez terminala: komunikat" "$out" "--yes"

  # Changed key: something else is trusted under this name (the Mac was reinstalled – or is impersonated).
  printf '[::1]:%s %s\n' "$PORT" "$(cut -d' ' -f1-2 "$WORK/hostkey.pub")" >> "$WORK/known_hosts"
  out="$(ctlpw exec 'echo nie-powinno' 98)"; code=$?
  expect "zmieniony klucz: połączenie odrzucone" "$out" "Klucz SSH komputera się zmienił" "podszywać"
  expect_not "zmieniony klucz: nie zaleca usuwania klucza bez sprawdzenia" "$out" "Zapomnij klucz hosta"
  [ -z "$(captured)" ] && pass "zmieniony klucz: hasło nie dotarło" || fail "zmieniony klucz: przechwycono dane" "$(captured)"
  out="$(ctl trust 98 --dry-run)"
  expect "trust: zmieniony klucz wyraźnie oznaczony" "$out" "KLUCZ SIĘ ZMIENIŁ" "poprzednio"

  # Only after an explicit trust does a session (and the password) reach that server – the capture works.
  out="$(ctl trust 98 --yes)"
  expect "trust --yes: zaufano" "$out" "imac98: zaufano"
  [ "$(ssh-keygen -F "[::1]:$PORT" -f "$WORK/known_hosts" | grep -vc '^#')" = 1 ] \
    && pass "trust: stary klucz zastąpiony nowym" || fail "trust: wpisy w known_hosts" "$(cat "$WORK/known_hosts")"
  out="$(ctlpw exec 'echo x' 98)"
  expect "po zaufaniu: sesja nawiązana" "$out" "spoof-session"
  expect "po zaufaniu: test wykrywa przekazanie hasła" "$(captured)" "$PASSWORD"
else
  echo "  (brak IPv6 na ::1 – pominięto test podszywania się)"
fi
kill "$SPOOF_PID" 2>/dev/null
wait "$SPOOF_PID" 2>/dev/null
cp "$WORK/hosts.hostkeys-backup.json" "$WORK/config/hosts.json"

section "Wspólne połączenie: polecenia o długości przy granicy 8 KiB"
# macOS refuses to hand a session's descriptors to the shared connection when the request ends just below a
# multiple of 8 KiB ("mm_send_fd: sendmsg(2): Message too long"); such commands are padded past the boundary.
# Body sizes chosen so that the base64 remote command lands around 8100–8160 bytes.
base="$(ctl render 'echo mux-ok #' | wc -c | tr -d ' ')"
leaked=""
retried=""
for target in $(seq 8090 6 8170); do
  # remote command ≈ 52 + 4 * ceil(rendered / 3) bytes
  want=$(( (target - 52) * 3 / 4 - base ))
  [ "$want" -lt 1 ] && continue
  pad="$(head -c "$want" </dev/zero | tr '\0' x)"
  out="$(ctl exec "echo mux-ok #$pad" 1)"
  case "$out" in *mm_send_fd*) leaked="$leaked $target" ;; esac
  case "$out" in *"Ponowna próba"*) retried="$retried $target" ;; esac
  case "$out" in *mux-ok*) ;; *) leaked="$leaked $target(brak wyniku)" ;; esac
done
[ -z "$leaked" ] && pass "8 KiB: brak komunikatów mm_send_fd w wyniku" || fail "8 KiB: komunikaty ssh w wyniku dla:$leaked"
[ -z "$retried" ] && pass "8 KiB: polecenia przeszły przez wspólne połączenie bez ponawiania" \
  || fail "8 KiB: ponowne próby dla:$retried"
