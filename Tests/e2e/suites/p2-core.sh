# shellcheck shell=bash
# P2 audit items of the CMCRCore package (AUDIT.md): checks through the real ssh transport and cmcrctl.
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT $ROOT come from there).

section "P2 core: wynik polecenia, które ruszyło (AUDIT ZAD-07)"
# ssh messages printed by the command itself (git or another ssh without network) are its own error: the iMac
# answered and stays online.
out="$(ctl __run-job 'echo "ssh: Could not resolve hostname github.com: nodename nor servname provided" >&2; exit 128' 1)"
expect "zadanie z komunikatem ssh polecenia: komputer online" "$out" "exit=128" "started=true" "reach=online"
out="$(ctl __run-job 'echo "ssh: connect to host inny.local port 22: Operation timed out" >&2; exit 255' 1)"
expect "zadanie zakończone kodem 255: komputer online" "$out" "exit=255" "started=true" "reach=online"

section "P2 core: wysyłanie plików o nazwach od „-” (AUDIT PLI-07)"
# tar read a first name such as "-szkic.txt" as options („Nie udało się spakować plików: tar: Can't specify both -t
# and -c”), and a later "-C…" name as a change of folder (the file was left out without an error).
P2S="$WORK/p2-send"
mkdir -p "$P2S"
echo "szkic" > "$P2S/-szkic p2.txt"
echo "dane" > "$P2S/-Cdane p2.txt"
out="$(ctlpw _builder push 1 "$WORK/remote/p2-dest" "" 644 "$P2S/-szkic p2.txt" "$P2S/-Cdane p2.txt" --root)"; code=$?
expect_code "wysyłanie: pliki o nazwach od „-” – kod 0" "$code" 0 "$out"
[ -f "$WORK/remote/p2-dest/-szkic p2.txt" ] && [ "$(cat "$WORK/remote/p2-dest/-Cdane p2.txt" 2>/dev/null)" = dane ] \
  && pass "wysyłanie: oba pliki o nazwach od „-” dotarły" \
  || fail "wysyłanie: brak plików o nazwach od „-”" "$out$(ls -la "$WORK/remote/p2-dest" 2>&1)"

section "P2 core: zbieranie prac z komputera o nazwie z „/” (AUDIT PLI-06)"
# The folder of a Mac named "Sala 3/iMac 01" pointed into a missing folder "Sala 3": the collected work was dropped.
P2C="$WORK/config-p2-slash"
mkdir -p "$P2C"
cp "$WORK/config/settings.json" "$P2C/settings.json"
python3 - "$WORK/config/hosts.json" "$P2C/hosts.json" <<'PY'
import json, sys
hosts = json.load(open(sys.argv[1]))
hosts[0]["name"] = "Sala 3/iMac 01"
json.dump(hosts, open(sys.argv[2], "w"))
PY
mkdir -p "$WORK/remote/p2-prace"
echo "praca" > "$WORK/remote/p2-prace/praca.txt"
out="$(CMCR_CONFIG_DIR="$P2C" CMCR_PASSWORD="$PASSWORD" "$CTL" collect 1 --from "$WORK/remote/p2-prace" --to "$WORK/p2-zebrane" --no-date 2>&1)"; code=$?
expect_code "collect: komputer o nazwie z „/” – kod 0" "$code" 0 "$out"
[ "$(cat "$WORK/p2-zebrane/Sala 3-iMac 01/praca.txt" 2>/dev/null)" = praca ] \
  && pass "collect: prace w folderze „Sala 3-iMac 01”" || fail "collect: brak zebranych prac" "$out$(ls -laR "$WORK/p2-zebrane" 2>&1)"

section "P2 core: litery dni harmonogramu w cmcrctl setup (AUDIT PRZ-10)"
out="$(ctl setup 1 --power-schedule "mtwrf 07:30")"; code=$?
expect_code "setup: złe litery dni – kod 2" "$code" 2 "$out"
expect "setup: złe litery dni – objaśnienie liter" "$out" "M T W R F S U" "np. MTWRF"
expect_not "setup: złe litery dni – nie „wybierz co najmniej jeden dzień”" "$out" "co najmniej jeden dzień"

