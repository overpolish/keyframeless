#!/usr/bin/env bash

# Builds and runs scratchpad/transpiledigest.mm, which prints the MSL digest of
# each GLSL file given. Used to show that an attribute-only template edit leaves
# the transpiled shader byte-identical.
#
# Two shims, both harness-only: the KeyframelessKit headers are flattened into
# an include dir because the installed framework is a GUI build product, and
# KKSlotLaneKey is stubbed because that binary predates it and nothing on the
# transpile path calls it.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FW="$(dirname "$(find "$ROOT/DerivedData" "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*/Build/Products/Debug/KeyframelessKit.framework' -maxdepth 5 -print -quit 2>/dev/null)")"
D="$(mktemp -d)"
HDR="$D/hdr/KeyframelessKit"
mkdir -p "$HDR"
find "$ROOT/KeyframelessKit/KeyframelessKit" -name '*.h' -exec ln -sf {} "$HDR" \;

cat > "$D/stub.m" <<'STUB'
#import <Foundation/Foundation.h>
NSString *KKSlotLaneKey(NSString *g, NSString *i, NSString *c) {
  return [NSString stringWithFormat:@"%@#%@.%@", g, i, c];
}
STUB

R="$ROOT/Mirage/Mirage/Plugin"
INC=(-I "$ROOT/ThirdParty/format-tests/stub" -I "$R/Render" -I "$R/Render/Surface"
     -I "$R/Core" -I "$R/OSC" -I "$ROOT/ThirdParty/build/include" -I "$D/hdr" -F "$FW")

for f in KKGLSLTranspileResult KKGLSLWrapper KKGLSLShims MirageShaderModel; do
  xcrun clang -fobjc-arc -arch arm64 -c "${INC[@]}" "$R/Render/$f.m" -o "$D/$f.o"
done
xcrun clang -fobjc-arc -arch arm64 -c "$D/stub.m" -o "$D/stub.o"
xcrun clang++ -std=gnu++20 -fobjc-arc -arch arm64 -c "${INC[@]}" \
  "$R/Render/KKGLSLTranspiler.mm" -o "$D/tr.o"
xcrun clang++ -std=gnu++20 -fobjc-arc -arch arm64 -c "${INC[@]}" \
  "$HERE/transpiledigest.mm" -o "$D/main.o"
xcrun clang++ -arch arm64 "$D"/*.o "$ROOT/ThirdParty/build/lib/libkktranspiler.a" \
  -F "$FW" -framework KeyframelessKit -rpath "$FW" \
  -framework Foundation -framework AppKit -o "$D/transpile-digest"

"$D/transpile-digest" "$@"
