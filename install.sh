#!/bin/bash
# One command to get Disk Map running. See ./install.sh --help.
set -uo pipefail

cd "$(dirname "$0")"

usage() {
cat <<'EOF'
Disk Map installer

USAGE
    ./install.sh [options]

WHAT IT DOES
    1  Checks that Swift and Xcode are present.
    2  Creates a local code-signing certificate, if you do not already have one.
       Full Disk Access is granted to a signed *identity*. An ad-hoc signature
       changes on every build, so macOS would treat each rebuild as a different
       app and silently drop the grant. The certificate is self-signed, valid
       for ten years, and created without prompting for a password.
    3  Builds and signs build/DiskMap.app.
    4  Copies it to /Applications, or ~/Applications if that is not writable.
    5  Opens Privacy & Security and a Finder window, so Full Disk Access can be
       granted by dragging the app into the list.

    The run ends with an explicit "Installed" or "Failed" block naming the
    identity it actually signed with. It is safe to run repeatedly.

OPTIONS
    --dev        Build and run from ./build. Does not install, does not touch
                 /Applications, does not open any windows.
    --no-open    Install, but do not open the Settings and Finder windows.
                 Useful when running from a script.
    -h, --help   Show this message.

WHAT IT PUTS ON THIS MACHINE
    /Applications/DiskMap.app            the app itself
    login keychain                       certificate "DiskMap Local Signing"
    ~/Library/Preferences/com.mmdemirbas.diskmap.plist
                                         written by the app on first run
    Full Disk Access grant               only if you complete step 5

    ./uninstall.sh removes all of it. ./uninstall.sh --dry-run lists it first.

WHY FULL DISK ACCESS
    Disk Map cannot measure what it cannot read. Without the grant, whole
    folders stay invisible and the totals come up short. A scan of the boot
    volume without it misses roughly 200 directories. The app says so in its
    status bar rather than quietly under-reporting.

EXAMPLES
    ./install.sh                 first-time setup
    ./install.sh --dev           try a local change without installing
    ./install.sh --no-open       reinstall without windows popping up

SEE ALSO
    ./uninstall.sh --help        removing everything
    Scripts/build-app.sh --help  building the bundle on its own
    make help                    all make targets
EOF
}

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
step() { printf "\n%s==> %s%s\n" "$BOLD" "$1" "$OFF"; }
ok()   { printf "    %s✓%s %s\n" "$GREEN" "$OFF" "$1"; }
warn() { printf "    %s!%s %s\n" "$YELLOW" "$OFF" "$1"; }
bad()  { printf "    %s✗%s %s\n" "$RED" "$OFF" "$1"; }

fail() {
    printf "\n%s==> Failed%s\n" "$BOLD$RED" "$OFF"
    bad "$1"
    [ $# -gt 1 ] && printf "\n%s\n" "$2"
    exit 1
}

DEV_MODE=0; OPEN_WINDOWS=1
for arg in "$@"; do
    case "$arg" in
        --dev) DEV_MODE=1 ;;
        --no-open) OPEN_WINDOWS=0 ;;
        -h|--help) usage; exit 0 ;;
        *) printf "Unknown option: %s\n\n" "$arg" >&2; usage >&2; exit 1 ;;
    esac
done

CERT="DiskMap Local Signing"
# No -v: a self-signed certificate reports as untrusted yet signs correctly.
has_identity() { security find-identity -p codesigning 2>/dev/null | grep -qF "\"$1\""; }

step "Checking the toolchain"
command -v swift >/dev/null 2>&1 || fail "Swift not found." \
    "    Install Xcode from the App Store, then run:
      xcode-select --install"
ok "$(swift --version 2>&1 | head -1 | sed 's/^ *//')"

step "Setting up a signing identity"
SIGN_STABLE=1
if has_identity "$CERT"; then
    ok "'$CERT' is already in your keychain"
else
    echo "    Full Disk Access is granted to a signed identity. Without a stable"
    echo "    certificate, every rebuild looks like a new app and you would have"
    echo "    to grant access again each time. Creating one now."
    CERT_LOG="$(Scripts/make-signing-cert.sh "$CERT" 2>&1)" && CERT_RC=0 || CERT_RC=$?
    if [ "$CERT_RC" -eq 0 ] && has_identity "$CERT"; then
        ok "created '$CERT'"
    else
        SIGN_STABLE=0
        warn "could not create the certificate, so the build will be ad-hoc signed"
        warn "Full Disk Access will need re-granting after each rebuild"
        printf "%s" "$CERT_LOG" | sed 's/^/        /'
    fi
fi

step "Building"
# Empty argument means "decide for yourself", so a failed certificate step
# cannot leave codesign chasing an identity that does not exist.
SIGN_ARG=""
[ "$SIGN_STABLE" -eq 1 ] && SIGN_ARG="$CERT"
Scripts/build-app.sh "$SIGN_ARG" 2>&1 | sed 's/^/    /'
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "The build failed." "    Full output:  Scripts/build-app.sh"
[ -d build/DiskMap.app ] || fail "The build reported success but produced no app bundle."

ACTUAL_ID="$(codesign -dvv build/DiskMap.app 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[ -n "$ACTUAL_ID" ] || ACTUAL_ID="ad-hoc"

if [ "$DEV_MODE" -eq 1 ]; then
    step "Launching from ./build"
    open build/DiskMap.app || fail "Could not launch the app."
    printf "\n%s==> Ready%s\n" "$BOLD$GREEN" "$OFF"
    ok "running from $(pwd)/build/DiskMap.app"
    ok "signed with: $ACTUAL_ID"
    exit 0
fi

step "Installing"
TARGET="/Applications/DiskMap.app"
if [ -w /Applications ]; then
    rm -rf "$TARGET" && cp -R build/DiskMap.app "$TARGET" || fail "Could not copy to /Applications."
else
    TARGET="$HOME/Applications/DiskMap.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$TARGET" && cp -R build/DiskMap.app "$TARGET" || fail "Could not copy to ~/Applications."
    warn "/Applications is not writable, so it went to ~/Applications instead"
fi
codesign --verify "$TARGET" 2>/dev/null || fail "The installed copy is not correctly signed."
ok "$TARGET"

printf "\n%s==> Installed%s\n" "$BOLD$GREEN" "$OFF"
ok "signed with: $ACTUAL_ID"
if [ "$SIGN_STABLE" -eq 1 ]; then
    ok "the identity is stable, so Full Disk Access only has to be granted once"
else
    warn "ad-hoc signature: Full Disk Access must be re-granted after every rebuild"
fi

step "One step left: Full Disk Access"
cat <<EOF
    Disk Map cannot measure what it cannot read. Without this permission
    parts of the disk stay invisible and the totals come up short.

      1. In the Privacy window, find ${BOLD}Full Disk Access${OFF}.
      2. Drag ${BOLD}DiskMap${OFF} from the Finder window into the list.
      3. Turn its switch on.
EOF
if [ "$OPEN_WINDOWS" -eq 1 ]; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || \
        warn "could not open System Settings; open Privacy & Security > Full Disk Access yourself"
    sleep 1
    open -R "$TARGET" 2>/dev/null || true
else
    echo "    (windows not opened: --no-open)"
fi

printf "\n%s==> Done%s\n" "$BOLD" "$OFF"
echo "    Launch:   open -a DiskMap"
echo "    Rebuild:  ./install.sh"
echo "    ${DIM}Remove the certificate: security delete-identity -c \"$CERT\" -t${OFF}"
