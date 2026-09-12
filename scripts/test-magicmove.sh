#!/bin/sh
# Run regression tests without rebuilding or registering the installed plugin.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
case "${1:-}" in
  "") gpu=yes ;;
  --cpu-only) gpu=no ;;
  *) echo "Usage: scripts/test-magicmove.sh [--cpu-only]" >&2; exit 2 ;;
esac
"$root/MotionTiming/Tests/run.sh"
"$root/MagicMove/Tests/run.sh"
if [ "$gpu" = yes ]; then
  "$root/MagicMove/Tests/run-shader.sh"
  "$root/MagicMove/Tests/run-blur.sh"
fi
