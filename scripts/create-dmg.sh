#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
APP="$PWD/build/iTunes.app"
[[ -d "$APP" ]] || { print -u2 'Run ./build.sh first'; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(uname -m)
mkdir -p dist
STAGE=$(mktemp -d "${TMPDIR:-/tmp/}itunes-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/iTunes.app"
ln -s /Applications "$STAGE/Applications"
cp README.md "$STAGE/README.md"
cp INSTALL.txt "$STAGE/Установка.txt"
cp THIRD_PARTY_NOTICES.md "$STAGE/THIRD_PARTY_NOTICES.md"
OUT="$PWD/dist/iTunes-$VERSION-$ARCH.dmg"
[[ ! -e "$OUT" ]] || { print -u2 "Already exists: $OUT"; exit 1; }
/usr/bin/hdiutil create -volname "iTunes $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$OUT"
/usr/bin/hdiutil verify "$OUT"
(cd dist && /usr/bin/shasum -a 256 "${OUT:t}" > "${OUT:t}.sha256")
print "Created: $OUT"
