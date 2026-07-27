#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Bumps the version for a single component. The component's plist (or .pbxproj for
# Keyframeless X) is the source of truth for the current version; the changelog .md
# filename + its kk-version meta tag are what the update checker reads.
#
# Usage: bump-version.sh <component> <breaking|major|minor|alpha|release>
#
# Components:
#   keyframelessx  Keyframeless X app
#   mirage         Mirage plugin
#   canvas         Canvas plugin
#   ai             Keyframeless AI (standalone local helper)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "Usage: bump-version.sh <component> <breaking|major|minor|alpha|release>"
  echo ""
  echo "Components:"
  echo "  keyframelessx  Keyframeless X app"
  echo "  mirage         Mirage plugin"
  echo "  canvas         Canvas plugin"
  echo "  ai             Keyframeless AI (standalone local helper)"
  echo ""
  echo "Version format: BREAKING.MAJOR.MINOR[-vN]"
  echo ""
  echo "Bump types:"
  echo "  breaking  Increment breaking version, reset major and minor"
  echo "  major     Increment major version, reset minor"
  echo "  minor     Increment minor version"
  echo "  alpha     Add or increment -vN suffix (no changelog entry)"
  echo "  release   Strip -vN suffix and create a changelog entry"
  exit 1
}

if [[ $# -ne 2 ]]; then
  usage
fi

COMPONENT="$1"
BUMP="$2"

case "$COMPONENT" in
  canvas | mirage | keyframelessx | ai) ;;
  *)
    echo "Unknown component: $COMPONENT"
    usage
    ;;
esac

# Returns the primary plist path for a component (empty for keyframelessx, which
# stores its version in the .pbxproj instead).
plist_for_component() {
  case "$1" in
    canvas)        echo "Canvas/Canvas/Plugin/Info.plist" ;;
    mirage)        echo "Mirage/Mirage/Plugin/Info.plist" ;;
    ai) echo "Distribution/helper/kk-ai-helper.plist" ;;
    keyframelessx) echo "" ;;
  esac
}

# The site folder a component's release notes live in. This is the SITE slug,
# which is not always the component name: the update check derives its own slug
# from the bundle id (keyframelessx, ai) while the site uses the product names.
# The generated alias pages keep those paths resolving.
changelog_slug_for_component() {
  case "$1" in
    ai) echo "keyframeless-ai" ;;
    *)  echo "$1" ;;
  esac
}

# Current version from the source of truth (includes -vN if present).
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

CURRENT=$(read_plist_version)
BASE_VERSION="${CURRENT%%-*}"

case "$BUMP" in
  breaking | major | minor)
    IFS='.' read -r BREAKING MAJOR MINOR <<< "$BASE_VERSION"
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
    CREATE_CHANGELOG=true
    ;;
  alpha)
    if [[ "$CURRENT" == *-v* ]]; then
      N="${CURRENT##*-v}"
      N=$((N + 1))
    else
      N=0
    fi
    VERSION="$BASE_VERSION-v$N"
    CREATE_CHANGELOG=false
    ;;
  release)
    if [[ "$CURRENT" != *-v* ]]; then
      echo "Already a release version: $CURRENT"
      exit 0
    fi
    VERSION="$BASE_VERSION"
    CREATE_CHANGELOG=true
    ;;
  *)
    echo "Unknown bump type: $BUMP"
    usage
    ;;
esac

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
  # Fail loudly on an identifier the pkgproj doesn't contain. The perl below
  # silently does nothing on no match, which is how the Shader -> Mirage rename
  # left the installer pinned to a stale version without anyone noticing.
  if ! grep -q "<string>$identifier</string>" "$ROOT/$pkgproj"; then
    echo "Error: $identifier not found in $pkgproj" >&2
    exit 1
  fi
  perl -i -0pe \
    "s|(<key>IDENTIFIER</key>\s*<string>\Q$identifier\E</string>.*?<key>VERSION</key>\s*<string>)[^<]*(</string>)|\${1}$VERSION\${2}|s" \
    "$ROOT/$pkgproj"
}

# Create a prefilled release-notes .md for this version (the changelog site + the
# kk-version meta tag both derive from this file). Never clobbers an existing one.
create_changelog_md() {
  local slug
  slug="$(changelog_slug_for_component "$COMPONENT")"
  local dir="$ROOT/docs/changelog/$slug"
  local md="$dir/$VERSION.md"
  if [[ -f "$md" ]]; then
    echo "  changelog: docs/changelog/$slug/$VERSION.md already exists (left as-is)"
    return
  fi
  mkdir -p "$dir"
  cat >"$md" <<EOF
<!-- date: $(date +%Y-%m-%d) -->

### New

### Improved

### Fixed
EOF
  echo "  changelog: created docs/changelog/$slug/$VERSION.md"
}

echo "Bumping $COMPONENT: $CURRENT -> $VERSION"

case "$COMPONENT" in
  canvas)
    bump_plist "Canvas/Canvas/Wrapper Application/Info.plist"
    bump_plist "Canvas/Canvas/Plugin/Info.plist"
    bump_fxplug "Canvas/Canvas/Plugin/Info.plist"
    bump_pkgproj "co.overpolish.keyframeless.Canvas"
    ;;


  mirage)
    bump_plist "Mirage/Mirage/Wrapper Application/Info.plist"
    bump_plist "Mirage/Mirage/Plugin/Info.plist"
    bump_fxplug "Mirage/Mirage/Plugin/Info.plist"
    bump_pkgproj "co.overpolish.keyframeless.Mirage"
    ;;

  ai)
    # Standalone "Keyframeless AI" helper: the version manifest (staged beside
    # the helper, read by KKUpdateChecker) + the pkg component version.
    bump_plist "Distribution/helper/kk-ai-helper.plist"
    bump_pkgproj "co.overpolish.keyframeless.KeyframelessAI"
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
esac

if [[ "$CREATE_CHANGELOG" == true ]]; then
  create_changelog_md
  echo ""
  echo "Done - $COMPONENT bumped to $VERSION"
  echo "  edit docs/changelog/$COMPONENT/$VERSION.md, then run scripts/build-changelog.py"
else
  echo ""
  echo "Done - $COMPONENT bumped to $VERSION (alpha; no changelog entry)"
fi
