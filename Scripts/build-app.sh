#!/bin/bash
# Assembles DiskMap.app from the SwiftPM build and signs it.
#
# Full Disk Access is granted to a *signed bundle*. With ad-hoc signing the
# signature changes on every rebuild, so macOS treats each build as a new app
# and the grant goes stale. Pass a certificate name to keep the identity stable:
#   Scripts/build-app.sh "DiskMap Local Signing"
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
cat <<'EOF'
Assemble build/DiskMap.app from the SwiftPM build.

USAGE
    Scripts/build-app.sh [signing-identity]

    With no argument it uses "DiskMap Local Signing" when that certificate is
    in your keychain, and falls back to ad-hoc signing when it is not. An
    identity that is not in the keychain is refused rather than handed to
    codesign, which would otherwise fail after the build had already succeeded.

WHY THE IDENTITY MATTERS
    Full Disk Access is granted to a signed identity. Ad-hoc signatures change
    on every build, so the grant goes stale each time you rebuild. Run
    Scripts/make-signing-cert.sh once to avoid that.

EXAMPLES
    Scripts/build-app.sh
    Scripts/build-app.sh "DiskMap Local Signing"
    Scripts/build-app.sh "Developer ID Application: Your Name (TEAMID)"

SEE ALSO
    ./install.sh --help
EOF
exit 0
fi

# Prefer the stable local certificate if it exists, so Full Disk Access
# survives rebuilds without the caller having to name it.
#
# Deliberately no -v: a self-signed certificate is listed as untrusted, and the
# valid-only listing would hide an identity that signs perfectly well.
DEFAULT_ID="DiskMap Local Signing"
if [ $# -ge 1 ] && [ -n "$1" ]; then
    IDENTITY="$1"
elif security find-identity -p codesigning 2>/dev/null | grep -qF "\"$DEFAULT_ID\""; then
    IDENTITY="$DEFAULT_ID"
else
    IDENTITY="-"
fi

# Never hand codesign an identity that is not in the keychain: it fails with
# "no identity found" after the build has already succeeded, which reads as a
# build failure.
if [ "$IDENTITY" != "-" ] \
   && ! security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
    echo "    Signing identity '$IDENTITY' not found; using ad-hoc instead." >&2
    IDENTITY="-"
fi
APP="build/DiskMap.app"
CONTENTS="$APP/Contents"

echo "==> building"
swift build -c release --product DiskMapApp
swift build -c release --product DiskMapFinder

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
    <!-- Right-click a folder in the Finder, Services. The same two commands
         also sit at the top level of that menu, put there by the Finder
         extension embedded below; these entries stay because a service works
         from every app's Services menu, not only from the Finder. -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>Compare in Disk Map</string></dict>
            <key>NSMessage</key><string>compareFolders</string>
            <key>NSPortName</key><string>Disk Map</string>
            <key>NSSendFileTypes</key>
            <array><string>public.item</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>Measure in Disk Map</string></dict>
            <key>NSMessage</key><string>measureFolders</string>
            <key>NSPortName</key><string>Disk Map</string>
            <key>NSSendFileTypes</key>
            <array><string>public.item</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# The Finder extension: a bundle of its own, inside the app.
#
# This is what puts "Compare in Disk Map" in the contextual menu itself rather
# than in the Services submenu at the bottom of it. It is assembled by hand
# because a Swift package builds executables and not .appex bundles; the
# executable it holds is an ordinary one whose entry point was moved to
# NSExtensionMain by a linker flag in Package.swift.
PLUGIN="$CONTENTS/PlugIns/DiskMapFinder.appex/Contents"
mkdir -p "$PLUGIN/MacOS"
cp .build/release/DiskMapFinder "$PLUGIN/MacOS/DiskMapFinder"
cat > "$PLUGIN/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>DiskMapFinder</string>
    <key>CFBundleIdentifier</key><string>com.mmdemirbas.diskmap.finder</string>
    <key>CFBundleName</key><string>Disk Map Finder</string>
    <key>CFBundleDisplayName</key><string>Disk Map</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHumanReadableCopyright</key><string>Personal build</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
        <key>NSExtensionPrincipalClass</key><string>FinderMenu</string>
    </dict>
</dict>
</plist>
PLIST

# A Finder extension has to be sandboxed. Without this entitlement the bundle
# builds, signs, verifies, installs and is found by Launch Services — and
# PlugInKit refuses to register it, silently, so the menu item never appears
# and nothing anywhere says why. `pluginkit -m -A -i com.mmdemirbas.diskmap.finder`
# printing the identifier is what "registered" looks like; printing nothing is
# what this entitlement being absent looks like.
cat > "$CONTENTS/PlugIns/appex.entitlements" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
</dict>
</plist>
ENTITLEMENTS

echo "==> signing with identity: $IDENTITY"
# Inside out: a nested bundle has to be sealed before the bundle that contains
# it, or the outer signature covers bytes that are about to change.
codesign --force --options runtime --sign "$IDENTITY" \
    --entitlements "$CONTENTS/PlugIns/appex.entitlements" \
    "$CONTENTS/PlugIns/DiskMapFinder.appex"
rm -f "$CONTENTS/PlugIns/appex.entitlements"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> $APP"
if [ "$IDENTITY" = "-" ]; then
  echo "    Ad-hoc signed. Full Disk Access must be re-granted after each rebuild."
  echo "    Run Scripts/make-signing-cert.sh once to avoid that."
fi
