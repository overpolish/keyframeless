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
  scripts/split-pkgproj.py --components                    list component keys

Components: rounded keyframelessx magicmove glow canvas
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
    "rounded": "co.overpolish.keyframeless.Rounded",
    "keyframelessx": "co.overpolish.keyframeless.Keyframeless-X.Keyframeless-X-FCP",
    "magicmove": "co.overpolish.keyframeless.MagicMove",
    "glow": "co.overpolish.keyframeless.Glow",
    "canvas": "co.overpolish.keyframeless.Canvas",
}


def installer_list(project):
    return project["PROJECT"]["PROJECT_PRESENTATION"]["INSTALLATION TYPE"][
        "HIERARCHIES"
    ]["INSTALLER"]["LIST"]


def find_app_name(node):
    """The installed .app filename (e.g. 'MagicMove.app'), which can differ from the
    product display name ('Magic Move'). Read it from the payload hierarchy."""
    path = node.get("PATH", "")
    if path.endswith(".app"):
        return pathlib.Path(path).name
    for child in node.get("CHILDREN", []):
        found = find_app_name(child)
        if found:
            return found
    return None


def template_folder_name(pkg):
    """The '<Plugin> • KF' folder this plugin installs into the Motion Templates tree,
    or '' if the product ships no templates (e.g. the Keyframeless X workflow ext)."""
    for r in pkg.get("PACKAGE_SCRIPTS", {}).get("RESOURCES", []):
        rel = r.get("PATH", "")
        if "MotionTemplates" not in rel:
            continue
        # rel is like ../MotionTemplates/<dir>/Effects.localized ; the installed
        # subfolder lives at <dir>/Effects.localized/Keyframeless/<Plugin> • KF.
        kf = (ROOT / "Distribution" / rel).resolve() / "Keyframeless"
        if kf.is_dir():
            entries = [p.name for p in kf.iterdir() if p.name != ".DS_Store"]
            if entries:
                return entries[0]
    return ""


def write_uninstaller(component, plugin_name, app_name, template_name):
    text = UNINSTALL_TEMPLATE.read_text(encoding="utf-8")
    text = (
        text.replace("__PLUGIN_NAME__", plugin_name)
        .replace("__APP_NAME__", app_name)
        .replace("__TEMPLATE_NAME__", template_name)
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
    # at it (the suite-wide scripts/uninstall stays for the combined bundle).
    app_name = find_app_name(only["PACKAGE_FILES"]["HIERARCHY"])
    tmpl_name = template_folder_name(only)
    write_uninstaller(component, name, app_name, tmpl_name)
    for r in only.get("PACKAGE_SCRIPTS", {}).get("RESOURCES", []):
        if r.get("PATH", "").rstrip("/").endswith("scripts/uninstall"):
            r["PATH"] = f"scripts/uninstall-{component}"

    out = ROOT / "Distribution" / f"{name}.pkgproj"
    with open(out, "wb") as f:
        plistlib.dump(proj, f)
    print(
        f"  wrote {out.relative_to(ROOT)}  (builds to build/{name}.pkg)\n"
        f"        uninstaller: scripts/uninstall-{component}  "
        f"(app={app_name}, template={tmpl_name or 'none'})"
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


def main(argv):
    # Query modes used by build-and-sign.sh to drive generation without printing noise.
    if argv == ["--components"]:
        print(" ".join(COMPONENT_ID))
        return
    if len(argv) == 2 and argv[0] == "--name":
        print(product_name(plistlib.loads(COMBINED.read_bytes()), argv[1]))
        return
    if not argv:
        sys.exit(__doc__)
    combined = plistlib.loads(COMBINED.read_bytes())
    targets = list(COMPONENT_ID) if argv == ["all"] else argv
    for c in targets:
        build_one(combined, c)


if __name__ == "__main__":
    main(sys.argv[1:])
