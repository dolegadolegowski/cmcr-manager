#!/bin/bash
# Demo environment for UI work: a user-mode sshd on 127.0.0.1:PORT with the e2e fakes (nothing privileged
# or disruptive can run), and a CMCR config with one reachable "iMac" plus a few unreachable ones.
#
#   eval "$(Tests/ui/demo-env.sh 2501 /tmp/cmcr-demo)"     # exports CMCR_CONFIG_DIR, DEMO_SSHD_PID
#   CMCR_SELECT_ALL=1 CMCR_SNAPSHOT_DIR=/tmp/shots "$(swift build --show-bin-path)/CMCRManager"
#   kill "$DEMO_SSHD_PID"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${1:?port}"
DIR="${2:?directory}"
mkdir -p "$DIR/config" "$DIR/remote/Public/cmcr" "$DIR/local" "$DIR/Applications"
[ -f "$DIR/hostkey" ] || ssh-keygen -q -t ed25519 -N "" -f "$DIR/hostkey"
[ -f "$DIR/client" ] || ssh-keygen -q -t ed25519 -N "" -f "$DIR/client" -C cmcr-demo
cp "$DIR/client.pub" "$DIR/authorized_keys"
chmod 600 "$DIR/authorized_keys"
cat > "$DIR/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/hostkey
PidFile $DIR/sshd.pid
AuthorizedKeysFile $DIR/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
Subsystem sftp /usr/libexec/sftp-server
EOF
printf 'SetEnv BASH_ENV=%s CMCR_E2E_LOG=%s CMCR_APPS_DIR=%s CMCR_E2E_WORK=%s CMCR_E2E_PASSWORD="demo"\n' \
  "$ROOT/Tests/e2e/fakes.sh" "$DIR/fake.log" "$DIR/Applications" "$DIR" >> "$DIR/sshd_config"
ME="$(id -un)"
cat > "$DIR/config/hosts.json" <<EOF
[
 {"id":"11111111-1111-1111-1111-111111111111","name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT,"groups":["Sala 101"]},
 {"id":"22222222-2222-2222-2222-222222222222","name":"imac02","address":"imac02.cmcr-demo.invalid","user":"imac02","groups":["Sala 101"]},
 {"id":"33333333-3333-3333-3333-333333333333","name":"imac03","address":"imac03.cmcr-demo.invalid","user":"imac03","groups":["Sala 101"]},
 {"id":"44444444-4444-4444-4444-444444444444","name":"imac04","address":"imac04.cmcr-demo.invalid","user":"imac04","groups":["Sala 102"]},
 {"id":"55555555-5555-5555-5555-555555555555","name":"imac05","address":"imac05.cmcr-demo.invalid","user":"imac05","groups":["Sala 102"]},
 {"id":"66666666-6666-6666-6666-666666666666","name":"imac06","address":"imac06.cmcr-demo.invalid","user":"imac06","groups":["Sala 102"]}
]
EOF
cat > "$DIR/config/settings.json" <<EOF
{"identityFile":"$DIR/client","extraSSHOptions":"UserKnownHostsFile=$DIR/known_hosts","sharedFolder":"/Users/student/Public/cmcr",
 "localFolder":"$DIR/local","studentUser":"student","connectTimeout":3,"observeOnlyStandardAccounts":false}
EOF
# The demo iMac's key counts as confirmed (connections check host keys strictly; see HostTrust).
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1-2 "$DIR/hostkey.pub")" > "$DIR/known_hosts"
[ -f "$DIR/sshd.pid" ] && kill "$(cat "$DIR/sshd.pid")" 2>/dev/null
/usr/sbin/sshd -f "$DIR/sshd_config" -E "$DIR/sshd.log"
for _ in $(seq 1 30); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
echo "export CMCR_CONFIG_DIR='$DIR/config' CMCR_KEYCHAIN_SERVICE='pl.cmcr.manager.demo' CMCR_PASSWORD='demo' DEMO_SSHD_PID='$(cat "$DIR/sshd.pid" 2>/dev/null)'"
