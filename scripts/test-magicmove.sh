#!/bin/sh
# Run regression tests without rebuilding or registering the installed plugin.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
case "${1:-}" in
  "") gpu=yes ;;
  --cpu-only) gpu=no ;;
  *) echo "Usage: scripts/test-magicmove.sh [--cpu-only]" >&2; exit 2 ;;
esac

# The suites compile the working tree, but Motion and FCP run whichever copy of
# the plugin PlugInKit has registered, and it keeps one registration per plugin
# identifier: a stale copy in another build directory holds it even after this
# one is rebuilt, so host checks can silently exercise an old binary. Report
# that here rather than leaving it to be noticed in the host.
derived="${MM_DERIVED_DATA:-$root/DerivedData/Keyframeless}"
registered=$(pluginkit -m -v -i com.keyframeless.MagicMoveNext.PlugIn 2>/dev/null |
  sed -n 's/.*	\(\/.*\.pluginkit\).*/\1/p' | head -1)
case "$registered" in
  "") echo "Note: no MagicMove plug-in is registered; Motion and FCP will not see it." >&2 ;;
  "$derived"/*) ;;
  *) cat >&2 <<WARNING
Warning: Motion and FCP run a different build than these tests compile.
  registered: $registered
  building:   $derived
Point the host at this build with:
  pluginkit -a "$derived/Build/Products/Debug/MagicMove.app/Contents/PlugIns/MagicMove XPC Service.pluginkit"
and relaunch the host. Delete stale MagicMove.app copies in other build
directories; they share one plug-in identifier and can take the registration back.
WARNING
    ;;
esac
"$root/PluginPreferences/Tests/run.sh"
"$root/InspectorControls/Tests/run.sh"
"$root/MotionTiming/Tests/run.sh"
"$root/OSCControls/Tests/run.sh"
"$root/OSCViewer/Tests/run.sh"
"$root/PluginHost/Tests/run.sh"
"$root/PoseLanes/Tests/run.sh"
if [ "$gpu" = yes ]; then
  "$root/RenderSupport/Tests/run.sh"
else
  "$root/RenderSupport/Tests/run.sh" --cpu-only
fi
"$root/MagicMove/Tests/run.sh"
if [ "$gpu" = yes ]; then
  "$root/MagicMove/Tests/run-shader.sh"
  "$root/MagicMove/Tests/run-blur.sh"
fi
# The committed Motion template publishes the plug-in's controls in the order
# they are registered, so a parameter change that is not regenerated would ship
# an inspector that no longer matches the code.
"$root/scripts/motion-template.py" check
