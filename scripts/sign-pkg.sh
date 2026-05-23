#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Signs, notarizes, and staples the Keyframeless .pkg installer.
#
# Usage: sign-pkg.sh <apple-id> <team-id>

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/Distribution/build"
UNSIGNED="$BUILD_DIR/Keyframeless.pkg"
SIGNED="$BUILD_DIR/Keyframeless-signed.pkg"

usage() {
  echo "Usage: sign-pkg.sh <apple-id> <team-id>"
  exit 1
}

if [[ $# -ne 2 ]]; then
  usage
fi

APPLE_ID="$1"
TEAM_ID="$2"

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
