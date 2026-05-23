#!/bin/bash
#
# new-plugin.sh - Scaffold a new Keyframeless plugin from the Template.
#
# Usage:
#   ./scripts/new-plugin.sh <PluginName> [--type effect|title|generator] [--bundle-prefix <prefix>] [--add-to-workspace]
#
# Example:
#   ./scripts/new-plugin.sh Glitch
#   ./scripts/new-plugin.sh BlurEdge --type effect --add-to-workspace

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $(basename "$0") <PluginName> [options]"
    echo ""
    echo "  PluginName              PascalCase name (e.g. Glitch, BlurEdge)"
    echo ""
    echo "Options:"
    echo "  --type <type>           Plugin type: effect (default), title, generator"
    echo "  --bundle-prefix <str>   Bundle ID prefix (default: co.overpolish.keyframeless)"
    echo "  --add-to-workspace      Add new project to Keyframeless.xcworkspace"
    echo "  -h, --help              Show this message"
    echo ""
    echo "Example:"
    echo "  ./scripts/new-plugin.sh Glitch --type effect --add-to-workspace"
    exit 1
}

log()  { echo "  $*"; }
ok()   { echo "✓ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

# Convert PascalCase to lowercase for keys (e.g. BlurEdge -> bluredge)
to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# ── Args ─────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && usage

PLUGIN_NAME="$1"; shift
BUNDLE_PREFIX="co.overpolish.keyframeless"
PLUGIN_TYPE="effect"
ADD_TO_WORKSPACE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) PLUGIN_TYPE="$2"; shift 2 ;;
        --bundle-prefix) BUNDLE_PREFIX="$2"; shift 2 ;;
        --add-to-workspace) ADD_TO_WORKSPACE=true; shift ;;
        -h|--help) usage ;;
        *) fail "Unknown option: $1" ;;
    esac
done

# Validate plugin type
case "$PLUGIN_TYPE" in
    effect)    MOTION_TEMPLATE_TYPE="Effects" ;;
    title)     MOTION_TEMPLATE_TYPE="Titles" ;;
    generator) MOTION_TEMPLATE_TYPE="Generators" ;;
    *) fail "Invalid --type '$PLUGIN_TYPE'. Must be: effect, title, or generator" ;;
esac

# Validate PascalCase
if ! [[ "$PLUGIN_NAME" =~ ^[A-Z][a-zA-Z0-9]*$ ]]; then
    fail "PluginName must be PascalCase and start with a capital letter (e.g. MyPlugin)"
fi

PLUGIN_ID="${BUNDLE_PREFIX}.${PLUGIN_NAME}"
PLUGIN_KEY=$(to_lower "$PLUGIN_NAME")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE="$REPO_ROOT/Template"
DEST="$REPO_ROOT/$PLUGIN_NAME"
WORKSPACE="$REPO_ROOT/Keyframeless.xcworkspace/contents.xcworkspacedata"
PKGPROJ="$REPO_ROOT/Distribution/Keyframeless.pkgproj"
MANIFEST="$REPO_ROOT/manifest.json"
BUMP_SCRIPT="$REPO_ROOT/scripts/bump-version.sh"
UPDATE_CHECKER="$REPO_ROOT/KeyframelessKit/KeyframelessKit/Update/KKUpdateChecker.m"

# ── Pre-flight checks ─────────────────────────────────────────────────────────

[[ -d "$SOURCE" ]] || fail "Template source not found: $SOURCE"
[[ -d "$DEST" ]]   && fail "Destination already exists: $DEST"

# ── Known UUIDs to replace ───────────────────────────────────────────────────

# These are Template's fixed UUIDs from Info.plist - must be unique per plugin.
OLD_UUID_EFFECT="E62BB814-A76B-4438-B1B1-090145A42CC2"
OLD_UUID_OSC="A1B70771-EDBB-4D3B-81B6-DB70B74CEDE4"
OLD_UUID_GROUP="450150AA-FB81-4198-BB73-058CFEF39F5C"

