#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
mkdir -p .build/release
xcrun clang -mmacosx-version-min=13.0 -fobjc-arc -fmodules -I Native/include -c Native/MTPBridge.m -o .build/release/MTPBridge.o
xcrun swiftc -import-objc-header Native/include/MTPBridge.h .build/release/MTPBridge.o -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$PWD/.build/clang-cache" Sources/iTunes/*.swift -o .build/release/iTunes
APP="$PWD/build/iTunes.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/iTunes "$APP/Contents/MacOS/iTunes"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto Resources/LegacyIcons "$APP/Contents/Resources/LegacyIcons"
ditto Resources/GenreArtwork "$APP/Contents/Resources/GenreArtwork"
ditto Resources/TrafficLights "$APP/Contents/Resources/TrafficLights"
ditto Resources/Libraries.bundle "$APP/Contents/Resources/Libraries.bundle"
./signing.sh
for lib in "$APP"/Contents/Resources/Libraries.bundle/*.dylib; do
  codesign --force --keychain "$PWD/.signing/iTunes.keychain-db" --sign "iTunes Local Development" "$lib"
done
codesign --force --keychain "$PWD/.signing/iTunes.keychain-db" --sign "iTunes Local Development" "$APP"
echo "Built: ${APP:A}"
