#!/bin/bash
# One command to get Disk Map running.
#
#   ./install.sh            build, sign, install to /Applications, set up access
#   ./install.sh --dev      build and run from ./build without installing
set -euo pipefail
cd "$(dirname "$0")"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
step() { printf "\n%s==> %s%s\n" "$BOLD" "$1" "$OFF"; }
ok()   { printf "    %s✓%s %s\n" "$GREEN" "$OFF" "$1"; }
warn() { printf "    %s!%s %s\n" "$YELLOW" "$OFF" "$1"; }

DEV_MODE=0
[ "${1:-}" = "--dev" ] && DEV_MODE=1

step "Checking the toolchain"
if ! command -v swift >/dev/null 2>&1; then
    echo "    Swift not found. Install Xcode from the App Store, then run:"
    echo "      xcode-select --install"
    exit 1
fi
ok "$(swift --version 2>&1 | head -1 | sed 's/^ *//')"

CERT="DiskMap Local Signing"
step "Setting up a signing identity"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT"; then
    ok "'$CERT' already in your keychain"
else
    echo "    macOS grants Full Disk Access to a signed identity. Without a stable"
    echo "    certificate every rebuild looks like a different app and you would"
    echo "    have to grant access again each time."
    echo "    Creating one now. macOS will ask for your login password once."
    if Scripts/make-signing-cert.sh "$CERT" >/dev/null 2>&1; then
        ok "created '$CERT'"
    else
        warn "could not create the certificate; falling back to ad-hoc signing"
        warn "you will need to re-grant Full Disk Access after each rebuild"
    fi
fi

step "Building"
Scripts/build-app.sh "$CERT" 2>&1 | sed 's/^/    /'

if [ "$DEV_MODE" -eq 1 ]; then
    step "Launching from ./build"
    open build/DiskMap.app
    ok "running"
    exit 0
fi

step "Installing"
TARGET="/Applications/DiskMap.app"
if [ -w /Applications ]; then
    rm -rf "$TARGET"
    cp -R build/DiskMap.app "$TARGET"
else
    TARGET="$HOME/Applications/DiskMap.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$TARGET"
    cp -R build/DiskMap.app "$TARGET"
    warn "/Applications is not writable; installed to ~/Applications instead"
fi
ok "$TARGET"

step "Full Disk Access"
PROBE="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if [ -r "$PROBE" ]; then
    ok "this terminal already has it; the app still needs its own grant"
fi
cat <<EOF
    Disk Map cannot measure what it cannot read. Without this permission,
    parts of the disk stay invisible and the totals come up short.

    A Settings window and a Finder window are opening now:
      1. Drag ${BOLD}DiskMap${OFF} from the Finder window into the list.
      2. Turn its switch on.

EOF
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" || true
sleep 1
open -R "$TARGET" || true

step "Done"
echo "    Launch it whenever you like:  open -a DiskMap"
echo "    ${DIM}Rebuild after changes:        ./install.sh${OFF}"
