#!/usr/bin/env python3
"""Build, check and install the Motion templates that publish our plug-ins to Final Cut Pro.

The published controls and their order come from the plug-in's own
`addParametersWithError:`, exported by `MagicMove/Tests/ParameterExport.m`, so the
inspector layout is changed in code rather than by republishing parameters in
Motion. Everything else comes from the skeleton in `scripts/templates` and the
per-plug-in manifest in `<Plugin>/Template/template.json`.

Usage:
  scripts/motion-template.py build     [plugin ...]
  scripts/motion-template.py check     [plugin ...]
  scripts/motion-template.py install   [plugin ...]
  scripts/motion-template.py uninstall [plugin ...]
"""

import argparse
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKELETONS = ROOT / "scripts" / "templates"
INSTALL_ROOT = Path.home() / "Movies" / "Motion Templates.localized"

# Motion writes the filter's scene id into both the filter node and every
# publish target. Any value works as long as the two agree, so the generator
# pins one and keeps generated documents byte-stable.
FILTER_ID = "103006"

# FCP 11 reads Motion 6.2 documents. A newer Motion silently writes 5.15/6.3 on
# save, which drops FCP 11 support, so the floor is pinned and checked.
OZML_VERSION = "5.14"
DISPLAY_VERSION = "6.2"

# Motion's own preset reference. Absolute, and shipped that way by every Motion
# template; pinned here so a machine-specific variant cannot leak in.
PRESET_PATH = (
    "/Applications/Motion.app/Contents/Resources/Presets/Project/en.lproj/"
    "Broadcast HD 1080.preset"
)

# Sizes the installed template carries, rendered from the plug-in's master.
THUMBNAIL_SIZES = {"large": (640, 360), "small": (192, 108)}
THUMBNAIL_DIR = "Thumbnails"


class Failure(Exception):
    pass


def manifests(names):
    found = sorted(ROOT.glob("*/Template/template.json"))
    if names:
        wanted = {name.rstrip("/") for name in names}
        found = [path for path in found if path.parts[-3] in wanted]
        missing = wanted - {path.parts[-3] for path in found}
        if missing:
            raise Failure(f"no template manifest for {', '.join(sorted(missing))}")
    if not found:
        raise Failure("no template manifests found")
    return found


def display_name(info, strings_path):
    """Resolve the FxPlug display name, which Info.plist holds as a strings key."""
    key = info["displayName"]
    if not strings_path.exists():
        return key
    text = strings_path.read_text(encoding="utf-8")
    match = re.search(rf'"{re.escape(key)}"\s*=\s*"([^"]*)"\s*;', text)
    return match.group(1) if match else key


def plugin_identity(manifest, directory):
    """The filter UUID, its display name, and whether the plug-in draws on-screen controls."""
    plist_path = ROOT / manifest["plugin"]["infoPlist"]
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    entries = plist["ProPlugPlugInList"]
    filters = [e for e in entries if "FxFilter" in e.get("protocolNames", [])]
    if len(filters) != 1:
        raise Failure(f"{plist_path} must register exactly one FxFilter")
    uuid = filters[0]["uuid"]
    controls = [
        e
        for e in entries
        if "FxOnScreenControl" in e.get("protocolNames", [])
        and uuid in e.get("supportedPlugins", [])
    ]
    strings = ROOT / manifest["plugin"]["strings"]
    return uuid, display_name(filters[0], strings), bool(controls)


def export_parameters(plugin):
    """Run the plug-in's parameter registration and read back the ordered result."""
    runner = ROOT / plugin / "Tests" / "run.sh"
    if not runner.exists():
        raise Failure(f"{runner} is missing; the exporter runs through it")
    with tempfile.TemporaryDirectory() as scratch:
        out = Path(scratch) / "parameters.json"
        environment = dict(os.environ, MM_TEST_SUITES="ParameterExport")
        result = subprocess.run(
            [str(runner), str(out)], env=environment, cwd=ROOT, capture_output=True, text=True
        )
        if result.returncode != 0:
            raise Failure(
                "parameter export failed; build the plug-in first "
                f"(MM_DERIVED_DATA must match that build)\n{result.stdout}{result.stderr}"
            )
        return json.loads(out.read_text())


def published(parameters):
    """Controls the host shows, in registration order: that is the FCP inspector order."""
    return [p for p in parameters if p["customUI"] and not p["hidden"]]


def render(manifest, directory, parameters):
    skeleton = (SKELETONS / manifest["skeleton"]).read_text(encoding="utf-8")
    uuid, name, draws_controls = plugin_identity(manifest, directory)
    targets = "\n\t\t".join(
        f'<target object="{FILTER_ID}" channel="./{p["id"]}" name=""/>'
        for p in published(parameters)
    )
    if not targets:
        raise Failure("the plug-in registers no visible controls to publish")
    document = skeleton.replace("__PUBLISH_TARGETS__", targets)
    document = document.replace("__FILTER_ID__", FILTER_ID)
    document = document.replace("__PLUGIN_UUID__", uuid)
    # Motion labels the filter with the plug-in's display name; FCP matches on the UUID.
    document = document.replace("__FILTER_NAME__", escape(name))
    # Without this the host never instantiates the on-screen control class, so
    # drawOSC never fires even though rendering and parameters work.
    document = document.replace("__PUBLISH_OSC__", "1" if draws_controls else "0")
    return document


def escape(value):
    return value.replace("&", "&amp;").replace("<", "&lt;").replace('"', "&quot;")


def png_size(path):
    header = path.read_bytes()[:24]
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        raise Failure(f"{path} is not a PNG")
    return struct.unpack(">II", header[16:24])


