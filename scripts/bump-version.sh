#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Bumps the version number across all plugins, the framework,
# Keyframeless X, and the installer .pkgproj.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Discover current version from KeyframelessKit ---

CURRENT=$(/usr/libexec/PlistBuddy -c \
  "Print :CFBundleShortVersionString" \
  "$ROOT/MotionBlur/MotionBlur/Wrapper Application/Info.plist")

echo "Current version: $CURRENT"
printf "New version: "
read -r NEW

if [[ -z "$NEW" ]]; then
  echo "No version entered, aborting."
  exit 1
fi

if [[ "$NEW" == "$CURRENT" ]]; then
  echo "Version unchanged, aborting."
  exit 1
fi

# --- Info.plist files (CFBundleShortVersionString) ---

PLISTS=(
  "MotionBlur/MotionBlur/Wrapper Application/Info.plist"
  "MotionBlur/MotionBlur/Plugin/Info.plist"
  "Rounded/Rounded/Wrapper Application/Info.plist"
  "Rounded/Rounded/Plugin/Info.plist"
)

for plist in "${PLISTS[@]}"; do
  echo "  $plist"
  /usr/libexec/PlistBuddy -c \
    "Set :CFBundleShortVersionString $NEW" "$ROOT/$plist"
done

# --- FxPlug ProPlugPlugInList version strings ---

FXPLUG_PLISTS=(
  "MotionBlur/MotionBlur/Plugin/Info.plist"
  "Rounded/Rounded/Plugin/Info.plist"
)

for plist in "${FXPLUG_PLISTS[@]}"; do
  full="$ROOT/$plist"
  i=0
  while /usr/libexec/PlistBuddy -c \
    "Print :ProPlugPlugInList:$i:ProPlugPlugInVersion" "$full" \
    &>/dev/null; do
    echo "  $plist ProPlugPlugInList[$i]"
    /usr/libexec/PlistBuddy -c \
      "Set :ProPlugPlugInList:$i:ProPlugPlugInVersion $NEW" "$full"
    ((i++))
  done
done

# --- Xcode projects (MARKETING_VERSION) ---

PBXPROJS=(
  "Keyframeless X/Keyframeless X.xcodeproj/project.pbxproj"
  "KeyframelessKit/KeyframelessKit.xcodeproj/project.pbxproj"
)

for proj in "${PBXPROJS[@]}"; do
  echo "  $proj"
  sed -i '' "s/MARKETING_VERSION = $CURRENT;/MARKETING_VERSION = $NEW;/g" \
    "$ROOT/$proj"
done

# --- Packages .pkgproj (installer version) ---

PKGPROJ="Distribution/Keyframeless.pkgproj"
echo "  $PKGPROJ"
sed -i '' "s|<string>$CURRENT</string>|<string>$NEW</string>|g" \
  "$ROOT/$PKGPROJ"

echo ""
echo "Bumped $CURRENT -> $NEW"
