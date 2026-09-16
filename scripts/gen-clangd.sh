#!/usr/bin/env bash
# Configure source indexing after a Debug build.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
derived=${MM_DERIVED_DATA:-$root/DerivedData/Keyframeless}
sdk=$(xcrun --show-sdk-path)
python3 - "$root" "$derived" "$sdk" <<'PY'
import json, sys
from pathlib import Path
root, derived, sdk = map(Path, sys.argv[1:])
products = derived / 'Build/Products/Debug'
base = ['-fmodules', '-isysroot', str(sdk), '-F'+str(products), '-F/Library/Developer/Frameworks']
blocks = []
for component, path in [('MagicMove', 'MagicMove/MagicMove'), ('MotionTiming', 'MotionTiming/Sources'), ('OSCControls', 'OSCControls/Sources'), ('InspectorControls', 'InspectorControls/Sources'), ('RenderSupport', 'RenderSupport/Sources'), ('PluginPreferences', 'PluginPreferences/Sources')]:
    flags = list(base)
    if component not in ('MotionTiming', 'OSCControls'): flags += ['-fobjc-arc']
    flags += ['-I'+str(p) for p in sorted({h.parent for h in (root/path).rglob('*.h')})]
    if component == 'MagicMove':
        for module in ['MotionTiming', 'OSCControls', 'InspectorControls', 'RenderSupport', 'PluginPreferences']:
            flags += ['-I'+str(root/module/'Sources'/module/'include')]
            modulemap = derived/'Build/Intermediates.noindex/GeneratedModuleMaps'/(module+'.modulemap')
            if modulemap.exists(): flags += ['-fmodule-map-file='+str(modulemap)]
    blocks += ['If:\n  PathMatch: '+component+'/.*\nCompileFlags:\n  Add: '+json.dumps(flags)]
(root/'.clangd').write_text('\n---\n'.join(blocks)+'\n')
print('Updated', root/'.clangd')
PY
