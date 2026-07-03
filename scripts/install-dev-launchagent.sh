#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Dev loop that exercises the REAL launchd on-demand wake path (NSXPC Mach-service
# lookup -> launchd launches the helper) with your local build, without building the
# "Keyframeless AI" installer. Signs a release kk-ai-helper with the app-group
# entitlement + hardened runtime, drops a per-user LaunchAgent pointing at it, and
# bootstraps it. After this, a local AI action in a plugin wakes THIS binary.
#
# Iterate: rebuild + re-sign, then
#   launchctl kickstart -k gui/$(id -u)/co.overpolish.keyframeless.aihelper
#
# Tear down:
#   launchctl bootout gui/$(id -u)/co.overpolish.keyframeless.aihelper
#   rm ~/Library/LaunchAgents/co.overpolish.keyframeless.aihelper.plist
#
# Usage: install-dev-launchagent.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="co.overpolish.keyframeless.aihelper"
ENT="$ROOT/Distribution/helper/kk-ai-helper.entitlements"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

echo "Building + signing kk-ai-helper (release)..."
swift build --package-path "$ROOT/KeyframelessAI" -c release --product kk-ai-helper
BIN="$ROOT/KeyframelessAI/.build/release/kk-ai-helper"
[[ -x "$BIN" ]] || { echo "Error: $BIN not found"; exit 1; }

codesign --force --options runtime \
  --identifier co.overpolish.keyframeless.aihelper \
  --entitlements "$ENT" \
  --sign "Developer ID Application" \
  "$BIN"
echo "Signed: $(codesign -dvv "$BIN" 2>&1 | grep -m1 Authority || true)"

mkdir -p "$HOME/Library/LaunchAgents"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
	</array>
	<key>MachServices</key>
	<dict>
		<key>group.co.overpolish.keyframeless.aihelper</key>
		<true/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
EOF
echo "Wrote dev LaunchAgent -> $PLIST"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
echo ""
echo "Bootstrapped. Trigger a local AI action in a plugin - launchd will wake this build."
echo "Iterate: swift build ... && launchctl kickstart -k gui/$UID_NUM/$LABEL"
