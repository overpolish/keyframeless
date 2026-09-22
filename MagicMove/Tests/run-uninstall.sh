#!/bin/sh
# Exercise the wrapper application's installation model, which decides what the
# uninstaller removes and what it has to ask for privileges to remove.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
wrapper="$root/MagicMove/MagicMove/Wrapper Application"
test_tmp=$(mktemp -d -t magicmove-uninstall)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$wrapper" -framework Foundation \
  "$root/MagicMove/Tests/UninstallTests.m" "$wrapper/KFInstallation.m" "$wrapper/KFUninstaller.m" \
  -o "$test_tmp/UninstallTests"
"$test_tmp/UninstallTests"
