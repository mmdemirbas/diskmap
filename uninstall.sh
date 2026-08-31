#!/bin/bash
# Removes everything install.sh put on this machine. See ./uninstall.sh --help.
set -uo pipefail
cd "$(dirname "$0")"
REPO="$(pwd)"

usage() {
cat <<'EOF'
Disk Map uninstaller

USAGE
    ./uninstall.sh [options]

WHAT IT REMOVES
    /Applications/DiskMap.app            the app (also ~/Applications)
    ~/Library/Preferences/...plist       saved appearance, language, window size
    ~/Library/Saved Application State/   window restoration data
    ~/Library/Caches, HTTPStorages       if the app ever created them
    login keychain certificate           "DiskMap Local Signing"
    Full Disk Access grant               via tccutil

    It prints the list with sizes and waits for confirmation before touching
    anything. Running it twice is harmless: the second run reports that the
    machine is already clean.

WHAT IT LEAVES ALONE
    This repository's ./build and ./.build directories. Those belong to the
    checkout rather than to the machine, and `make clean` already covers them.
    Pass --build to include them.

OPTIONS
    -n, --dry-run   Print the plan and change nothing.
    -y, --yes       Do not ask for confirmation. Required when not running in
                    a terminal.
    --keep-cert     Leave the signing certificate in place. Use this when you
                    intend to reinstall: keeping the same identity means the
                    Full Disk Access grant survives.
    --build         Also delete this repo's ./build and ./.build.
    -h, --help      Show this message.

TWO THINGS A MANUAL DELETE MISSES
    Dragging the app to the Trash leaves a dead entry in System Settings >
    Privacy & Security > Full Disk Access, pointing at an app that no longer
    exists. This resets it with tccutil.

    Deleting the preferences file alone does not stick: cfprefsd holds
    preferences in memory and writes the file back afterwards. This drops the
    defaults domain as well.

EXAMPLES
    ./uninstall.sh --dry-run          see exactly what would go
    ./uninstall.sh                    remove it, with a confirmation prompt
    ./uninstall.sh --yes --build      remove everything, including build output
    ./uninstall.sh --keep-cert        remove the app but keep the identity

SEE ALSO
    ./install.sh --help
EOF
}

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
step() { printf "\n%s==> %s%s\n" "$BOLD" "$1" "$OFF"; }
ok()   { printf "    %s✓%s %s\n" "$GREEN" "$OFF" "$1"; }
warn() { printf "    %s!%s %s\n" "$YELLOW" "$OFF" "$1"; }
bad()  { printf "    %s✗%s %s\n" "$RED" "$OFF" "$1"; }

BUNDLE_ID="com.mmdemirbas.diskmap"
CERT="DiskMap Local Signing"
DRY=0; ASSUME_YES=0; KEEP_CERT=0; WIPE_BUILD=0

for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --keep-cert)  KEEP_CERT=1 ;;
        --build)      WIPE_BUILD=1 ;;
        -h|--help)    usage; exit 0 ;;
        *) printf "Unknown option: %s\n\n" "$arg" >&2; usage >&2; exit 1 ;;
    esac
done

