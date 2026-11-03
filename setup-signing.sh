#!/bin/bash
# One-time setup: creates a personal code-signing certificate in your login
# keychain so every build is signed the same way. macOS ties permissions
# (Accessibility, System Audio Recording) to an app's signature, so a stable
# signature means you stop re-granting them after each rebuild.
#
# The certificate is self-signed, lives only on this Mac, and is only
# trusted for signing your own builds. To remove it later:
#   Keychain Access → login → My Certificates → "VolumeMixer Local Signing" → Delete
set -euo pipefail

NAME="VolumeMixer Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
  exit 0   # already set up
fi

echo "Creating a personal code-signing certificate (\"$NAME\") in your login keychain..."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# Apple's built-in openssl (LibreSSL) writes .p12 files the keychain can read.
# A Homebrew OpenSSL 3 needs -legacy for that.
OPENSSL=/usr/bin/openssl
LEGACY=""
if ! "$OPENSSL" version | grep -q LibreSSL; then LEGACY="-legacy"; fi

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# Random one-time password for the temporary .p12 file (deleted on exit).
PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"

# -T lets codesign use the key without asking every time.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Done. Future builds will be signed with \"$NAME\"."
echo "Note: macOS may ask once for your login password so codesign can use it. Choose \"Always Allow\"."
