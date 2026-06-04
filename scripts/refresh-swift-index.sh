#!/usr/bin/env bash
#
# Refresh SourceKit-LSP's build-flag cache so VSCode resolves Swift correctly.
#
# Swift files are served by SourceKit-LSP (the Swift extension), NOT clangd. It reads
# build flags from xcode-build-server's `.compile` (via buildServer.json). That cache
# goes stale when you add/move Swift files, change a module, or build fresh - then you
# see "Cannot find X in scope" (a sibling type) or "No such module 'KeyframelessAI'"
# (a dependency whose build args aren't cached).
#
# This rebuilds the Swift-bearing schemes and re-parses their logs into `.compile`.
# Swift compiles a whole module at once, so a normal build re-emits the module compile
# (no clean needed). After it finishes, reload: Cmd-Shift-P -> "Swift: Restart LSP Server".

set -uo pipefail
cd "$(dirname "$0")/.."
WS="Keyframeless.xcworkspace"

# KeyframelessAI first (the shared module), then the workflow extension (which imports
# it - building it caches the module-search-path so `import KeyframelessAI` resolves).
SCHEMES=(
  "KeyframelessAI"
  "Keyframeless X FCP"
)

for s in "${SCHEMES[@]}"; do
  echo "==> $s"
  xcodebuild -workspace "$WS" -scheme "$s" -configuration Debug build 2>/dev/null \
    | xcode-build-server parse -a || true
done

echo ""
echo "Done. Reload: Cmd-Shift-P -> 'Swift: Restart LSP Server'."