# Only ever delete inside these roots. A typo in a path variable should not be
# able to reach anything else.
safe_path() {
    case "$1" in
        /Applications/DiskMap.app|"$HOME"/Library/*|"$HOME"/Applications/DiskMap.app|"$REPO"/*) return 0 ;;
        *) return 1 ;;
    esac
}

TARGETS=()
add_target() { [ -e "$1" ] && TARGETS+=("$1"); }

add_target "/Applications/DiskMap.app"
add_target "$HOME/Applications/DiskMap.app"
add_target "$HOME/Library/Preferences/$BUNDLE_ID.plist"
add_target "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
add_target "$HOME/Library/Caches/$BUNDLE_ID"
add_target "$HOME/Library/HTTPStorages/$BUNDLE_ID"
add_target "$HOME/Library/Containers/$BUNDLE_ID"
if [ "$WIPE_BUILD" -eq 1 ]; then
    add_target "$REPO/.build"
    add_target "$REPO/build"
fi

HAS_CERT=0
security find-identity -p codesigning 2>/dev/null | grep -qF "\"$CERT\"" && HAS_CERT=1

step "This will remove"
if [ ${#TARGETS[@]} -eq 0 ] && { [ "$HAS_CERT" -eq 0 ] || [ "$KEEP_CERT" -eq 1 ]; }; then
    ok "nothing found; this machine is already clean"
    [ "$WIPE_BUILD" -eq 0 ] && [ -d "$REPO/.build" ] && \
        echo "    ${DIM}build artifacts are still in the repo; add --build to delete them${OFF}"
    exit 0
fi
for t in "${TARGETS[@]}"; do
    printf "    %s  %s\n" "$(du -sh "$t" 2>/dev/null | cut -f1 | tr -d ' ' | sed 's/^/[/;s/$/]/')" "$t"
done
[ "$HAS_CERT" -eq 1 ] && [ "$KEEP_CERT" -eq 0 ] && \
    printf "    %s  keychain identity \"%s\"\n" "[cert]" "$CERT"
printf "    %s  Full Disk Access grant for %s\n" "[tcc] " "$BUNDLE_ID"
if [ "$WIPE_BUILD" -eq 0 ] && [ -d "$REPO/.build" ]; then
    echo
    echo "    ${DIM}Not touching the repo's build artifacts ($(du -sh "$REPO/.build" 2>/dev/null | cut -f1)). Add --build to include them.${OFF}"
fi

if [ "$DRY" -eq 1 ]; then
    printf "\n%s==> Dry run: nothing was changed%s\n" "$BOLD" "$OFF"
    exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    if [ ! -t 0 ]; then
        printf "\n"
        bad "Not running interactively. Re-run with --yes to confirm."
        exit 1
    fi
    printf "\n    Remove these? [y/N] "
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) printf "\n%s==> Cancelled; nothing was changed%s\n" "$BOLD" "$OFF"; exit 0 ;;
    esac
fi

step "Quitting the app"
if pgrep -f "DiskMap.app/Contents/MacOS/DiskMap" >/dev/null 2>&1; then
    osascript -e 'tell application "DiskMap" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -f "DiskMap.app/Contents/MacOS/DiskMap" >/dev/null 2>&1 || true
    ok "stopped"
else
    ok "not running"
fi

step "Removing files"
FAILED=0
# cfprefsd caches preferences in memory and will happily write the plist back
# after it is deleted, so the domain has to be dropped as well as the file.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
for t in "${TARGETS[@]}"; do
    if ! safe_path "$t"; then
        bad "refusing to delete an unexpected path: $t"
        FAILED=1
        continue
    fi
    if rm -rf "$t" 2>/dev/null; then
        ok "$t"
    else
        bad "could not remove $t"
        FAILED=1
    fi
done
[ ${#TARGETS[@]} -eq 0 ] && ok "no files to remove"

step "Resetting Full Disk Access"
# Leaves a stale entry in System Settings otherwise, pointing at an app that no
# longer exists.
if tccutil reset SystemPolicyAllFiles "$BUNDLE_ID" >/dev/null 2>&1; then
    ok "cleared the grant for $BUNDLE_ID"
else
    warn "no grant to clear (or macOS declined); remove it by hand in"
    warn "System Settings > Privacy & Security > Full Disk Access if it lingers"
fi

if [ "$HAS_CERT" -eq 1 ] && [ "$KEEP_CERT" -eq 0 ]; then
    step "Removing the signing certificate"
    if security delete-identity -c "$CERT" -t >/dev/null 2>&1; then
        ok "deleted \"$CERT\""
    else
        bad "could not delete \"$CERT\""
        warn "try by hand: security delete-identity -c \"$CERT\" -t"
        FAILED=1
    fi
elif [ "$HAS_CERT" -eq 1 ]; then
    step "Signing certificate"
    ok "kept \"$CERT\" (--keep-cert)"
fi

# Stop Launch Services offering an app that is gone.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREG" ] && "$LSREG" -kill -r -domain local -domain user >/dev/null 2>&1 || true

if [ "$FAILED" -eq 0 ]; then
    printf "\n%s==> Uninstalled%s\n" "$BOLD$GREEN" "$OFF"
    ok "nothing of Disk Map is left on this machine"
    [ "$WIPE_BUILD" -eq 0 ] && [ -d "$REPO/.build" ] && \
        echo "    ${DIM}except the repo's build artifacts: ./uninstall.sh --build, or make clean${OFF}"
    echo "    Reinstall any time with:  ./install.sh"
else
    printf "\n%s==> Finished with problems%s\n" "$BOLD$YELLOW" "$OFF"
    warn "some items could not be removed; see the lines marked above"
    exit 1
fi
