#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d -t plugin-preferences-tests)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$root/Sources/PluginPreferences/include" -framework Foundation \
  "$root/Sources/PluginPreferences/PPDefaultStore.m" "$root/Tests/DefaultStoreTests.m" \
  -o "$test_tmp/DefaultStoreTests"
"$test_tmp/DefaultStoreTests"
