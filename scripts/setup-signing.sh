#!/bin/zsh
# One-time setup of a stable code-signing identity for development builds.
#
# Ad-hoc signed builds get a new identity on every build, so macOS asks again for Keychain access
# (the saved Steam login) after each rebuild. With this self-signed certificate, builds keep the same
# identity and the Keychain remembers "Always Allow".
#
# What it does, in your login keychain:
#   1. creates a self-signed certificate "mac-wallpaper development", usable only for code signing (10 years);
#   2. imports it and its private key, letting only /usr/bin/codesign use the key;
#   3. trusts it for code signing. macOS asks for your password here.
# Undo: Keychain Access → login → My Certificates → delete "mac-wallpaper development".
set -euo pipefail

NAME="mac-wallpaper development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already set up."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=$(/usr/bin/openssl rand -hex 16)

cat >"$WORK/cert.cnf" <<EOF
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
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASS"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Imported \"$NAME\". macOS will now ask for your password to trust it for code signing…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

security find-identity -v -p codesigning | grep "\"$NAME\""
echo "Done. scripts/build.sh signs with it from now on."
