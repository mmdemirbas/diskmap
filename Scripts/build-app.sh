#!/bin/bash
# Assembles DiskMap.app from the SwiftPM build and signs it.
#
# Full Disk Access is granted to a *signed bundle*. With ad-hoc signing the
# signature changes on every rebuild, so macOS treats each build as a new app
# and the grant goes stale. Pass a certificate name to keep the identity stable:
#   Scripts/build-app.sh "DiskMap Local Signing"
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:--}"
APP="build/DiskMap.app"
CONTENTS="$APP/Contents"

echo "==> building"
swift build -c release --product DiskMapApp

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/DiskMapApp "$CONTENTS/MacOS/DiskMap"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>DiskMap</string>
    <key>CFBundleIdentifier</key><string>com.mmdemirbas.diskmap</string>
    <key>CFBundleName</key><string>Disk Map</string>
    <key>CFBundleDisplayName</key><string>Disk Map</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal build</string>
</dict>
</plist>
PLIST

[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

echo "==> signing with identity: $IDENTITY"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> $APP"
if [ "$IDENTITY" = "-" ]; then
  echo "    Ad-hoc signed. Full Disk Access must be re-granted after each rebuild."
  echo "    Run Scripts/make-signing-cert.sh once to avoid that."
fi
