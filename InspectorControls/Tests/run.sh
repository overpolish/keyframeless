#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
test_tmp=$(mktemp -d -t inspector-controls-tests)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

for source in ICContextMenu ICDefaultMenu InspectorTokens ICValueTextField ICValueFieldEditor ICValueTextField+Scrub ICValueFieldNavigation ICInspectorRow ICSliderView ICSliderRow ICMenuToggleView ICPopUpButton ICInspectorHeader; do
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
  "$test_tmp/InspectorTokens.o" "$test_tmp/ICValueTextField.o" "$test_tmp/ICValueFieldEditor.o" "$test_tmp/ICValueTextField+Scrub.o" "$test_tmp/ICValueFieldNavigation.o" "$test_tmp/ICInspectorRow.o" \
  "$test_tmp/ICContextMenu.o" "$test_tmp/ICDefaultMenu.o" "$test_tmp/ICPopUpButton.o" "$test_tmp/ICMenuToggleView.o" "$test_tmp/ICSliderView.o" "$test_tmp/ICSliderRow.o" "$test_tmp/ICInspectorHeader.o" \
  -framework AppKit -framework Foundation -framework CoreGraphics \
  -o "$test_tmp/InspectorControlsTests"
"$test_tmp/InspectorControlsTests"
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
  -I "$root/InspectorControls/Sources/InspectorControls/include" \
  -fsanitize=address,undefined \
  -framework AppKit -framework Foundation \
  "$root/InspectorControls/Tests/InspectorHeaderTests.m" \
  "$test_tmp/ICInspectorHeader.o" "$test_tmp/InspectorTokens.o" \
  -o "$test_tmp/InspectorHeaderTests"
"$test_tmp/InspectorHeaderTests"
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
  -fsanitize=address,undefined \
  -I "$root/InspectorControls/Sources/InspectorControls/include" \
  "$root/InspectorControls/Tests/ValueFocusTests.m" \
  "$test_tmp/ICValueTextField.o" "$test_tmp/ICValueFieldEditor.o" "$test_tmp/ICValueTextField+Scrub.o" "$test_tmp/ICValueFieldNavigation.o" "$test_tmp/ICContextMenu.o" "$test_tmp/InspectorTokens.o" \
  -framework AppKit -framework Foundation -framework CoreGraphics \
  -o "$test_tmp/ValueFocusTests"
"$test_tmp/ValueFocusTests"
