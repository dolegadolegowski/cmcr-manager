#!/bin/bash
# Builds "CMCR Manager.app" and the cmcrctl command line tool into ./build.
#   scripts/build-app.sh          – release build
#   scripts/build-app.sh --dmg    – additionally packs build/CMCR-Manager.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="CMCR Manager"
EXECUTABLE="CMCRManager"
BUNDLE_ID="pl.cmcr.manager"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "• Kompilacja (release)…"
swift build -c release --product "$EXECUTABLE"
swift build -c release --product cmcrctl
BIN="$(swift build -c release --show-bin-path)"

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

echo "• Pakiet $APP…"
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
  <key>CFBundleVersion</key><string>$VERSION</string>
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

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "⚠︎ Podpis ad-hoc nie powiódł się (aplikacja nadal zadziała lokalnie)."

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
echo "✔ Gotowe: $APP"
echo "  CLI: $BUILD_DIR/cmcrctl"
