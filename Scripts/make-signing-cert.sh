#!/bin/bash
# Creates a self-signed code-signing certificate so DiskMap.app keeps the same
# identity across rebuilds.
#
# Why it matters: Full Disk Access is granted to a signed identity. An ad-hoc
# signature changes on every build, so macOS sees each build as a different app
# and the grant goes stale. With a stable certificate you grant access once.
#
# Runs without prompting. Nothing leaves this machine. To remove it later:
#   security delete-identity -c "DiskMap Local Signing" -t
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
cat <<'EOF'
Create a self-signed code-signing certificate for local builds.

USAGE
    Scripts/make-signing-cert.sh [certificate-name]

    Default name: "DiskMap Local Signing". Valid for ten years. Runs without
    prompting: no trust settings are changed, because codesign accepts an
    untrusted self-signed identity and the resulting signature verifies.

WHY
    Full Disk Access is granted to a signed identity, so a signature that
    changes on every build means re-granting access on every build.

REMOVING IT
    security delete-identity -c "DiskMap Local Signing" -t

TWO MACOS QUIRKS THIS WORKS AROUND
    security import cannot read a PKCS#12 written with current OpenSSL
    defaults, and fails outright on an empty password. The export therefore
    uses PBE-SHA1-3DES with a real transport password.

    security find-identity -v lists only trusted identities, so a self-signed
    certificate never appears there even though it signs correctly. Detection
    uses the listing without -v.
EOF
exit 0
fi

NAME="${1:-DiskMap Local Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

# Note: no -v. A self-signed certificate is reported as untrusted, so the
# valid-only listing hides it even though codesign can use it perfectly well.
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
    echo "Certificate '$NAME' already exists."
    exit 0
fi

[ -f "$KEYCHAIN" ] || { echo "No login keychain at $KEYCHAIN" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# An arbitrary transport password. It only protects the PKCS#12 file for the
# few milliseconds between openssl writing it and security importing it.
PASS="diskmap-transport-$$"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# The legacy PBE algorithms are required: macOS SecKeychainItemImport cannot
# read the defaults that current OpenSSL/LibreSSL writes, and an empty password
# fails MAC verification outright.
openssl pkcs12 -export -out "$WORK/bundle.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASS" 2>/dev/null

security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P "$PASS" -A -T /usr/bin/codesign

# No add-trusted-cert: codesign accepts an untrusted self-signed identity, and
# changing trust settings is the only step that would need a password prompt.
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
    echo "Created '$NAME'."
else
    echo "Import reported success but '$NAME' is not usable for signing." >&2
    exit 1
fi
