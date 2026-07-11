#!/usr/bin/env bash
# Build glslang + SPIRV-Cross as static libs and merge them into a single fat
# archive (libkktranspiler.a) plus a headers tree, for linking the runtime
# GLSL->MSL transpiler into the Mesh XPC service.
#
# Usage: ./build-transpiler.sh [arm64|x86_64|universal]   (default: arm64)
#
# Output:
#   ThirdParty/build/lib/libkktranspiler.a
#   ThirdParty/build/include/{glslang,spirv_cross}/...
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARCHSEL="${1:-arm64}"
case "$ARCHSEL" in
  arm64)     ARCHS="arm64" ;;
  x86_64)    ARCHS="x86_64" ;;
  universal) ARCHS="arm64;x86_64" ;;
  *) echo "unknown arch '$ARCHSEL' (arm64|x86_64|universal)"; exit 1 ;;
esac

BUILD="$HERE/build"
OUT_LIB="$BUILD/lib"
OUT_INC="$BUILD/include"
DEPLOY_TARGET="12.0"
rm -rf "$BUILD"
mkdir -p "$OUT_LIB" "$OUT_INC"

CMAKE_COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES="$ARCHS"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET"
  -DBUILD_SHARED_LIBS=OFF
)

echo "==> Building glslang ($ARCHS)"
cmake -S "$HERE/glslang" -B "$BUILD/glslang" -G Ninja "${CMAKE_COMMON[@]}" \
  -DENABLE_OPT=OFF \
  -DENABLE_HLSL=OFF \
  -DENABLE_GLSLANG_BINARIES=OFF \
  -DGLSLANG_TESTS=OFF \
  -DGLSLANG_ENABLE_INSTALL=OFF \
  -DBUILD_TESTING=OFF
cmake --build "$BUILD/glslang"

echo "==> Building SPIRV-Cross ($ARCHS)"
cmake -S "$HERE/SPIRV-Cross" -B "$BUILD/spirv-cross" -G Ninja "${CMAKE_COMMON[@]}" \
  -DSPIRV_CROSS_STATIC=ON \
  -DSPIRV_CROSS_SHARED=OFF \
  -DSPIRV_CROSS_CLI=OFF \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF \
  -DSPIRV_CROSS_ENABLE_C_API=ON \
  -DSPIRV_CROSS_ENABLE_GLSL=ON \
  -DSPIRV_CROSS_ENABLE_MSL=ON \
  -DSPIRV_CROSS_ENABLE_HLSL=OFF \
  -DSPIRV_CROSS_ENABLE_CPP=OFF \
  -DSPIRV_CROSS_ENABLE_REFLECT=OFF \
  -DSPIRV_CROSS_ENABLE_UTIL=ON
cmake --build "$BUILD/spirv-cross"

echo "==> Merging static archives"
ARCHIVES=()
while IFS= read -r a; do ARCHIVES+=("$a"); done < <(find "$BUILD/glslang" "$BUILD/spirv-cross" -name '*.a')
printf '   %s\n' "${ARCHIVES[@]}"
libtool -static -o "$OUT_LIB/libkktranspiler.a" "${ARCHIVES[@]}"

echo "==> Assembling headers"
mkdir -p "$OUT_INC/glslang" "$OUT_INC/spirv_cross"
# glslang C interface + the resource-limits header the C API needs.
cp -R "$HERE/glslang/glslang/Include" "$OUT_INC/glslang/Include"
cp -R "$HERE/glslang/glslang/Public" "$OUT_INC/glslang/Public"
cp -R "$HERE/glslang/SPIRV" "$OUT_INC/glslang/SPIRV"
# SPIRV-Cross C API header (+ the couple it includes).
cp "$HERE/SPIRV-Cross"/spirv_cross_c.h "$OUT_INC/spirv_cross/" 2>/dev/null || true
cp "$HERE/SPIRV-Cross"/spirv.h "$OUT_INC/spirv_cross/" 2>/dev/null || true
cp "$HERE/SPIRV-Cross"/spirv.hpp "$OUT_INC/spirv_cross/" 2>/dev/null || true

echo "==> Done: $OUT_LIB/libkktranspiler.a"
lipo -info "$OUT_LIB/libkktranspiler.a" 2>/dev/null || true
ls -la "$OUT_LIB"
