#!/bin/sh

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/MirageRackLanesTests.m"
STUBS="$HERE/MirageRackLanesStubs.m"
PLUGIN="$HERE/../Mirage/Plugin"
DERIVED="$HERE/../../DerivedData/Keyframeless/Build/Products/Debug"
FXPLUG="/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks"
OUTPUT="${TMPDIR:-/tmp}/mirage-rack-lanes-tests"

# Unlike run-rack-model-tests.sh (which compiles the handful of kit .m files
# MirageRack.h needs), the lane catalog reaches KeyframelessKit's umbrella
# header through Plugin.h, so it links the BUILT framework instead - which is
# the one the GUI build produces. Nothing here is compiled against it that the
# plugin doesn't already compile against.
if [ ! -d "$DERIVED/KeyframelessKit.framework" ]; then
  echo "error: $DERIVED/KeyframelessKit.framework not found - build the" \
       "KeyframelessKit scheme (Debug) first." >&2
  exit 1
fi

xcrun clang -fobjc-arc -framework Foundation -framework AppKit \
  -framework KeyframelessKit \
  -F"$FXPLUG" -F"$DERIVED" \
  -I"$PLUGIN/Core" -I"$PLUGIN/Render" -I"$PLUGIN/Render/Surface" -I"$PLUGIN/OSC" \
  -Wno-protocol \
  "$SOURCE" "$STUBS" \
  "$PLUGIN/Core/MirageLocalized.m" \
  "$PLUGIN/Core/MirageDirectiveCatalog.m" \
  "$PLUGIN/Core/MirageDirectiveVocab.m" \
  "$PLUGIN/Render/MirageShaderModel.m" \
  "$PLUGIN/Render/MirageCustomShader.m" \
  -Wl,-rpath,"$DERIVED" \
  -o "$OUTPUT"
"$OUTPUT"
