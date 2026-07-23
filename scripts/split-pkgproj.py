#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 overpolish
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate per-product .pkgproj files from the combined Keyframeless.pkgproj.

The combined Distribution/Keyframeless.pkgproj (edited in Packages.app) stays the
single source of truth for payload layout, scripts, and presentation. This derives a
standalone single-product installer project for one component, so each plugin can ship
its own .pkg on Payhip independently of the all-in-one bundle.

Outputs are EPHEMERAL build artifacts, gitignored, normally generated + cleaned up by
build-and-sign.sh - never committed and never hand-edited in Packages.app. Edit the
combined project (the source of truth) and re-run this. Outputs live next to the
combined project so the relative payload paths (release/<App>.app,
../MotionTemplates/..., ../Assets/installer.png) still resolve.

Each run also writes Distribution/scripts/uninstall-<component> from
scripts/uninstall.template (per-plugin uninstaller) and points that package at it.

Usage:
  scripts/split-pkgproj.py <component> [<component> ...]   generate project(s)
  scripts/split-pkgproj.py all                             generate all
  scripts/split-pkgproj.py --name <component>              print the product name
  scripts/split-pkgproj.py --version <component>           print the product version
  scripts/split-pkgproj.py --components                    list component keys

Components: keyframelessx canvas shader
Output:    Distribution/<Name>.pkgproj   (builds to build/<Name>.pkg)

