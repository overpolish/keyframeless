#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Converts an FxPlug plugin (Canvas/Shader) to the thin-client model:
# removes the embedded `kk-ai-helper` target so the ~40 MB MLX engine no longer ships
# in the plugin, and gives the sandboxed XPC Service the app-group entitlement so it
# reaches the shared, separately-installed helper. Idempotent-ish: re-running after a
# partial run is safe (it skips what's already gone).
#
# It edits the .pbxproj as TEXT (targeted line removals + one inserted build setting)
# to keep the diff clean, then you must open the project in Xcode and build to verify.
#
# Usage: convert-plugin-to-thin.py <PluginName>   (e.g. Canvas)

import os
import re
import sys

if len(sys.argv) != 2:
    sys.exit("Usage: convert-plugin-to-thin.py <PluginName>")

PLUG = sys.argv[1]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, PLUG, f"{PLUG}.xcodeproj", "project.pbxproj")
if not os.path.isfile(PBX):
    sys.exit(f"Not found: {PBX}")

src = open(PBX).read()
orig = src


def die(msg):
    sys.exit(f"[{PLUG}] {msg}")


# --- discover the kk-ai-helper native target id ---
m = re.search(r'([0-9A-F]{24}) /\* kk-ai-helper \*/ = \{\s*isa = PBXNativeTarget;', src)
helper_id = m.group(1) if m else None

# remove any array reference to this id (id is globally unique; the comment label
# varies - "CopyFiles" vs "Embed AI Helper" etc - so match any comment).
def drop_array_line(text, ref):
    if not ref:
        return text, 0
    return re.compile(r'\n\t+' + ref + r' /\* [^*]*\*/,').subn('', text)


if helper_id:
    # build file that embeds the helper (comment "kk-ai-helper in <PhaseName>")
    bf = re.search(r'([0-9A-F]{24}) /\* kk-ai-helper in [^*]*\*/', src)
    if not bf:
        die("helper target present but no 'kk-ai-helper in <phase>' build file")
    build_file_id = bf.group(1)
    # the copy-files phase (any name) whose files array lists that build file
    copy_phase_id = None
    for pm in re.finditer(
        r'([0-9A-F]{24}) /\* [^*]*\*/ = \{\s*isa = PBXCopyFilesBuildPhase;(.*?)\n\t\t\};',
        src, re.S):
        if build_file_id in pm.group(2):
            copy_phase_id = pm.group(1)
            break
    if not copy_phase_id:
        die("could not find the copy-files phase embedding kk-ai-helper")

    dep = re.search(r'([0-9A-F]{24}) /\* PBXTargetDependency \*/ = \{\s*isa = PBXTargetDependency;\s*target = '
                    + helper_id, src)
    dep_id = dep.group(1) if dep else None

    src, n1 = drop_array_line(src, copy_phase_id)
    src, n2 = drop_array_line(src, dep_id)
    src, n3 = drop_array_line(src, helper_id)
    print(f"[{PLUG}] removed: copy-phase ref x{n1}, dependency ref x{n2}, target-list ref x{n3}")
else:
    print(f"[{PLUG}] no kk-ai-helper target (already removed) - skipping removal")

# --- add app-group entitlements to the XPC Service target's build configs ---
# Keyframeless X is app + FCP-extension (no "XPC Service" target) and its extension
# already carries the app-group entitlement, so there it's helper-removal only.
xt = re.search(r'/\* XPC Service \*/ = \{\s*isa = PBXNativeTarget;.*?buildConfigurationList = ([0-9A-F]{24})',
               src, re.S)
if not xt:
    if src != orig:
        open(PBX, "w").write(src)
        print(f"[{PLUG}] no 'XPC Service' target - wrote helper removal only "
              "(ensure the extension already has the app-group entitlement)")
    else:
        print(f"[{PLUG}] no 'XPC Service' target and nothing to remove")
    sys.exit(0)

ent_rel = f"{PLUG}/Plugin/{PLUG}PluginEntitlements.entitlements"
ent_abs = os.path.join(ROOT, PLUG, PLUG, "Plugin", f"{PLUG}PluginEntitlements.entitlements")
cfg_list_id = xt.group(1)
cl = re.search(cfg_list_id + r' /\* Build configuration list.*?buildConfigurations = \((.*?)\);', src, re.S)
if not cl:
    die("could not find XPC Service configuration list")
cfg_ids = re.findall(r'([0-9A-F]{24})', cl.group(1))

added = 0
for cid in cfg_ids:
    cm = re.search(cid + r' /\* (?:Debug|Release) \*/ = \{\s*isa = XCBuildConfiguration;\s*buildSettings = \{',
                   src)
    if not cm:
        continue
    block_start = cm.end()
    # already set?
    tail = src[block_start:block_start + 4000]
    if 'CODE_SIGN_ENTITLEMENTS' in tail.split('};')[0]:
        continue
    ins = f'\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = "{ent_rel}";'
    src = src[:block_start] + ins + src[block_start:]
    added += 1
print(f"[{PLUG}] CODE_SIGN_ENTITLEMENTS added to {added} XPC Service config(s)")

if src != orig:
    open(PBX, "w").write(src)
    print(f"[{PLUG}] wrote {PBX}")
else:
    print(f"[{PLUG}] no pbxproj changes")

# --- create the entitlements file if missing ---
if not os.path.isfile(ent_abs):
    os.makedirs(os.path.dirname(ent_abs), exist_ok=True)
    open(ent_abs, "w").write(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n<dict>\n'
        '\t<key>com.apple.security.application-groups</key>\n'
        '\t<array>\n\t\t<string>group.co.overpolish.keyframeless</string>\n\t</array>\n'
        '</dict>\n</plist>\n')
    print(f"[{PLUG}] created {ent_rel}")
else:
    print(f"[{PLUG}] entitlements already exist: {ent_rel}")
