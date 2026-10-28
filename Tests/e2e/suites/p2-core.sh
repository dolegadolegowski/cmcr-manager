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
