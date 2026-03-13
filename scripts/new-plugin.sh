#!/bin/bash
#
# new-plugin.sh — Scaffold a new Keyframeless plugin from the Rounded template.
#
# Usage:
#   ./scripts/new-plugin.sh <PluginName> [--bundle-prefix <prefix>] [--add-to-workspace]
#
# Example:
#   ./scripts/new-plugin.sh Glitch
#   ./scripts/new-plugin.sh BlurEdge --add-to-workspace

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $(basename "$0") <PluginName> [options]"
    echo ""
    echo "  PluginName              PascalCase name (e.g. Glitch, BlurEdge)"
    echo ""
    echo "Options:"
    echo "  --bundle-prefix <str>   Bundle ID prefix (default: co.overpolish.keyframeless)"
    echo "  --add-to-workspace      Add new project to Keyframeless.xcworkspace"
    echo "  -h, --help              Show this message"
    echo ""
    echo "Example:"
    echo "  ./scripts/new-plugin.sh Glitch --add-to-workspace"
    exit 1
}

log()  { echo "  $*"; }
ok()   { echo "✓ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

# ── Args ─────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && usage

PLUGIN_NAME="$1"; shift
BUNDLE_PREFIX="co.overpolish.keyframeless"
ADD_TO_WORKSPACE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-prefix) BUNDLE_PREFIX="$2"; shift 2 ;;
        --add-to-workspace) ADD_TO_WORKSPACE=true; shift ;;
        -h|--help) usage ;;
        *) fail "Unknown option: $1" ;;
    esac
done

# Validate PascalCase
if ! [[ "$PLUGIN_NAME" =~ ^[A-Z][a-zA-Z0-9]*$ ]]; then
    fail "PluginName must be PascalCase and start with a capital letter (e.g. MyPlugin)"
fi

PLUGIN_ID="${BUNDLE_PREFIX}.${PLUGIN_NAME}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE="$REPO_ROOT/Rounded"
DEST="$REPO_ROOT/$PLUGIN_NAME"
WORKSPACE="$REPO_ROOT/Keyframeless.xcworkspace/contents.xcworkspacedata"

# ── Pre-flight checks ─────────────────────────────────────────────────────────

[[ -d "$SOURCE" ]] || fail "Template source not found: $SOURCE"
[[ -d "$DEST" ]]   && fail "Destination already exists: $DEST"

# ── Known UUIDs to replace ───────────────────────────────────────────────────

# These are Rounded's fixed UUIDs from Info.plist — must be unique per plugin.
OLD_UUID_EFFECT="A5D350B8-198F-499E-A35A-A6CE420473E4"
OLD_UUID_OSC="C1E3B919-E259-42BA-B362-169AF0CD2390"
OLD_UUID_GROUP="0A3BF7B0-01C2-4425-811E-A741C4C483DE"

NEW_UUID_EFFECT=$(uuidgen | tr '[:lower:]' '[:upper:]')
NEW_UUID_OSC=$(uuidgen | tr '[:lower:]' '[:upper:]')
NEW_UUID_GROUP=$(uuidgen | tr '[:lower:]' '[:upper:]')

# ── Step 1: Copy ──────────────────────────────────────────────────────────────

echo ""
echo "Creating plugin: $PLUGIN_NAME"
echo "  Bundle ID : $PLUGIN_ID"
echo "  Location  : $DEST"
echo ""

log "Copying Rounded template..."
cp -r "$SOURCE" "$DEST"
ok "Copied"

# ── Step 2: Rename files and directories ─────────────────────────────────────

log "Renaming files..."

# Rename inner source directory: NewPlugin/Rounded/ → NewPlugin/NewPlugin/
mv "$DEST/Rounded" "$DEST/$PLUGIN_NAME"

# Rename Xcode project: NewPlugin/Rounded.xcodeproj → NewPlugin/NewPlugin.xcodeproj
mv "$DEST/Rounded.xcodeproj" "$DEST/$PLUGIN_NAME.xcodeproj"

# Rename Metal shader file
mv "$DEST/$PLUGIN_NAME/Plugin/Rounded.metal" \
   "$DEST/$PLUGIN_NAME/Plugin/$PLUGIN_NAME.metal"

ok "Renamed"

# ── Step 3: String substitution in all text files ────────────────────────────

log "Substituting names..."

TEXT_FILES=$(find "$DEST" -type f \( \
    -name "*.h"                 \
    -o -name "*.m"              \
    -o -name "*.metal"          \
    -o -name "*.plist"          \
    -o -name "*.pbxproj"        \
    -o -name "*.xcscheme"       \
    -o -name "*.xcworkspacedata"\
    -o -name "*.entitlements"   \
\))

while IFS= read -r file; do
    # Replace bundle ID first (more specific than bare "Rounded")
    sed -i '' "s/co\.overpolish\.keyframeless\.Rounded/$PLUGIN_ID/g" "$file"
    # Replace all remaining "Rounded" occurrences
    sed -i '' "s/Rounded/$PLUGIN_NAME/g" "$file"
done <<< "$TEXT_FILES"

ok "Substituted"

# ── Step 4: Generate fresh Info.plist UUIDs ───────────────────────────────────

log "Generating new UUIDs..."

PLIST="$DEST/$PLUGIN_NAME/Plugin/Info.plist"

sed -i '' "s/$OLD_UUID_EFFECT/$NEW_UUID_EFFECT/g" "$PLIST"
sed -i '' "s/$OLD_UUID_OSC/$NEW_UUID_OSC/g"       "$PLIST"
sed -i '' "s/$OLD_UUID_GROUP/$NEW_UUID_GROUP/g"   "$PLIST"

ok "UUIDs: effect=$NEW_UUID_EFFECT"
ok "       osc   =$NEW_UUID_OSC"
ok "       group =$NEW_UUID_GROUP"

# ── Step 5 (optional): Add to workspace ──────────────────────────────────────

if $ADD_TO_WORKSPACE; then
    log "Adding to workspace..."

    if [[ ! -f "$WORKSPACE" ]]; then
        fail "Workspace not found: $WORKSPACE"
    fi

    NEW_REF="   <FileRef\n      location = \"group:${PLUGIN_NAME}/${PLUGIN_NAME}.xcodeproj\">\n   </FileRef>"

    # Insert before closing </Workspace> tag
    sed -i '' "s|</Workspace>|${NEW_REF}\n</Workspace>|" "$WORKSPACE"

    ok "Added to Keyframeless.xcworkspace"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "Done! $PLUGIN_NAME is ready."
echo ""
echo "Next steps:"
echo "  1. open $PLUGIN_NAME/$PLUGIN_NAME.xcodeproj"
echo "  2. Set your signing team in Build Settings → All → Signing"
echo "  3. Customize Plugin.m, OSC.m, and $PLUGIN_NAME.metal"
echo "  4. Update the plugin display name in $PLUGIN_NAME/$PLUGIN_NAME/Plugin/Info.plist"
echo ""
