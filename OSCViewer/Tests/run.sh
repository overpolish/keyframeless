#!/bin/sh
# Compiles the package sources directly; FxPlug-facing behaviour is covered by
# the plugin test suites, which drive the control through a mock host.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
sources="$root/OSCViewer/Sources/OSCViewer"
test_tmp=$(mktemp -d -t osc-viewer-tests)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$sources/include" -framework AppKit -framework Foundation \
  "$sources/OSCCursor.m" "$root/OSCViewer/Tests/OSCCursorTests.m" -o "$test_tmp/OSCCursorTests"
# Without art beside the binary every kind falls back to an AppKit cursor.
"$test_tmp/OSCCursorTests"
# With the SwiftPM resource bundle laid out as Xcode ships it, the art resolves.
bundle="$test_tmp/OSCViewer_OSCViewer.bundle/Contents/Resources"
mkdir -p "$bundle"
cp "$sources"/Resources/*.png "$bundle/"
"$test_tmp/OSCCursorTests" --packaged

xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$sources/include" -framework Foundation \
  "$sources/OSCPlayheadMotion.c" "$root/OSCViewer/Tests/OSCPlayheadMotionTests.m" \
  -o "$test_tmp/OSCPlayheadMotionTests"
"$test_tmp/OSCPlayheadMotionTests"
