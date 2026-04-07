#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the .pkg installer with Packages, then signs, notarizes, and staples it.
#
# Usage: build-and-sign.sh <apple-id> <team-id>

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKGPROJ="$ROOT/Distribution/Keyframeless.pkgproj"
BUILD_DIR="$ROOT/Distribution/build"
UNSIGNED="$BUILD_DIR/Keyframeless.pkg"
SIGNED="$BUILD_DIR/Keyframeless-signed.pkg"

usage() {
  echo "Usage: build-and-sign.sh <apple-id> <team-id>"
  exit 1
}

if [[ $# -ne 2 ]]; then
  usage
fi

APPLE_ID="$1"
TEAM_ID="$2"

if ! command -v packagesbuild &>/dev/null; then
  echo "Error: packagesbuild not found. Install Packages from http://s.sudre.free.fr/Software/Packages/about.html"
  exit 1
fi

echo "Building .pkg..."
packagesbuild "$PKGPROJ"

if [[ ! -f "$UNSIGNED" ]]; then
  echo "Error: build failed — $UNSIGNED not found."
  exit 1
fi

echo ""
"$ROOT/scripts/sign-pkg.sh" "$APPLE_ID" "$TEAM_ID"

echo "Copying manifest.json to build folder..."
cp "$ROOT/manifest.json" "$BUILD_DIR/manifest.json"
echo "Done — manifest.json copied to $BUILD_DIR/"