NEW_UUID_EFFECT=$(uuidgen | tr '[:lower:]' '[:upper:]')
NEW_UUID_OSC=$(uuidgen | tr '[:lower:]' '[:upper:]')
NEW_UUID_GROUP=$(uuidgen | tr '[:lower:]' '[:upper:]')

# ── Step 1: Copy ──────────────────────────────────────────────────────────────

echo ""
echo "Creating plugin: $PLUGIN_NAME"
echo "  Bundle ID : $PLUGIN_ID"
echo "  Type      : $PLUGIN_TYPE ($MOTION_TEMPLATE_TYPE)"
echo "  Location  : $DEST"
echo ""

log "Copying Template..."
cp -r "$SOURCE" "$DEST"
ok "Copied"

# ── Step 2: Rename files and directories ─────────────────────────────────────

log "Renaming files..."

# Rename inner source directory: NewPlugin/Template/ → NewPlugin/NewPlugin/
mv "$DEST/Template" "$DEST/$PLUGIN_NAME"

# Rename Xcode project: NewPlugin/Template.xcodeproj → NewPlugin/NewPlugin.xcodeproj
mv "$DEST/Template.xcodeproj" "$DEST/$PLUGIN_NAME.xcodeproj"

# Rename Metal shader file
mv "$DEST/$PLUGIN_NAME/Plugin/Template.metal" \
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
    -o -name "*.strings"        \
\))

while IFS= read -r file; do
    # Replace bundle ID first (more specific than bare "Template")
    LC_ALL=C sed -i '' "s/co\.overpolish\.keyframeless\.Template/$PLUGIN_ID/g" "$file"
    # Replace all remaining "Template" occurrences
    LC_ALL=C sed -i '' "s/Template/$PLUGIN_NAME/g" "$file"
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

# ── Step 5: Register in manifest.json ─────────────────────────────────────────

log "Registering in manifest.json..."

python3 -c "
import json
with open('$MANIFEST', 'r') as f:
    m = json.load(f)
m['$PLUGIN_KEY'] = '1.0.0'
with open('$MANIFEST', 'w') as f:
    json.dump(m, f, indent=2)
    f.write('\n')
"

ok "Added '$PLUGIN_KEY' to manifest.json"

# ── Step 6: Register in bump-version.sh ───────────────────────────────────────

log "Registering in bump-version.sh..."

# Add to usage comment
sed -i '' "/^#   keyframelessx/a\\
#   $PLUGIN_KEY$(printf '%*s' $((13 - ${#PLUGIN_KEY})) '')$PLUGIN_NAME plugin" "$BUMP_SCRIPT"

# Add to usage() echo block
sed -i '' "/echo \"  keyframelessx/a\\
  echo \"  $PLUGIN_KEY$(printf '%*s' $((13 - ${#PLUGIN_KEY})) '')$PLUGIN_NAME plugin\"" "$BUMP_SCRIPT"

# Add plist_for_component case (match the line with 'echo ""')
sed -i '' "/keyframelessx) echo/i\\
    $PLUGIN_KEY) echo \"$PLUGIN_NAME/$PLUGIN_NAME/Plugin/Info.plist\" ;;" "$BUMP_SCRIPT"

# Add bump case before keyframelessx (match the standalone case line)
sed -i '' "/^  keyframelessx)$/i\\
\\
  $PLUGIN_KEY)\\
    bump_plist \"$PLUGIN_NAME/$PLUGIN_NAME/Wrapper Application/Info.plist\"\\
    bump_plist \"$PLUGIN_NAME/$PLUGIN_NAME/Plugin/Info.plist\"\\
    bump_fxplug \"$PLUGIN_NAME/$PLUGIN_NAME/Plugin/Info.plist\"\\
    bump_pkgproj \"$PLUGIN_ID\"\\
    ;;" "$BUMP_SCRIPT"

ok "Added '$PLUGIN_KEY' to bump-version.sh"

