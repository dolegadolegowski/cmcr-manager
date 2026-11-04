#!/bin/bash
# Builds "CMCR Screen Agent.app" (docs/screen-agent.md) around a compiled cmcr-screen-agent and signs it.
#   scripts/make-agent-bundle.sh BINARY OUT_DIR [IDENTITY] [KEYCHAIN]
#     BINARY    cmcr-screen-agent (release from scripts/build-app.sh, debug from Tests/e2e/run.sh)
#     OUT_DIR   folder that receives "CMCR Screen Agent.app" (an existing bundle there is replaced)
#     IDENTITY  code signing identity (default "-", ad-hoc)
#     KEYCHAIN  keychain file holding that identity (default: the keychain search list)
# Environment:
#   AGENT_ICON  .icns copied into the bundle (System Settings shows it next to the name)
#
# The bundle's version is the agent's own (ScreenAgentInfo.version, printed by `BINARY --version`), not the app's:
# the iMacs replace their agent only when it changes, because with an ad-hoc signature every new copy needs the
# Screen Recording permission granted again at each iMac.
set -euo pipefail

die() { echo "✘ $*" >&2; exit 1; }
[ $# -ge 2 ] && [ $# -le 4 ] || die "Użycie: $0 BINARY OUT_DIR [IDENTITY] [KEYCHAIN]"
BINARY=$1 OUT_DIR=$2 IDENTITY=${3:--} KEYCHAIN=${4:-}
NAME="CMCR Screen Agent"
BUNDLE_ID="pl.cmcr.manager.screen-agent"
EXECUTABLE="cmcr-screen-agent"

[ -x "$BINARY" ] || die "Brak pliku wykonywalnego usługi: $BINARY"
VERSION=$("$BINARY" --version) || die "$BINARY --version zakończył się błędem"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Nieprawidłowa wersja usługi '$VERSION' ($BINARY --version)"

APP="$OUT_DIR/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"
chmod 755 "$APP/Contents/MacOS/$EXECUTABLE"
ICON_KEY=""
if [ -n "${AGENT_ICON:-}" ]; then
  [ -f "$AGENT_ICON" ] || die "Brak ikony $AGENT_ICON"
  mkdir -p "$APP/Contents/Resources"
  cp "$AGENT_ICON" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY=$'\n  <key>CFBundleIconFile</key><string>AppIcon</string>'
fi
# LSUIElement: an agent without a Dock icon or menu bar. CFBundleName/CFBundleDisplayName is the name in System
# Settings › Privacy & Security › Screen & System Audio Recording.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>pl</string>$ICON_KEY
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>CMCR – zarządzanie pracownią iMac</string>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist" || die "Nieprawidłowy Info.plist usługi"

# Hardened runtime: launchd's environment for the user's session (`launchctl setenv`) cannot inject a library
# (DYLD_INSERT_LIBRARIES) into the agent that the client trusts. The identifier comes from Info.plist.
KEYCHAIN_ARGS=()
[ -n "$KEYCHAIN" ] && KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
codesign --force --sign "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --options runtime "$APP"
codesign --verify --strict "$APP" || die "Podpis usługi $APP jest nieprawidłowy"
[ "$("$APP/Contents/MacOS/$EXECUTABLE" --version)" = "$VERSION" ] || die "Podpisana usługa nie uruchamia się"
echo "$APP"
