# shellcheck shell=bash
# Review fixes of cmcrctl (AUDIT REV, group R2-cli): Ctrl-C on several Macs and in every command that changes
# something, the warning about a damaged classroom.json and the logout hint. Sourced by Tests/e2e/run.sh (helpers and
# $WORK $CTL $PASSWORD $ME $PORT come from there). Own config folder, so later suites see the original configuration.

R2="$WORK/cfg-rev-r2"
mkdir -p "$R2"
cp "$WORK/config/settings.json" "$R2/"
cat > "$R2/hosts.json" <<EOF
[
 {"id":"a1111111-1111-1111-1111-111111111111","name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"a2222222-2222-2222-2222-222222222222","name":"imac02","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"a5555555-5555-5555-5555-555555555555","name":"imac 05","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"a9999999-9999-9999-9999-999999999999","name":"imac09","address":"imac09.cmcr-e2e.invalid","user":"imac09","port":22}
]
EOF
r2() { CMCR_CONFIG_DIR="$R2" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
# r2_before NAME OUTPUT FIRST SECOND – both lines are there, FIRST above SECOND.
r2_before() {
  local a b
  a="$(printf '%s\n' "$2" | grep -nF -- "$3" | head -n 1 | cut -d: -f1)"
  b="$(printf '%s\n' "$2" | grep -nF -- "$4" | head -n 1 | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then pass "$1"; else fail "$1 („$3” przed „$4”)" "$2"; fi
}
# r2_interrupt CONDITION ARGS… – runs cmcrctl ARGS in its own process group and, once CONDITION (shell code) holds
# (at most 10 s), sends SIGINT to the whole group, as Ctrl-C in a terminal does. Output: $R2_OUT, exit code: $R2_CODE.
r2_interrupt() {
  local cond="$1" pid _
  shift
  set -m
  CMCR_CONFIG_DIR="$R2" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" > "$WORK/rev-r2-int.out" 2>&1 </dev/null &
  pid=$!
  set +m
  for _ in $(seq 1 100); do eval "$cond" && break; sleep 0.1; done
  sleep 0.5
  kill -INT -- "-$pid"
  wait "$pid"; R2_CODE=$?
  R2_OUT="$(cat "$WORK/rev-r2-int.out")"
}

section "REV R2 cmcrctl – przygotowanie"
out="$(r2 list)"
expect "r2: lista komputerów" "$out" "imac01" "imac02" "imac 05" "imac09"

section "REV R2 cmcrctl – logout: podpowiedź --force tylko po odmowie skryptu, pod wynikiem (AUDIT REV-38)"
# A Mac that does not answer: the polite logout never reached it, --force would fail the same way.
out="$(r2 logout 9 --yes)"; code=$?
expect_code "logout, komputer niedostępny: kod 1" "$code" 1 "$out"
expect "logout, komputer niedostępny: przyczyna" "$out" "✘ imac09"
expect_not "logout, komputer niedostępny: bez podpowiedzi --force" "$out" "--force"
# macOS refuses the request (fake-ae-denied): the script itself points to „Wyloguj natychmiast”.
: > "$WORK/fake-ae-denied"
out="$(r2 logout 1 --yes)"; code=$?
expect_code "logout, odmowa macOS: kod 1" "$code" 1 "$out"
expect "logout, odmowa macOS: podpowiedź --force" "$out" "(cmcrctl logout imac01 --force – wylogowanie natychmiastowe"
r2_before "logout, odmowa macOS: podpowiedź pod przyczyną" "$out" "✘ imac01:" "cmcrctl logout imac01 --force"
out="$(r2 logout "imac 05" --yes)"; code=$?
expect "logout, nazwa ze spacją: podpowiedź do skopiowania" "$out" "(cmcrctl logout 'imac 05' --force"
rm -f "$WORK/fake-ae-denied"
