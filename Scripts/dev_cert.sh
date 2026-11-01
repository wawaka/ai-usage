#!/usr/bin/env bash
# (Re)generates the self-signed code-signing certificate used by Scripts/dev.sh, so dev builds keep one
# stable signature across rebuilds (macOS then stops re-asking for Keychain access after every build).
#
#   Scripts/dev_cert.sh      # wipe .dev-signing/ and create a fresh certificate + keychain
#
# Everything lives in .dev-signing/ (git-ignored) in its own keychain, so your login keychain is not touched.
# Dev builds only: Scripts/package_app.sh never uses this certificate.
# A new certificate is a new identity: macOS will ask once more for Keychain access after regenerating.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=".dev-signing"
NAME="AI Usage Dev"
KEYCHAIN="$PWD/$DIR/dev.keychain-db"
# macOS's own LibreSSL writes .p12 files that `security import` accepts (Homebrew's OpenSSL 3 may not).
OPENSSL=/usr/bin/openssl

# Drop the previous certificate's trust setting and keychain.
if [[ -f "$DIR/cert.pem" ]]; then security remove-trusted-cert "$DIR/cert.pem" 2>/dev/null || true; fi
if [[ -f "$KEYCHAIN" ]]; then security delete-keychain "$KEYCHAIN" 2>/dev/null || true; fi
rm -rf "$DIR"
mkdir -p "$DIR"
chmod 700 "$DIR"

PASSWORD="$($OPENSSL rand -hex 16)"
printf '%s' "$PASSWORD" > "$DIR/keychain-password"
chmod 600 "$DIR/keychain-password"

cat > "$DIR/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

$OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/openssl.cnf" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
$OPENSSL pkcs12 -export -name "$NAME" -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -out "$DIR/dev.p12" -passout "pass:$PASSWORD"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # never auto-lock
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$DIR/dev.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

# codesign only accepts identities whose certificate is trusted for code signing (Keychain Access sets this
# for the certificates it creates, an imported one needs it explicitly). Per-user setting, macOS asks you
# to authorise it once with your password or Touch ID.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"

# dev.sh signs by this SHA-1 (the certificate is self-signed, so it isn't listed as a "valid" identity).
$OPENSSL x509 -in "$DIR/cert.pem" -noout -fingerprint -sha1 | sed -e 's/.*=//' -e 's/://g' > "$DIR/identity"
if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "$(cat "$DIR/identity")"; then
  echo "error: the certificate was created but macOS doesn't accept it as a valid code-signing identity" >&2
  echo "       (check: security find-identity -p codesigning $KEYCHAIN)" >&2
  exit 1
fi
rm -f "$DIR/key.pem" "$DIR/dev.p12"   # the key now lives only in the keychain

echo "✓ created '$NAME' in $DIR/ (identity $(cat "$DIR/identity"))"
