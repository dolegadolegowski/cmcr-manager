# P2 audit fixes in the remote scripts (package „scripts”): processes, uninstalling, disk images, updates, lesson
# end, delayed power, energy schedule, uploads, folders, readiness, the setup script and the screen preview.
# Sourced by Tests/e2e/run.sh (helpers: section, pass, fail, expect, expect_not, expect_code, ctl, ctlpw, fakelog…).
# Everything runs against folders inside $WORK and the fakes in fakes.sh (control files in $WORK).

P2="$WORK/p2"
mkdir -p "$P2"
p2_mkapp() { # p2_mkapp DIR NAME – minimal application bundle running a copy of /bin/sleep
  mkdir -p "$1/$2.app/Contents/MacOS"
  cp /bin/sleep "$1/$2.app/Contents/MacOS/$2"
  codesign --force --sign - "$1/$2.app/Contents/MacOS/$2" >/dev/null 2>&1
}
p2_start() { # p2_start EXECUTABLE – starts it detached (no job notices) and prints its PID
  ( "$1" 300 >/dev/null 2>&1 & echo $! )
}
p2_alive() { kill -0 "$1" 2>/dev/null; }

section "P2: zamykanie procesu po PID (AUDIT APL-06)"
ROOTPID="$(ps -axo pid=,user= | awk '$2 == "root" && $1 > 1 {print $1; exit}')"
clear_fakelog
out="$(ctlpw kill "$ROOTPID" 1 --force)"; code=$?
expect "kill: proces innego konta – odmowa" "$out" "Odmowa" "nie do zalogowanego użytkownika"
expect_code "kill: proces innego konta – kod 1" "$code" 1 "$out"
expect_not "kill: proces innego konta – nic nie wysłano przez sudo" "$(fakelog)" "sudo kill"
