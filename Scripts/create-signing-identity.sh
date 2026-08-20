#!/bin/bash
# Creates a stable self-signed code-signing identity for SidekickDock.
#
# Why: ad-hoc signatures (`codesign -s -`) change on every rebuild, so macOS TCC sees a
# different binary each time and re-asks for Screen Recording and Accessibility. Signing
# with a persistent identity keeps the app's designated requirement stable, so the grants
# stick across rebuilds.
#
# Run once. It asks for your login password to trust the certificate for code signing.
set -euo pipefail

IDENTITY="SidekickDock Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "==> Identity '$IDENTITY' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$IDENTITY/O=SidekickDock" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -name "$IDENTITY" -passout pass:sidekickdock 2>/dev/null

echo "==> Importing into your login keychain"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P sidekickdock \
  -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null

echo "==> Trusting it for code signing (authentication required)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "==> Done. './Scripts/build.sh release' will now sign with '$IDENTITY'."
