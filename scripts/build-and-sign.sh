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
#     <component>      one per-product .pkg (keyframelessx|canvas|shader|keyframelessai)
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
  echo "  <target>: combined | all | keyframelessx | canvas | shader | keyframelessai"
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

# The AI engine's payload is a built binary (unlike the plugins, whose .app is
# archived beforehand). Build kk-ai-helper with xcodebuild (only the Metal toolchain
# compiles MLX's metallib), thin to arm64 (MLX is Apple-Silicon), Developer-ID sign it
# with the app-group + hardened runtime, and stage it where the .pkgproj payload points
# (Distribution/helper/staging). No Xcode "archive" step is involved.
AI_STAGE="$ROOT/Distribution/helper/staging"

stage_ai_helper() {
  echo "Building + signing kk-ai-helper (xcodebuild, arm64)..."
  local dd; dd="$(mktemp -d)"
  ( cd "$ROOT/KeyframelessAI" && xcodebuild -scheme kk-ai-helper -configuration Release \
      -destination 'generic/platform=macOS' -derivedDataPath "$dd" build ) >/dev/null
  local prod="$dd/Build/Products/Release"
  [[ -x "$prod/kk-ai-helper" ]] || { echo "Error: kk-ai-helper not built"; rm -rf "$dd"; exit 1; }
  rm -rf "$AI_STAGE"; mkdir -p "$AI_STAGE"
  # Helper binary, thinned to arm64 (MLX is Apple-Silicon), Developer-ID signed.
  lipo "$prod/kk-ai-helper" -thin arm64 -output "$AI_STAGE/kk-ai-helper" 2>/dev/null \
    || cp "$prod/kk-ai-helper" "$AI_STAGE/kk-ai-helper"
  codesign --force --options runtime --timestamp \
    --identifier com.keyframeless.aihelper \
    --entitlements "$ROOT/Distribution/helper/kk-ai-helper.entitlements" \
    --sign "Developer ID Application" "$AI_STAGE/kk-ai-helper"
  chmod 0755 "$AI_STAGE/kk-ai-helper"
  # SwiftPM resource bundles MUST sit next to the executable or the helper traps at
  # runtime: KeyframelessAI_KeyframelessAI (Bundle.module - localization/knowledge),
  # mlx-swift_Cmlx (default.metallib), swift-transformers_Hub, swift-crypto_Crypto.
  # Ship the exact set xcodebuild produced.
  cp -R "$prod"/*.bundle "$AI_STAGE/"
  # Version manifest: installs beside the helper so KKUpdateChecker can read the
  # installed CFBundleShortVersionString (the "Keyframeless AI" update check).
  cp "$ROOT/Distribution/helper/kk-ai-helper.plist" "$AI_STAGE/kk-ai-helper.plist"
  codesign -dvv "$AI_STAGE/kk-ai-helper" 2>&1 | grep -m1 Authority || true
  rm -rf "$dd"
}

unstage_ai_helper() {
  rm -f "$AI_STAGE/kk-ai-helper" "$AI_STAGE/mlx.metallib" \
    "$AI_STAGE/kk-ai-helper.plist"
}

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
  local component="$1" name version
  name="$(python3 "$SPLIT" --name "$component")"
  version="$(python3 "$SPLIT" --version "$component")"

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

  # Stamp the product version onto the final installer (e.g. Canvas-v2.0.0.pkg).
  mv "$BUILD_DIR/$name.pkg" "$BUILD_DIR/$name-v$version.pkg"
  echo "  -> $name-v$version.pkg"

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
  keyframelessai)
    stage_ai_helper
    build_product keyframelessai
    unstage_ai_helper
    ;;
  *)
    build_product "$TARGET"
    ;;
esac

echo ""
echo "Done."
