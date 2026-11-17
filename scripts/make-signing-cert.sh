#!/usr/bin/env bash
# One-time setup: creates the self-signed "Framed Release" code-signing identity in the
# login keychain. Releases signed with it keep a stable code requirement, so users keep
# the Screen Recording permission across updates, and nothing personal (like the email in
# an Apple Development certificate) ends up in the app. Back up the exported .p12: losing
# it means every user has to grant the permission again once.
set -euo pipefail

NAME="Framed Release"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in the keychain."; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(openssl rand -hex 16)"

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# Legacy PBE algorithms: `security import` can't read OpenSSL 3's default .p12 encryption.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASS" -out "$TMP/framed.p12"
security import "$TMP/framed.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" -T /usr/bin/codesign >/dev/null

BACKUP="$HOME/Framed-Release-signing.p12"
(umask 077; cp "$TMP/framed.p12" "$BACKUP"; echo "$PASS" > "$BACKUP.password")
echo "Created \"$NAME\". Backup: $BACKUP (+ .password). Move both somewhere safe, e.g. a password manager."