section "P2 core: cmcrctl setup zachowuje „SSH wyłącznie z kluczem” z aplikacji (AUDIT PRZ-11)"
# Without --ssh-key-only the script rewrote the sshd settings without „PasswordAuthentication no”.
P2K="$WORK/config-p2-keyonly"
mkdir -p "$P2K"
cp "$WORK/config/settings.json" "$WORK/config/hosts.json" "$P2K/"
echo '{"sshKeyOnly": true, "installKey": true}' > "$P2K/setup-options.json"
out="$(CMCR_CONFIG_DIR="$P2K" "$CTL" setup-script 2>/dev/null)"
expect "setup-script: SSH wyłącznie z kluczem z opcji aplikacji" "$out" "OPT_SSH_KEY_ONLY=1"
out="$(CMCR_CONFIG_DIR="$P2K" "$CTL" setup-script --no-ssh-key-only 2>/dev/null)"
expect "setup-script --no-ssh-key-only: logowanie hasłem zostaje" "$out" "OPT_SSH_KEY_ONLY=0"
out="$(CMCR_CONFIG_DIR="$P2K" "$CTL" setup 1 --no-key 2>&1)"; code=$?
expect_code "setup --no-key przy kluczu z aplikacji: kod 2" "$code" 2 "$out"
expect "setup --no-key przy kluczu z aplikacji: wskazówka" "$out" "--no-ssh-key-only"
out="$("$CTL" setup-script 2>/dev/null)"
expect "setup-script bez zapisanych opcji: domyślnie bez SSH wyłącznie z kluczem" "$out" "OPT_SSH_KEY_ONLY=0"

section "P2 core: przerwanie tuż po starcie zatrzymuje polecenie na iMacu (AUDIT ZAD-06)"
# The wrapper prints its start marker before it registers the job; a cancel while the marker is still on its way
# skipped the remote stop („Polecenie nie zostało uruchomione”), and the command ran to the end on the Mac.
# A second sshd on [::1] (same port, other address) delivers every session's stderr – where the marker travels –
# 3 s late, like a slow link; stdout is not delayed.
SLOW="$WORK/p2-slow"
mkdir -p "$SLOW"
cat > "$SLOW/env.sh" <<EOF
. "$ROOT/Tests/e2e/fakes.sh"
exec 2> >(sleep 3; exec cat >&2)
EOF
cat > "$SLOW/sshd_config" <<EOF
Port $PORT
ListenAddress ::1
HostKey $WORK/hostkey
PidFile $SLOW/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
printf 'SetEnv BASH_ENV=%s CMCR_E2E_LOG=%s CMCR_APPS_DIR=%s CMCR_E2E_WORK=%s CMCR_E2E_PASSWORD="%s"\n' \
  "$SLOW/env.sh" "$WORK/fake.log" "$WORK/Applications" "$WORK" "$PASSWORD" >> "$SLOW/sshd_config"
/usr/sbin/sshd -D -e -f "$SLOW/sshd_config" 2>"$SLOW/sshd.log" &
SLOW_PID=$!
for _ in $(seq 1 50); do nc -z ::1 "$PORT" 2>/dev/null && break; sleep 0.1; done
if nc -z ::1 "$PORT" 2>/dev/null; then
  cp "$WORK/config/hosts.json" "$SLOW/hosts-backup.json"
  python3 - "$WORK/config/hosts.json" "$ME" "$PORT" <<'PY'
import json, sys
p, me, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
hosts = json.load(open(p))
hosts.append({"id": "97979797-9797-9797-9797-979797979797", "name": "imac97", "address": "::1", "user": me, "port": port})
json.dump(hosts, open(p, "w"))
PY
  ctl trust 97 --yes >/dev/null
  out="$(ctl __run-job "echo szybkie-p2" 97)"
  expect "wolne stderr: połączenie działa" "$out" "szybkie-p2" "exit=0"
  rm -f "$SLOW/koniec"
  out="$(ctl __run-job "sleep 4; echo koniec > '$SLOW/koniec'" 97 --cancel-after 1.5)"
  expect "przerwanie przed znacznikiem startu: zatrzymano na komputerze" "$out" "cancelled=true" "Zatrzymano polecenie na komputerze"
  expect_not "przerwanie przed znacznikiem startu: nie „nie zostało uruchomione”" "$out" "nie zostało uruchomione"
  sleep 4
  [ ! -e "$SLOW/koniec" ] && pass "przerwanie przed znacznikiem startu: polecenie nie dokończyło pracy" \
    || fail "przerwanie przed znacznikiem startu: polecenie dokończyło pracę na komputerze" "$out"
  cp "$SLOW/hosts-backup.json" "$WORK/config/hosts.json"
else
  echo "  (brak IPv6 na ::1 – pominięto test przerwania przed znacznikiem startu)"
fi
kill "$SLOW_PID" 2>/dev/null
wait "$SLOW_PID" 2>/dev/null