# ── Step 7: Register in KKUpdateChecker.m ─────────────────────────────────────

log "Registering in KKUpdateChecker.m..."

# Add to KKKnownComponents
sed -i '' "s|@\"magicmove\" : @\"MagicMove\"|@\"magicmove\" : @\"MagicMove\",\\
    @\"$PLUGIN_KEY\" : @\"$PLUGIN_NAME\"|" "$UPDATE_CHECKER"

# Add to KKBundleIDToComponent
sed -i '' "s|@\"MagicMove-XPC-Service\" : @\"magicmove\"|@\"MagicMove-XPC-Service\" : @\"magicmove\",\\
    @\"$PLUGIN_NAME\" : @\"$PLUGIN_KEY\",\\
    @\"$PLUGIN_NAME-XPC-Service\" : @\"$PLUGIN_KEY\"|" "$UPDATE_CHECKER"

ok "Added '$PLUGIN_NAME' to KKUpdateChecker.m"

# ── Step 8: Register in installer pkgproj ────────────────────────────────────

log "Registering in Keyframeless.pkgproj..."

if [[ ! -f "$PKGPROJ" ]]; then
    fail "Installer project not found: $PKGPROJ"
fi

PKG_UUID=$(uuidgen | tr '[:lower:]' '[:upper:]')
CHOOSER_UUID=$(uuidgen | tr '[:lower:]' '[:upper:]')

# Type label for installer description (capitalised)
case "$PLUGIN_TYPE" in
    effect)    TYPE_LABEL="Effect" ;;
    title)     TYPE_LABEL="Title" ;;
    generator) TYPE_LABEL="Generator" ;;
esac

# Render package template
PKG_BLOCK=$(LC_ALL=C sed \
    -e "s/__PLUGIN_NAME__/$PLUGIN_NAME/g" \
    -e "s/__PLUGIN_ID__/$PLUGIN_ID/g" \
    -e "s/__TEMPLATE_TYPE__/$MOTION_TEMPLATE_TYPE/g" \
    -e "s/__PKG_UUID__/$PKG_UUID/g" \
    "$SCRIPT_DIR/pkgproj-package.template")

# Render chooser template
CHOOSER_BLOCK=$(LC_ALL=C sed \
    -e "s/__PLUGIN_NAME__/$PLUGIN_NAME/g" \
    -e "s/__TYPE_LABEL__/$TYPE_LABEL/g" \
    -e "s/__PKG_UUID__/$PKG_UUID/g" \
    -e "s/__CHOOSER_UUID__/$CHOOSER_UUID/g" \
    "$SCRIPT_DIR/pkgproj-chooser.template")

python3 -c "
import sys
pkgproj = sys.argv[1]
pkg_block = sys.argv[2]
chooser_block = sys.argv[3]

with open(pkgproj, 'r') as f:
    content = f.read()

anchor_pkg = '\t</array>\n\t<key>PROJECT</key>'
assert anchor_pkg in content, 'Could not find package insertion anchor in pkgproj'
content = content.replace(anchor_pkg, pkg_block + '\n' + anchor_pkg, 1)

anchor_chooser = '\t\t\t\t\t\t</array>\n\t\t\t\t\t\t<key>REMOVED</key>'
assert anchor_chooser in content, 'Could not find chooser insertion anchor in pkgproj'
content = content.replace(anchor_chooser, chooser_block + anchor_chooser, 1)

with open(pkgproj, 'w') as f:
    f.write(content)
" "$PKGPROJ" "$PKG_BLOCK" "$CHOOSER_BLOCK"

ok "Added '$PLUGIN_NAME' to Keyframeless.pkgproj (pkg=$PKG_UUID)"

# ── Step 9 (optional): Add to workspace ──────────────────────────────────────

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
echo "  3. Customize Plugin+Parameters.m, Plugin+Render.m, OSC.m, and $PLUGIN_NAME.metal"
echo "  4. Update the plugin display name in en.lproj/InfoPlist.strings"
echo ""
