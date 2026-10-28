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
