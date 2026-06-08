#!/usr/bin/env bash
set -euo pipefail

# Creates a local, self-signed code-signing identity ("Mac2And Dev") in the
# login keychain. build-app.sh signs the app with it so the Accessibility
# permission (required by Slow Type) survives rebuilds instead of re-prompting
# every time. Safe and local — remove it any time with:
#   security delete-identity -c "Mac2And Dev"

CERT_CN="Mac2And Dev"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
  echo "Identity '$CERT_CN' already exists — nothing to do."
  exit 0
fi

PW="m2a-transit"          # transit-only password for the temp PKCS#12
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$CERT_CN" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# -legacy + -macalg sha1 + a non-empty password: required so Apple's Security
# framework can parse the PKCS#12 (OpenSSL 3 defaults are incompatible).
openssl pkcs12 -export -legacy -macalg sha1 \
  -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$PW" 2>/dev/null

# -A lets codesign use the key without per-use keychain prompts.
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PW" -A

echo "Created code-signing identity '$CERT_CN'."
echo "It is self-signed (shows as NOT_TRUSTED), which is fine — codesign can"
echo "sign with it and the Accessibility grant binds to its stable signature."