def derive_thumbnails(manifest, directory):
    """Render the installed sizes from the one master the plug-in keeps."""
    master = directory / manifest["thumbnail"]
    if not master.exists():
        raise Failure(f"{master.relative_to(ROOT)} is missing")
    out = directory / THUMBNAIL_DIR
    out.mkdir(exist_ok=True)
    rendered = {}
    for key, (width, height) in THUMBNAIL_SIZES.items():
        path = out / f"{key}.png"
        result = subprocess.run(
            ["sips", "-s", "format", "png", "-z", str(height), str(width), str(master),
             "--out", str(path)],
            capture_output=True, text=True,
        )
        if result.returncode != 0 or not path.exists():
            raise Failure(f"sips could not render {key}.png\n{result.stderr}")
        rendered[key] = path
    return rendered


def validate(manifest, directory, document, parameters):
    problems = []
    if f'<ozml version="{OZML_VERSION}">' not in document:
        problems.append(f"ozml version must stay at {OZML_VERSION} for FCP 11")
    if f"<displayversion>{DISPLAY_VERSION}</displayversion>" not in document:
        problems.append(f"displayversion must stay at {DISPLAY_VERSION} for FCP 11")
    for tag in ("dataValue", "defaultVal"):
        if f"<{tag}>" in document:
            problems.append(f"{tag} blobs bake plug-in defaults into the template")
    for absolute in re.findall(r"<pathURL>(/[^<]*)</pathURL>", document):
        problems.append(f"absolute media path {absolute}")
    for preset in re.findall(r"<presetPath>([^<]*)</presetPath>", document):
        if preset != PRESET_PATH:
            problems.append(f"unexpected preset path {preset}")
    identifiers = {p["id"] for p in parameters}
    for target in re.findall(r'channel="\./(\d+)"', document):
        if int(target) not in identifiers:
            problems.append(f"published channel {target} is not a registered parameter")
    _, _, draws_controls = plugin_identity(manifest, directory)
    if draws_controls and '"Publish OSC" id="10005" flags="4311744512" default="0" value="1"' not in document:
        problems.append("Publish OSC must be on, or the on-screen control never draws")
    master = directory / manifest["thumbnail"]
    if not master.exists():
        problems.append(f"missing thumbnail master {master.relative_to(ROOT)}")
    else:
        width, height = png_size(master)
        # sips resizes to exact dimensions, so a master of the wrong shape would
        # be squashed rather than cropped. Refuse it instead.
        if abs(width * 9 - height * 16) > height:
            problems.append(f"{master.relative_to(ROOT)} must be 16:9, is {width}x{height}")
        if (width, height) < THUMBNAIL_SIZES["large"]:
            problems.append(
                f"{master.relative_to(ROOT)} must be at least "
                f"{'x'.join(str(v) for v in THUMBNAIL_SIZES['large'])}, is {width}x{height}"
            )
    for path in [directory / manifest["document"], directory, *directory.rglob("*")]:
        if not str(path.relative_to(ROOT)).isascii():
            problems.append(f"non-ASCII repository path {path.relative_to(ROOT)}")
    return problems


def installed_directory(manifest):
    return INSTALL_ROOT / f"{manifest['kind']}.localized" / manifest["category"] / manifest["name"]


def build(paths, check):
    failed = False
    for manifest_path in paths:
        directory = manifest_path.parent
        plugin = manifest_path.parts[-3]
        manifest = json.loads(manifest_path.read_text())
        parameters = export_parameters(plugin)["parameters"]
        document = render(manifest, directory, parameters)
        target = directory / manifest["document"]
        problems = validate(manifest, directory, document, parameters)
        order = ", ".join(str(p["id"]) for p in published(parameters))
        if check:
            current = target.read_text(encoding="utf-8") if target.exists() else None
            if current != document:
                problems.append(
                    f"{target.relative_to(ROOT)} is stale; run scripts/motion-template.py build"
                )
        else:
            target.write_text(document, encoding="utf-8")
            if not problems:
                derive_thumbnails(manifest, directory)
        if problems:
            failed = True
            print(f"{plugin}: template check failed", file=sys.stderr)
            for problem in problems:
                print(f"  - {problem}", file=sys.stderr)
        else:
            verb = "checked" if check else "built"
            print(f"{plugin}: {verb} {target.relative_to(ROOT)}, publishing {order}")
    return 1 if failed else 0


def install(paths):
    for manifest_path in paths:
        directory = manifest_path.parent
        manifest = json.loads(manifest_path.read_text())
        document = directory / manifest["document"]
        if not document.exists():
            raise Failure(f"{document.relative_to(ROOT)} is missing; build it first")
        destination = installed_directory(manifest)
        shutil.rmtree(destination, ignore_errors=True)
        destination.mkdir(parents=True)
        shutil.copyfile(document, destination / f"{manifest['name']}.moef")
        for key, path in derive_thumbnails(manifest, directory).items():
            shutil.copyfile(path, destination / f"{key}.png")
        print(f"installed {destination}")
    return 0


def uninstall(paths):
    for manifest_path in paths:
        manifest = json.loads(manifest_path.read_text())
        destination = installed_directory(manifest)
        if destination.exists():
            shutil.rmtree(destination)
            print(f"removed {destination}")
        else:
            print(f"not installed: {destination}")
        category = destination.parent
        if category.exists() and not any(category.iterdir()):
            category.rmdir()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "check", "install", "uninstall"))
    parser.add_argument("plugins", nargs="*", help="plug-in directory names; default is all")
    arguments = parser.parse_args()
    try:
        paths = manifests(arguments.plugins)
        if arguments.action in ("build", "check"):
            return build(paths, arguments.action == "check")
        if arguments.action == "install":
            return install(paths)
        return uninstall(paths)
    except Failure as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
