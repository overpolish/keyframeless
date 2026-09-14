#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
test_tmp=$(mktemp -d -t inspector-controls-tests)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

for source in InspectorTokens ICValueTextField ICInspectorRow ICSliderView ICSliderRow ICMenuToggleView ICPopUpButton; do
  xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -I "$root/InspectorControls/Sources/InspectorControls/include" \
    -c "$root/InspectorControls/Sources/InspectorControls/$source.m" \
    -o "$test_tmp/$source.o"
done
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror -I "$root/InspectorControls/Sources/InspectorControls/include" \
  -fsanitize=address,undefined \
  -framework AppKit -framework Foundation \
  "$root/InspectorControls/Tests/SliderGeometryTests.m" \
  "$test_tmp/ICSliderView.o" \
  "$test_tmp/InspectorTokens.o" -o "$test_tmp/SliderGeometryTests"
"$test_tmp/SliderGeometryTests"
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
  -fsanitize=address,undefined \
  -I "$root/InspectorControls/Sources/InspectorControls/include" \
  "$root/InspectorControls/Tests/InspectorControlsTests.m" \
  "$test_tmp/InspectorTokens.o" "$test_tmp/ICValueTextField.o" "$test_tmp/ICInspectorRow.o" \
  "$test_tmp/ICPopUpButton.o" "$test_tmp/ICMenuToggleView.o" "$test_tmp/ICSliderView.o" "$test_tmp/ICSliderRow.o" \
  -framework AppKit -framework Foundation -framework CoreGraphics \
  -o "$test_tmp/InspectorControlsTests"
"$test_tmp/InspectorControlsTests"
