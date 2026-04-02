#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Bumps the version for a single component and updates manifest.json.
#
# Usage: bump-version.sh <component> <version>
#
# Components:
#   motionblur     MotionBlur plugin
#   rounded        Rounded plugin
#   magicmove      MagicMove plugin
#   keyframelessx  Keyframeless X app

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/manifest.json"

usage() {
  echo "Usage: bump-version.sh <component> <version>"
  echo ""
  echo "Components:"
  echo "  motionblur     MotionBlur plugin"
  echo "  rounded        Rounded plugin"
  echo "  magicmove      MagicMove plugin"
  echo "  keyframelessx  Keyframeless X app"
  exit 1
}

if [[ $# -ne 2 ]]; then
  usage
fi

COMPONENT="$1"
VERSION="$2"

bump_plist() {
  local plist="$1"
  echo "  $plist"
  /usr/libexec/PlistBuddy -c \
    "Set :CFBundleShortVersionString $VERSION" "$ROOT/$plist"
}

bump_fxplug() {
  local plist="$1"
  local full="$ROOT/$plist"
  local i=0
  while /usr/libexec/PlistBuddy -c \
    "Print :ProPlugPlugInList:$i:ProPlugPlugInVersion" "$full" \
    &>/dev/null; do
    echo "  $plist ProPlugPlugInList[$i]"
    /usr/libexec/PlistBuddy -c \
      "Set :ProPlugPlugInList:$i:ProPlugPlugInVersion $VERSION" "$full"
    ((i++))
  done
}

bump_pkgproj() {
  local identifier="$1"
  local pkgproj="Distribution/Keyframeless.pkgproj"
  echo "  $pkgproj ($identifier)"
  perl -i -0pe \
    "s|(<key>IDENTIFIER</key>\s*<string>\Q$identifier\E</string>.*?<key>VERSION</key>\s*<string>)[^<]*(</string>)|\${1}$VERSION\${2}|s" \
    "$ROOT/$pkgproj"
}

bump_manifest() {
  if [[ "$VERSION" == *-* ]]; then
    echo "  manifest.json skipped (pre-release)"
    return
  fi
  python3 -c "
import json, sys
key_path, value = sys.argv[1], sys.argv[2]
with open('$MANIFEST', 'r') as f:
    m = json.load(f)
keys = key_path.split('.')
obj = m
for k in keys[:-1]:
    obj = obj[k]
obj[keys[-1]] = value
with open('$MANIFEST', 'w') as f:
    json.dump(m, f, indent=2)
    f.write('\n')
" "$@"
}

case "$COMPONENT" in
  motionblur)
    echo "Bumping MotionBlur to $VERSION"
    bump_plist "MotionBlur/MotionBlur/Wrapper Application/Info.plist"
    bump_plist "MotionBlur/MotionBlur/Plugin/Info.plist"
    bump_fxplug "MotionBlur/MotionBlur/Plugin/Info.plist"
    bump_pkgproj "co.overpolish.keyframeless.MotionBlur"
    bump_manifest "motionblur" "$VERSION"
    ;;

  rounded)
    echo "Bumping Rounded to $VERSION"
    bump_plist "Rounded/Rounded/Wrapper Application/Info.plist"
    bump_plist "Rounded/Rounded/Plugin/Info.plist"
    bump_fxplug "Rounded/Rounded/Plugin/Info.plist"
    bump_pkgproj "co.overpolish.keyframeless.Rounded"
    bump_manifest "rounded" "$VERSION"
    ;;

  magicmove)
    echo "Bumping MagicMove to $VERSION"
    bump_plist "MagicMove/MagicMove/Wrapper Application/Info.plist"
    bump_plist "MagicMove/MagicMove/Plugin/Info.plist"
    bump_fxplug "MagicMove/MagicMove/Plugin/Info.plist"
    bump_pkgproj "co.overpolish.keyframeless.MagicMove"
    bump_manifest "magicmove" "$VERSION"
    ;;

  keyframelessx)
    echo "Bumping Keyframeless X to $VERSION"
    proj="Keyframeless X/Keyframeless X.xcodeproj/project.pbxproj"
    echo "  $proj"
    current=$(grep -m1 'MARKETING_VERSION' "$ROOT/$proj" \
      | sed 's/.*= //;s/;.*//' | tr -d ' ')
    sed -i '' \
      "s/MARKETING_VERSION = $current;/MARKETING_VERSION = $VERSION;/g" \
      "$ROOT/$proj"
    bump_pkgproj "co.overpolish.keyframeless.Keyframeless-X.Keyframeless-X-FCP"
    bump_manifest "keyframelessx" "$VERSION"
    ;;

  *)
    echo "Unknown component: $COMPONENT"
    usage
    ;;
esac

echo ""
echo "Done — $COMPONENT bumped to $VERSION"
echo "  manifest.json updated"
