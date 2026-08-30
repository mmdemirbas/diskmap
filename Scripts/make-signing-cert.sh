#!/bin/bash
# Creates a self-signed code-signing certificate so DiskMap.app keeps the same
# identity across rebuilds.
#
# Why this matters: Full Disk Access is granted to a signed identity. Ad-hoc
# signatures change on every build, so macOS sees each build as a different app
# and you must re-grant access every time. With a stable certificate you grant
# it once.
#
# Prompts once for your login keychain password. Nothing leaves this machine.
set -euo pipefail
NAME="${1:-DiskMap Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Certificate '$NAME' already exists."
    security find-identity -v -p codesigning | grep "$NAME" || true
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$WORK/bundle.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass: 2>/dev/null

security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P "" -A -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
echo "Done. Build with:  Scripts/build-app.sh \"$NAME\""
security find-identity -v -p codesigning | grep "$NAME" || true
