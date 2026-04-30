#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Bumps the version for a single component and updates manifest.json.
#
# Usage: bump-version.sh <component> <breaking|major|minor|alpha|release>
#
# Components:
#   rounded        Rounded plugin
#   magicmove      MagicMove plugin
#   keyframelessx  Keyframeless X app
#   canvas       Canvas plugin
#   glow         Glow plugin

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/manifest.json"

usage() {
  echo "Usage: bump-version.sh <component> <breaking|major|minor|alpha|release>"
  echo ""
  echo "Components:"
  echo "  rounded        Rounded plugin"
  echo "  magicmove      MagicMove plugin"
  echo "  keyframelessx  Keyframeless X app"
  echo "  canvas       Canvas plugin"
  echo "  glow           Glow plugin"
  echo ""
  echo "Version format: BREAKING.MAJOR.MINOR[-vN]"
  echo ""
  echo "Bump types:"
  echo "  breaking  Increment breaking version, reset major and minor"
  echo "  major     Increment major version, reset minor"
  echo "  minor     Increment minor version"
  echo "  alpha     Add or increment -vN suffix (manifest unchanged)"
  echo "  release   Strip -vN suffix and update manifest"
  exit 1
}

if [[ $# -ne 2 ]]; then
  usage
fi

COMPONENT="$1"
BUMP="$2"

# Returns the primary plist path for a component (used to read current version
# for alpha/release operations where the plist may differ from manifest).
plist_for_component() {
  case "$1" in
    rounded)       echo "Rounded/Rounded/Plugin/Info.plist" ;;
    magicmove)     echo "MagicMove/MagicMove/Plugin/Info.plist" ;;
    glow)          echo "Glow/Glow/Plugin/Info.plist" ;;
    canvas) echo "Canvas/Canvas/Plugin/Info.plist" ;;
    keyframelessx) echo "" ;;
  esac
}

# Read current version from the installed plist (includes -vN if present).
read_plist_version() {
  local plist
  plist=$(plist_for_component "$COMPONENT")
  if [[ -n "$plist" ]]; then
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/$plist"
  else
    grep -m1 'MARKETING_VERSION' "$ROOT/Keyframeless X/Keyframeless X.xcodeproj/project.pbxproj" \
      | sed 's/.*= //;s/;.*//' | tr -d ' '
  fi
}

# Read base version from manifest.json (never has -vN suffix).
read_manifest_version() {
  python3 -c "
import json, sys
with open('$MANIFEST') as f:
    m = json.load(f)
print(m.get(sys.argv[1], '0.0.0'))
" "$COMPONENT"
}

MANIFEST_VERSION=$(read_manifest_version)

if [[ "$MANIFEST_VERSION" == "0.0.0" ]]; then
  echo "Unknown component: $COMPONENT"
  usage
fi

case "$BUMP" in
  breaking|major|minor)
    IFS='.' read -r BREAKING MAJOR MINOR <<< "$MANIFEST_VERSION"
    case "$BUMP" in
      breaking)
        BREAKING=$((BREAKING + 1))
        MAJOR=0
        MINOR=0
        ;;
      major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        ;;
      minor)
        MINOR=$((MINOR + 1))
        ;;
    esac
    VERSION="$BREAKING.$MAJOR.$MINOR"
    UPDATE_MANIFEST=true
    ;;
  alpha)
    PLIST_VERSION=$(read_plist_version)
    BASE="${PLIST_VERSION%%-*}"
    if [[ "$PLIST_VERSION" == *-v* ]]; then
      N="${PLIST_VERSION##*-v}"
      N=$((N + 1))
    else
      N=0
    fi
    VERSION="$BASE-v$N"
    UPDATE_MANIFEST=false
    ;;
  release)
    PLIST_VERSION=$(read_plist_version)
    if [[ "$PLIST_VERSION" != *-v* ]]; then
      echo "Already a release version: $PLIST_VERSION"
      exit 0
    fi
    VERSION="${PLIST_VERSION%%-*}"
    UPDATE_MANIFEST=true
    ;;
  *)
    echo "Unknown bump type: $BUMP"
    usage
    ;;
esac

CURRENT=$(read_plist_version)

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

echo "Bumping $COMPONENT: $CURRENT -> $VERSION"

case "$COMPONENT" in
  rounded)
    bump_plist "Rounded/Rounded/Wrapper Application/Info.plist"
    bump_plist "Rounded/Rounded/Plugin/Info.plist"
    bump_fxplug "Rounded/Rounded/Plugin/Info.plist"
    bump_pkgproj "co.overpolish.keyframeless.Rounded"
    ;;

  magicmove)
    bump_plist "MagicMove/MagicMove/Wrapper Application/Info.plist"
    bump_plist "MagicMove/MagicMove/Plugin/Info.plist"
    bump_fxplug "MagicMove/MagicMove/Plugin/Info.plist"
    bump_pkgproj "co.overpolish.keyframeless.MagicMove"
    ;;


  glow)
    bump_plist "Glow/Glow/Wrapper Application/Info.plist"
    bump_plist "Glow/Glow/Plugin/Info.plist"
    bump_fxplug "Glow/Glow/Plugin/Info.plist"
    bump_pkgproj "co.overpolish.keyframeless.Glow"
    ;;

  canvas)
    bump_plist "Canvas/Canvas/Wrapper Application/Info.plist"
    bump_plist "Canvas/Canvas/Plugin/Info.plist"
    bump_fxplug "Canvas/Canvas/Plugin/Info.plist"
    bump_pkgproj "co.overpolish.keyframeless.Canvas"
    ;;
  keyframelessx)
    proj="Keyframeless X/Keyframeless X.xcodeproj/project.pbxproj"
    echo "  $proj"
    current=$(grep -m1 'MARKETING_VERSION' "$ROOT/$proj" \
      | sed 's/.*= //;s/;.*//' | tr -d ' ')
    sed -i '' \
      "s/MARKETING_VERSION = $current;/MARKETING_VERSION = $VERSION;/g" \
      "$ROOT/$proj"
    bump_pkgproj "co.overpolish.keyframeless.Keyframeless-X.Keyframeless-X-FCP"
    ;;

  *)
    echo "Unknown component: $COMPONENT"
    usage
    ;;
esac

if [[ "$UPDATE_MANIFEST" == true ]]; then
  bump_manifest "$COMPONENT" "$VERSION"
  echo ""
  echo "Done — $COMPONENT bumped to $VERSION"
  echo "  manifest.json updated"
else
  echo ""
  echo "Done — $COMPONENT bumped to $VERSION"
  echo "  manifest.json unchanged (alpha)"
fi
