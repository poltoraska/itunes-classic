#!/bin/zsh
# Stable, project-local identity; no system trust or default-keychain changes.
set -euo pipefail
cd "${0:A:h}"
umask 077
mkdir -p .signing
KEYCHAIN="$PWD/.signing/iTunes.keychain-db"
if [[ ! -f "$KEYCHAIN" ]]; then
  openssl rand -base64 32 > .signing/password
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=iTunes Local Development/' -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=codeSigning' -keyout .signing/key.pem -out .signing/certificate.pem 2>/dev/null
  openssl pkcs12 -export -inkey .signing/key.pem -in .signing/certificate.pem -out .signing/identity.p12 -passout file:.signing/password
  security create-keychain -p "$(cat .signing/password)" "$KEYCHAIN"
  security unlock-keychain -p "$(cat .signing/password)" "$KEYCHAIN"
  security import .signing/identity.p12 -k "$KEYCHAIN" -P "$(cat .signing/password)" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat .signing/password)" "$KEYCHAIN" >/dev/null
fi
security unlock-keychain -p "$(cat .signing/password)" "$KEYCHAIN"
