#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stop the pluginkit (XPC Service) from embedding its OWN copy of
# KeyframelessKit.framework - it shares the wrapper app's copy instead (the standard
# app-extension pattern). Saves ~6 MB per plugin. The pluginkit still LINKS the
# framework; it just finds the host app's copy at load time via an added rpath
# (@loader_path/../../../../Frameworks resolves from
# <App>/Contents/PlugIns/X.pluginkit/Contents/MacOS to <App>/Contents/Frameworks).
#
# Usage: dedup-kkit.py <PluginName>

import re
import sys

if len(sys.argv) != 2:
    sys.exit("Usage: dedup-kkit.py <PluginName>")
PLUG = sys.argv[1]
PBX = f"{PLUG}/{PLUG}.xcodeproj/project.pbxproj"
HOST_RPATH = "@loader_path/../../../../Frameworks"

p = open(PBX).read()
orig = p


def die(m):
    sys.exit(f"[{PLUG}] {m}")


# 1. Find the XPC Service target and the "Embed Frameworks" phase in ITS buildPhases.
xt = re.search(r"/\* XPC Service \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};", p, re.S)
if not xt:
    die("no XPC Service target")
phases = re.search(r"buildPhases = \((.*?)\);", xt.group(1), re.S).group(1)
embed_ids = [m.group(1) for m in re.finditer(r"([0-9A-F]{24}) /\* Embed Frameworks \*/", phases)]
if not embed_ids:
    print(f"[{PLUG}] no Embed Frameworks phase on XPC Service (already deduped?)")
else:
    phase_id = embed_ids[0]
    # In that phase's files, drop the KeyframelessKit build-file ref.
    def strip(m):
        body = m.group(0)
        body2 = re.sub(
            r"\n\t+[0-9A-F]{24} /\* KeyframelessKit\.framework in Embed Frameworks \*/,",
            "", body)
        return body2
    p, n = re.subn(
        re.escape(phase_id) + r" /\* Embed Frameworks \*/ = \{.*?\n\t\t\};", strip, p, flags=re.S)
    print(f"[{PLUG}] removed KeyframelessKit from pluginkit Embed Frameworks phase")

# 2. Add the host-app rpath to every pluginkit config (WRAPPER_EXTENSION = pluginkit).
added = 0
def fix_cfg(m):
    global added
    block = m.group(0)
    if "WRAPPER_EXTENSION = pluginkit" not in block:
        return block
    if HOST_RPATH in block:
        return block
    new_rpath = (
        'LD_RUNPATH_SEARCH_PATHS = (\n'
        '\t\t\t\t\t"$(inherited)",\n'
        '\t\t\t\t\t"@loader_path/../Frameworks",\n'
        f'\t\t\t\t\t"{HOST_RPATH}",\n'
        '\t\t\t\t);')
    # Match the whole setting up to its terminating ';' (the value - array or string -
    # has no ';' inside, but DOES contain ')' from $(inherited), so match on ';').
    block2 = re.sub(r"LD_RUNPATH_SEARCH_PATHS = [^;]*;", new_rpath, block)
    if block2 != block:
        added += 1
    return block2

p = re.sub(
    r"[0-9A-F]{24} /\* (?:Debug|Release) \*/ = \{\s*isa = XCBuildConfiguration;.*?\n\t\t\};",
    fix_cfg, p, flags=re.S)
print(f"[{PLUG}] added host rpath to {added} pluginkit config(s)")

if p != orig:
    open(PBX, "w").write(p)
    print(f"[{PLUG}] wrote {PBX}")
else:
    print(f"[{PLUG}] no changes")