Build one unsigned:  packagesbuild "Distribution/<Name>.pkgproj"
Build + sign:        scripts/build-and-sign.sh <component> <apple-id> <team-id>
"""

import copy
import pathlib
import plistlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMBINED = ROOT / "Distribution" / "Keyframeless.pkgproj"
UNINSTALL_TEMPLATE = ROOT / "scripts" / "uninstall.template"

# component key -> package IDENTIFIER as it appears in the combined project
COMPONENT_ID = {
    "keyframelessx": "co.overpolish.keyframeless.Keyframeless-X.Keyframeless-X-FCP",
    "canvas": "co.overpolish.keyframeless.Canvas",
    "shader": "co.overpolish.keyframeless.Shader",
    # The shared local-AI engine (helper + LaunchAgent to /Library). Not a plugin
    # (no .app / Motion Template), so `--components` (which drives `all`) excludes it;
    # build it explicitly. build-and-sign.sh stages the helper before packaging.
    "keyframelessai": "co.overpolish.keyframeless.KeyframelessAI",
}

# The FxPlug plugins + the workflow extension (everything `all` builds). The AI engine
# is deliberately not here - it needs the helper staged first.
PLUGIN_COMPONENTS = [k for k in COMPONENT_ID if k != "keyframelessai"]


def installer_list(project):
    return project["PROJECT"]["PROJECT_PRESENTATION"]["INSTALLATION TYPE"][
        "HIERARCHIES"
    ]["INSTALLER"]["LIST"]


def find_app_name(node):
    """The installed .app filename (which can differ from the product display name
    when the name has spaces or separators). Read it from the payload hierarchy."""
    path = node.get("PATH", "")
    if path.endswith(".app"):
        return pathlib.Path(path).name
    for child in node.get("CHILDREN", []):
        found = find_app_name(child)
        if found:
            return found
    return None


def template_rel_paths(pkg):
    """Every template this plugin installs, each as a path relative to the Motion
    Templates base (e.g. 'Effects.localized/Keyframeless/<Plugin> • KF'). A plugin
    can ship more than one type - an effect AND a transition - so this is a list.
    Empty for products with no templates (e.g. the Keyframeless X workflow ext)."""
    paths = []
    for r in pkg.get("PACKAGE_SCRIPTS", {}).get("RESOURCES", []):
        rel = r.get("PATH", "")
        if "MotionTemplates" not in rel:
            continue
        # rel is like ../MotionTemplates/<dir>/<Type>.localized ; the installed
        # subfolder lives at <Type>.localized/Keyframeless/<Plugin> • KF.
        type_dir = pathlib.Path(rel).name  # e.g. Effects.localized
        kf = (ROOT / "Distribution" / rel).resolve() / "Keyframeless"
        if kf.is_dir():
            for p in sorted(kf.iterdir()):
                if p.name != ".DS_Store" and p.is_dir():
                    paths.append(f"{type_dir}/Keyframeless/{p.name}")
    return paths


def write_uninstaller(component, plugin_name, app_name, rel_paths):
    # Bash-array body: one quoted, indented entry per template ("" when none, so
    # the array is still valid and the uninstaller reports nothing to remove).
    body = "\n".join(f'    "{p}"' for p in rel_paths) if rel_paths else '    ""'
    text = UNINSTALL_TEMPLATE.read_text(encoding="utf-8")
    text = (
        text.replace("__PLUGIN_NAME__", plugin_name)
        .replace("__APP_NAME__", app_name)
        .replace("__TEMPLATE_RELPATHS__", body)
    )
    out = ROOT / "Distribution" / "scripts" / f"uninstall-{component}"
    out.write_text(text, encoding="utf-8")
    out.chmod(0o755)
    return out


def build_one(combined, component):
    ident = COMPONENT_ID.get(component)
    if not ident:
        sys.exit(f"unknown component '{component}' (known: {', '.join(COMPONENT_ID)})")

    pkg = next(
        (p for p in combined["PACKAGES"] if p["PACKAGE_SETTINGS"]["IDENTIFIER"] == ident),
        None,
    )
    if pkg is None:
        sys.exit(f"no package with identifier {ident} in {COMBINED.name}")

    name = pkg["PACKAGE_SETTINGS"]["NAME"]
    uuid = pkg["UUID"]

    proj = copy.deepcopy(combined)
    only = copy.deepcopy(pkg)
    proj["PACKAGES"] = [only]
    # A single-product installer should go straight to the standard install screen,
    # not the "Installation Type" selection with a pointless checkbox to deselect the
    # only product. The combined project uses MODE 2 (always customize) so bundle
    # buyers can pick; a standalone drops to MODE 1 (standard, no forced customize).
    proj["PROJECT"]["PROJECT_PRESENTATION"]["INSTALLATION TYPE"]["MODE"] = 1
    # Keep only this package's choice in the chooser; drop the other plugins.
    keep = [c for c in installer_list(proj) if c.get("PACKAGE_UUID") == uuid]
    proj["PROJECT"]["PROJECT_PRESENTATION"]["INSTALLATION TYPE"]["HIERARCHIES"][
        "INSTALLER"
    ]["LIST"] = keep
    # Output .pkg is named after the product, not "Keyframeless".
    proj["PROJECT"]["PROJECT_SETTINGS"]["NAME"] = name
    # Installer window title too (otherwise it reads "Install Keyframeless").
    title = proj["PROJECT"]["PROJECT_PRESENTATION"].get("TITLE", {})
    for loc in title.get("LOCALIZATIONS", []):
        loc["VALUE"] = name

    # Generate a per-plugin uninstaller and point the package's uninstall resource
    # at it (the suite-wide scripts/uninstall stays for the combined bundle). Skipped
    # for non-plugin components (e.g. the AI engine ships its own uninstaller in the
    # payload and has no .app / Motion Template).
    app_name = find_app_name(only["PACKAGE_FILES"]["HIERARCHY"])
    tmpl_paths = []
    if app_name is not None:
        tmpl_paths = template_rel_paths(only)
        write_uninstaller(component, name, app_name, tmpl_paths)
        for r in only.get("PACKAGE_SCRIPTS", {}).get("RESOURCES", []):
            if r.get("PATH", "").rstrip("/").endswith("scripts/uninstall"):
                r["PATH"] = f"scripts/uninstall-{component}"

    out = ROOT / "Distribution" / f"{name}.pkgproj"
    with open(out, "wb") as f:
        plistlib.dump(proj, f)
    print(
        f"  wrote {out.relative_to(ROOT)}  (builds to build/{name}.pkg)\n"
        f"        uninstaller: scripts/uninstall-{component}  "
        f"(app={app_name}, templates={', '.join(tmpl_paths) or 'none'})"
    )


def product_name(combined, component):
    ident = COMPONENT_ID.get(component)
    if not ident:
        sys.exit(f"unknown component '{component}' (known: {', '.join(COMPONENT_ID)})")
    pkg = next(
        (p for p in combined["PACKAGES"] if p["PACKAGE_SETTINGS"]["IDENTIFIER"] == ident),
        None,
    )
    if pkg is None:
        sys.exit(f"no package with identifier {ident} in {COMBINED.name}")
    return pkg["PACKAGE_SETTINGS"]["NAME"]


def product_version(combined, component):
    ident = COMPONENT_ID.get(component)
    if not ident:
        sys.exit(f"unknown component '{component}' (known: {', '.join(COMPONENT_ID)})")
    pkg = next(
        (p for p in combined["PACKAGES"] if p["PACKAGE_SETTINGS"]["IDENTIFIER"] == ident),
        None,
    )
    if pkg is None:
        sys.exit(f"no package with identifier {ident} in {COMBINED.name}")
    return pkg["PACKAGE_SETTINGS"]["VERSION"]


def main(argv):
    # Query modes used by build-and-sign.sh to drive generation without printing noise.
    if argv == ["--components"]:
        print(" ".join(PLUGIN_COMPONENTS))
        return
    if len(argv) == 2 and argv[0] == "--name":
        print(product_name(plistlib.loads(COMBINED.read_bytes()), argv[1]))
        return
    if len(argv) == 2 and argv[0] == "--version":
        print(product_version(plistlib.loads(COMBINED.read_bytes()), argv[1]))
        return
    if not argv:
        sys.exit(__doc__)
    combined = plistlib.loads(COMBINED.read_bytes())
    targets = list(PLUGIN_COMPONENTS) if argv == ["all"] else argv
    for c in targets:
        build_one(combined, c)


if __name__ == "__main__":
    main(sys.argv[1:])
