#!/bin/bash
# Captures the main window of a freshly launched CMCR Manager binary (matched by PID, so parallel runs
# do not grab each other's windows).
#   Tests/ui/snapshot.sh OUT.png [ENV=VALUE …]
# Environment: BIN (default: debug build), WAIT (seconds before capture, default 7), KEEP=1 (leave running),
# MAXSIZE (resize output, default 1400). Pass CMCR_CONFIG_DIR, CMCR_SECTION, CMCR_SELECT_ALL as arguments.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$1"; shift
BIN="${BIN:-$(cd "$ROOT" && swift build --show-bin-path 2>/dev/null)/CMCRManager}"
env "$@" "$BIN" >/dev/null 2>&1 &
PID=$!
sleep "${WAIT:-7}"
WID="$(/usr/bin/swift - "$PID" 2>/dev/null <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let windows = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
let best = windows.max { a, b in
    let ra = a[kCGWindowBounds as String] as! [String: Double], rb = b[kCGWindowBounds as String] as! [String: Double]
    return ra["Width"]! * ra["Height"]! < rb["Width"]! * rb["Height"]!
}
if let w = best { print(w[kCGWindowNumber as String]!) }
SWIFT
)"
if [ -z "$WID" ]; then echo "Nie znaleziono okna (PID $PID)" >&2; kill "$PID" 2>/dev/null; exit 1; fi
TMP="$(mktemp /tmp/cmcr-snap.XXXXXX).png"
screencapture -x -o -l "$WID" "$TMP"
sips -Z "${MAXSIZE:-1400}" "$TMP" --out "$OUT" >/dev/null
rm -f "$TMP"
[ "${KEEP:-0}" = 1 ] || kill "$PID" 2>/dev/null
echo "$OUT"
