#!/bin/bash
# Builds "CMCR Manager.app" and the cmcrctl command line tool into ./build.
#   scripts/build-app.sh          – release build
#   scripts/build-app.sh --dmg    – additionally packs build/CMCR-Manager.dmg
# Environment:
#   VERSION             CFBundleShortVersionString (default: contents of the VERSION file)
#   BUILD_NUMBER        CFBundleVersion (default: number of commits)
#   UNIVERSAL=1         arm64 + x86_64 (Intel Macs)
#   CMCR_SIGN_IDENTITY  code signing identity; default: "CMCR Manager Code Signing" when it exists
#                       (scripts/make-signing-identity.sh), otherwise ad-hoc ("-"). A stable identity lets
#                       macOS keep "Zawsze pozwalaj" Keychain decisions after an automatic update.
#   CMCR_SIGN_KEYCHAIN  keychain file holding that identity (default: the keychain search list)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="CMCR Manager"
EXECUTABLE="CMCRManager"
BUNDLE_ID="pl.cmcr.manager"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION 2>/dev/null || true)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "✘ Nieprawidłowa wersja '$VERSION' (plik VERSION)." >&2; exit 1; }
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

DEFAULT_IDENTITY="CMCR Manager Code Signing"
KEYCHAIN_ARGS=()
[ -n "${CMCR_SIGN_KEYCHAIN:-}" ] && KEYCHAIN_ARGS=(--keychain "$CMCR_SIGN_KEYCHAIN")
if [ -n "${CMCR_SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$CMCR_SIGN_IDENTITY"
elif security find-identity -p codesigning ${CMCR_SIGN_KEYCHAIN:+"$CMCR_SIGN_KEYCHAIN"} 2>/dev/null | grep -qF "\"$DEFAULT_IDENTITY\""; then
  SIGN_IDENTITY="$DEFAULT_IDENTITY"
else
  SIGN_IDENTITY="-"
fi

echo "• Kompilacja (release)…"
swift build -c release --product "$EXECUTABLE"
swift build -c release --product cmcrctl
BIN="$(swift build -c release --show-bin-path)"
if [ "${UNIVERSAL:-0}" = 1 ]; then
  echo "• Kompilacja x86_64 (universal)…"
  X86=(-c release --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64)
  swift build "${X86[@]}" --product "$EXECUTABLE"
  swift build "${X86[@]}" --product cmcrctl
  X86_BIN="$(swift build "${X86[@]}" --show-bin-path)"
  mkdir -p "$BUILD_DIR/universal"
  for b in "$EXECUTABLE" cmcrctl; do lipo -create "$BIN/$b" "$X86_BIN/$b" -output "$BUILD_DIR/universal/$b"; done
  BIN="$BUILD_DIR/universal"
fi

echo "• Ikona…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$BUILD_DIR/icon-1024.png" >/dev/null
for size in 16 32 128 256 512; do
  sips -z $size $size "$BUILD_DIR/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$BUILD_DIR/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

echo "• Pakiet ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$BIN/cmcrctl" "$APP/Contents/Resources/bin/cmcrctl"
cp "$BIN/cmcrctl" "$BUILD_DIR/cmcrctl"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>pl</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>CMCR Manager łączy się przez SSH z komputerami iMac w sieci lokalnej i wysyła pakiety Wake-on-LAN.</string>
  <key>NSHumanReadableCopyright</key><string>CMCR – zarządzanie pracownią iMac</string>
</dict>
</plist>
PLIST

# A valid, sealed signature is required: the updater rejects bundles whose signature does not verify.
if [ "$SIGN_IDENTITY" = "-" ]; then echo "• Podpis kodu: ad-hoc"; else echo "• Podpis kodu: $SIGN_IDENTITY"; fi
codesign --force --sign "$SIGN_IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --identifier "$BUNDLE_ID.cmcrctl" \
  "$APP/Contents/Resources/bin/cmcrctl" "$BUILD_DIR/cmcrctl"
codesign --force --sign "$SIGN_IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$APP"
codesign --verify --deep --strict "$APP"

if [ "${1:-}" = "--dmg" ]; then
  echo "• Obraz DMG…"
  STAGE="$BUILD_DIR/dmg"
  rm -rf "$STAGE" "$BUILD_DIR/CMCR-Manager.dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$BUILD_DIR/CMCR-Manager.dmg" >/dev/null
  rm -rf "$STAGE"
  echo "  → $BUILD_DIR/CMCR-Manager.dmg"
fi

rm -rf "$ICONSET" "$BUILD_DIR/icon-1024.png"
echo "✔ Gotowe: $APP (wersja $VERSION, kompilacja $BUILD_NUMBER, podpis: $SIGN_IDENTITY)"
echo "  CLI: $BUILD_DIR/cmcrctl"
