#!/bin/sh

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
RENDER="$ROOT/Mirage/Plugin/Render"
CORE="$ROOT/Mirage/Plugin/Core"
LIB="$ROOT/../ThirdParty/build/lib/libkktranspiler.a"
INCLUDE="$ROOT/../ThirdParty/build/include"
BUILD="${TMPDIR:-/tmp}/mirage-transpile-tests.build"

if [ ! -f "$LIB" ]; then
  echo "skip: $LIB missing - run ThirdParty/build-transpiler.sh first"
  exit 0
fi

# MirageShaderModel imports <KeyframelessKit/KKSlotInstances.h>; the kit is a
# framework in the app build and a loose header here, so stage the one header
# under the name the import spells.
rm -rf "$BUILD"
mkdir -p "$BUILD/include/KeyframelessKit"
cp "$ROOT/../KeyframelessKit/KeyframelessKit/Math/Timing/KKSlotInstances.h" \
   "$BUILD/include/KeyframelessKit/"

INCS="-I$CORE -I$RENDER -I$RENDER/Surface -I$ROOT/Mirage/Plugin/OSC -I$BUILD/include -I$INCLUDE"

for src in "$HERE/MirageTranspileTests.m" \
           "$RENDER/KKGLSLWrapper.m" \
           "$RENDER/KKGLSLShims.m" \
           "$RENDER/KKGLSLTranspileResult.m" \
           "$RENDER/MirageCustomShader.m" \
           "$RENDER/MirageShaderModel.m"; do
  xcrun clang -c -fobjc-arc -x objective-c $INCS "$src" \
    -o "$BUILD/$(basename "$src" .m).o"
done
xcrun clang++ -c -fobjc-arc -std=c++17 -x objective-c++ $INCS \
  "$RENDER/KKGLSLTranspiler.mm" -o "$BUILD/KKGLSLTranspiler.o"

xcrun clang++ -fobjc-arc -framework Foundation "$BUILD"/*.o "$LIB" \
  -o "$BUILD/mirage-transpile-tests"
"$BUILD/mirage-transpile-tests" "$@"
