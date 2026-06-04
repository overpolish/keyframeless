#!/usr/bin/env bash
#
# Generate a self-contained .clangd for VSCode's clangd. We do NOT rely on
# compile_commands.json (the editor's clangd doesn't reliably discover it); .clangd
# is always read, so all flags live here.
#
# Structure:
#  - base block: SDK + frameworks + the KIT include dirs + the kit VFS overlay
#    (the overlay maps <KeyframelessKit/X.h> onto the SOURCE header so it isn't
#    double-defined alongside the quoted "X.h" -> fixes "redefinition" errors).
#  - one `If: PathMatch` block per plugin with ONLY that plugin's dirs, so the 4
#    copies of Plugin.h / Constants.h / ShaderTypes.h don't collide across plugins.
#
# Re-run after adding/moving header directories (e.g. new subfolders).
# Then reload clangd: Cmd-Shift-P -> "clangd: Restart language server".

set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
OUT=".clangd"
SDK="$(xcrun --show-sdk-path)"
DD="$REPO/DerivedData/Keyframeless"

# Kit VFS overlay (hash changes per build; pick the newest).
KIT_VFS="$(ls -t "$DD"/Build/Intermediates.noindex/KeyframelessKit.build/Debug/KeyframelessKit-*-VFS/all-product-headers.yaml 2>/dev/null | head -1)"
CL_MODMAP="$DD/Build/Intermediates.noindex/GeneratedModuleMaps/CocoaLumberjack.modulemap"
CL_INC="$DD/SourcePackages/checkouts/CocoaLumberjack/Sources/CocoaLumberjack/include"

incdirs() {  # $1 = source root -> emit "    - -I<dir>" for every dir holding a header
  find "$1" -type f \( -name '*.h' \) -not -path '*/build/*' 2>/dev/null \
    | xargs -n1 dirname | sort -u | sed "s#^#    - -I#"
}

{
  echo "CompileFlags:"
  echo "  Add:"
  echo "    - -fobjc-arc"
  echo "    - -fmodules"
  echo "    - -fmodule-name=KeyframelessKit"
  echo "    - -fmodules-cache-path=/tmp/clangd-modules-cache"
  echo "    - -isysroot"
  echo "    - $SDK"
  echo "    - -F$DD/Build/Products/Debug"
  echo "    - -F/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks"
  [ -n "$KIT_VFS" ] && { echo "    - -ivfsoverlay"; echo "    - $KIT_VFS"; }
  [ -f "$CL_MODMAP" ] && echo "    - -fmodule-map-file=$CL_MODMAP"
  [ -d "$CL_INC" ] && echo "    - -I$CL_INC"
  incdirs "$REPO/KeyframelessKit/KeyframelessKit"
  echo "    - -ferror-limit=0"

  for plug in MagicMove Rounded Glow Canvas; do
    [ -d "$REPO/$plug/$plug" ] || continue
    echo ""
    echo "---"
    echo "If:"
    echo "  PathMatch: $plug/.*"
    echo "CompileFlags:"
    echo "  Add:"
    incdirs "$REPO/$plug/$plug"
  done

  cat <<'EOF'

---
# Metal shaders as C++ (closest grammar for clangd; real compile is xcrun metal).
If:
  PathMatch: .*\.metal
CompileFlags:
  Add:
    - -x
    - c++
    - -std=c++17
Diagnostics:
  Suppress: "*"
EOF
} > "$OUT"

rm -rf "$REPO/.cache" /tmp/clangd-modules-cache
echo "Wrote $OUT (kit VFS: $([ -n "$KIT_VFS" ] && echo yes || echo MISSING - build the kit first))"
echo "Reload clangd: Cmd-Shift-P -> 'clangd: Restart language server'."
