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
sdkframeworks = '-F/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks'
base = ['-fmodules', '-isysroot', str(sdk), '-F'+str(products), '-F/Library/Developer/Frameworks']
modulemaps = derived/'Build/Intermediates.noindex/GeneratedModuleMaps'
# Every package that compiles against FxPlug headers needs the SDK search path
# and the module maps of the packages it imports.
dependencies = {
    'MagicMove': ['MotionTiming', 'OSCControls', 'OSCViewer', 'InspectorControls', 'RenderSupport',
                  'PluginPreferences', 'PluginHost', 'PoseLanes'],
    'OSCViewer': ['OSCControls', 'RenderSupport'],
    'PluginHost': ['InspectorControls', 'OSCViewer', 'RenderSupport'],
    'PoseLanes': ['PluginHost', 'InspectorControls', 'MotionTiming', 'PluginPreferences'],
}
blocks = []
for component, path in [('MagicMove', 'MagicMove/MagicMove'), ('MotionTiming', 'MotionTiming/Sources'), ('OSCControls', 'OSCControls/Sources'), ('OSCViewer', 'OSCViewer/Sources'), ('InspectorControls', 'InspectorControls/Sources'), ('RenderSupport', 'RenderSupport/Sources'), ('PluginPreferences', 'PluginPreferences/Sources'), ('PluginHost', 'PluginHost/Sources'), ('PoseLanes', 'PoseLanes/Sources')]:
    flags = list(base)
    if component not in ('MotionTiming', 'OSCControls'): flags += ['-fobjc-arc']
    flags += ['-I'+str(p) for p in sorted({h.parent for h in (root/path).rglob('*.h')})]
    if component in dependencies and sdkframeworks not in flags: flags += [sdkframeworks]
    for module in dependencies.get(component, []):
        flags += ['-I'+str(root/module/'Sources'/module/'include')]
        modulemap = modulemaps/(module+'.modulemap')
        if modulemap.exists(): flags += ['-fmodule-map-file='+str(modulemap)]
    blocks += ['If:\n  PathMatch: '+component+'/.*\nCompileFlags:\n  Add: '+json.dumps(flags)]
(root/'.clangd').write_text('\n---\n'.join(blocks)+'\n')
print('Updated', root/'.clangd')
PY
