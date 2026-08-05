#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Dev loop for the shared local-AI helper WITHOUT installing Kai
# package. Builds kk-ai-helper and runs it manually, bound to the app-group socket.
#
# Because SharedHelperRunner connects to the socket BEFORE trying to wake/launch the
# helper, a manually-run helper is picked up transparently: just leave this running
# and trigger a local AI action in a plugin (Canvas etc.). No signing, no launchd, no
# entitlement needed here - the --socket arg makes the helper bind the path directly
# and skip the app-group lookup + Mach-service wake.
#
# Usage: run-dev-helper.sh [debug|release]   (default: release - MLX debug inference
#        is painfully slow; release compiles once then iterates fast)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
GROUP="group.com.keyframeless"
GC="$HOME/Library/Group Containers/$GROUP"
SOCK="$GC/kkai.sock"
CACHE="$GC/huggingface/hub"

mkdir -p "$CACHE"

echo "Building kk-ai-helper ($CONFIG)..."
swift build --package-path "$ROOT/KeyframelessAI" -c "$CONFIG" --product kk-ai-helper

BIN="$ROOT/KeyframelessAI/.build/$CONFIG/kk-ai-helper"
[[ -x "$BIN" ]] || { echo "Error: $BIN not found"; exit 1; }

# `swift build` can't compile MLX's Metal shader library (no Metal toolchain in SPM),
# so the executable ships without one and MLX aborts at first GPU use. Reuse a
# default.metallib from any recent Xcode build (same pinned mlx-swift); if none is
# around (all plugins are thin now and don't build MLX), fall back to an xcodebuild of
# the helper itself, which DOES produce one. Colocate it as mlx.metallib (MLX lookup #1).
METALLIB="$(find "$HOME/Library/Developer/Xcode/DerivedData" /tmp -name 'default.metallib' -path '*Cmlx*' 2>/dev/null -exec stat -f '%m %N' {} \; | sort -rn | head -1 | cut -d' ' -f2-)"
if [[ -z "$METALLIB" ]]; then
	echo "No metallib around - building one via xcodebuild (one-time, slow)..."
	( cd "$ROOT/KeyframelessAI" && xcodebuild -scheme kk-ai-helper -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath /tmp/kkai-metallib build ) >/dev/null 2>&1
	METALLIB="$(find /tmp/kkai-metallib -name 'default.metallib' -path '*Cmlx*' 2>/dev/null | head -1)"
fi
[[ -n "$METALLIB" ]] || { echo "Error: could not obtain an MLX metallib"; exit 1; }
cp "$METALLIB" "$ROOT/KeyframelessAI/.build/$CONFIG/mlx.metallib"
echo "Staged MLX metallib from: ${METALLIB/#$HOME/~}"

# Clear any stale socket from a previous run so bind() doesn't hit EADDRINUSE.
[[ -S "$SOCK" ]] && rm -f "$SOCK"

echo ""
echo "Running helper -> $SOCK"
echo "  model cache: $CACHE"
echo "  Trigger a local AI action in a plugin now. Ctrl-C to stop."
echo ""
HF_HUB_CACHE="$CACHE" exec "$BIN" --socket "$SOCK"
