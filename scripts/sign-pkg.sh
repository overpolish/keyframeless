#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Signs, notarizes, and staples a built .pkg installer in place.
#
# Usage: sign-pkg.sh <pkg-name> <apple-id> <team-id>
#   <pkg-name>  base name (no .pkg) of the installer in Distribution/build/,
#               e.g. "Keyframeless", "Rounded", "Keyframeless X"

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/Distribution/build"

usage() {
  echo "Usage: sign-pkg.sh <pkg-name> <apple-id> <team-id>"
  exit 1
}

if [[ $# -ne 3 ]]; then
  usage
fi

PKG_NAME="$1"
APPLE_ID="$2"
TEAM_ID="$3"
UNSIGNED="$BUILD_DIR/$PKG_NAME.pkg"
SIGNED="$BUILD_DIR/$PKG_NAME-signed.pkg"

if [[ ! -f "$UNSIGNED" ]]; then
  echo "Error: $UNSIGNED not found. Build the installer with Packages first."
  exit 1
fi

echo "Signing..."
productsign --sign "Developer ID Installer" "$UNSIGNED" "$SIGNED"

echo ""
echo "Notarizing..."
xcrun notarytool submit "$SIGNED" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --wait

echo ""
echo "Stapling..."
xcrun stapler staple "$SIGNED"
xcrun stapler validate "$SIGNED"

echo ""
echo "Verifying..."
spctl --assess --type install "$SIGNED"

echo ""
echo "Cleaning up..."
rm "$UNSIGNED"
mv "$SIGNED" "$UNSIGNED"

echo ""
echo "Done - $UNSIGNED is signed, notarized, and ready to distribute."
