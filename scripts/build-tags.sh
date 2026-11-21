#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
xcrun clang++ -std=c++17 -dynamiclib -fobjc-arc -mmacosx-version-min=13.0 -I Native/TagLibHeaders Native/TagWriter.mm Resources/Libraries.bundle/libtag.2.dylib -framework Foundation -Wl,-rpath,@loader_path -install_name @rpath/libITTagWriter.dylib -o Resources/Libraries.bundle/libITTagWriter.dylib
