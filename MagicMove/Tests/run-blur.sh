#!/bin/sh
# Exercise the production blur path on Metal using the built plugin shader.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
derived="${MM_DERIVED_DATA:-$root/DerivedData/Keyframeless}"
MM_TEST_SUITES=MotionBlurRenderTests "$root/MagicMove/Tests/run.sh"   "$derived/Build/Products/Debug/MagicMove.app/Contents/PlugIns/MagicMove XPC Service.pluginkit/Contents/Resources/default.metallib"
