#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds a .pkg installer with Packages, then signs, notarizes, and staples it.
#
# Usage: build-and-sign.sh <target> <apple-id> <team-id>
#   <target>:
#     combined         the all-in-one Keyframeless.pkg (every plugin)
#     all              every plugin as its own per-product .pkg
#     <component>      one per-product .pkg (rounded|keyframelessx|magicmove|glow|canvas)
#
# Per-product builds GENERATE the single-product .pkgproj and its uninstaller from
# templates (split-pkgproj.py + uninstall.template), build, sign, then delete those
# temp files - so nothing per-plugin is committed (one template, not N near-copies).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/Distribution/build"
SPLIT="$ROOT/scripts/split-pkgproj.py"

usage() {
  echo "Usage: build-and-sign.sh <target> <apple-id> <team-id>"
  echo "  <target>: combined | all | rounded | keyframelessx | magicmove | glow | canvas"
  exit 1
}

if [[ $# -ne 3 ]]; then
  usage
fi

TARGET="$1"
APPLE_ID="$2"
TEAM_ID="$3"

if ! command -v packagesbuild &>/dev/null; then
  echo "Error: packagesbuild not found. Install Packages from http://s.sudre.free.fr/Software/Packages/about.html"
  exit 1
fi

# Temp files for the product currently being built; removed on any exit.
GEN_PKGPROJ=""
GEN_UNINSTALL=""
cleanup() {
  [[ -n "$GEN_PKGPROJ" ]] && rm -f "$GEN_PKGPROJ"
  [[ -n "$GEN_UNINSTALL" ]] && rm -f "$GEN_UNINSTALL"
  GEN_PKGPROJ=""
  GEN_UNINSTALL=""
}
trap cleanup EXIT

build_combined() {
  echo "Building Keyframeless (combined)..."
  packagesbuild "$ROOT/Distribution/Keyframeless.pkgproj"
  [[ -f "$BUILD_DIR/Keyframeless.pkg" ]] || {
    echo "Error: build failed - Keyframeless.pkg not found."
    exit 1
  }
  echo ""
  "$ROOT/scripts/sign-pkg.sh" "Keyframeless" "$APPLE_ID" "$TEAM_ID"
}

build_product() {
  local component="$1" name
  name="$(python3 "$SPLIT" --name "$component")"

  # Generate the single-product project + its uninstaller, then ensure they're
  # cleaned up even if the build or signing fails.
  GEN_PKGPROJ="$ROOT/Distribution/$name.pkgproj"
  GEN_UNINSTALL="$ROOT/Distribution/scripts/uninstall-$component"
  python3 "$SPLIT" "$component"

  echo ""
  echo "Building $name..."
  packagesbuild "$GEN_PKGPROJ"
  [[ -f "$BUILD_DIR/$name.pkg" ]] || {
    echo "Error: build failed - $name.pkg not found."
    exit 1
  }
  echo ""
  "$ROOT/scripts/sign-pkg.sh" "$name" "$APPLE_ID" "$TEAM_ID"

  cleanup
}

case "$TARGET" in
  combined)
    build_combined
    ;;
  all)
    for component in $(python3 "$SPLIT" --components); do
      build_product "$component"
    done
    ;;
  *)
    build_product "$TARGET"
    ;;
esac

echo ""
echo "Done."
