#!/bin/sh
# Build the Keyframeless installer: every plugin in the repository, each one a
# choice the buyer can turn off, installed for every account on the Mac.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
sign=no
notarize=no
for argument in "$@"; do
  case "$argument" in
    --sign) sign=yes ;;
    # Only a signed package can be notarized, so asking for one asks for both.
    --notarize) sign=yes; notarize=yes ;;
    *) echo "Usage: scripts/build-pkg.sh [--sign] [--notarize]" >&2; exit 2 ;;
  esac
done

derived="${MM_PACKAGE_DERIVED_DATA:-$root/DerivedData/Package}"
identity="${MM_INSTALLER_IDENTITY:-Developer ID Installer}"
profile="${MM_NOTARY_PROFILE:-keyframeless}"
output="$root/Distribution/build"
# The template folder Final Cut Pro and Motion read for every account, and the
# one KFInstallation.m looks in when it removes a plugin again.
templates="/Library/Application Support/Final Cut Pro/Templates.localized"

plist() {
  /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist" 2>/dev/null || true
}

escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

work=$(mktemp -d -t keyframeless-package)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/parts"
: > "$work/outline.xml"
: > "$work/choices.xml"
: > "$work/versions"

# The installer's own artwork, drawn from the vector source. It is the mark on
# a transparent canvas, so one image serves both appearances and the installer
# window shows through behind it. The SVG declares the pixel size the installer
# wants, so sips rasterizes it at that size rather than resampling.
resources="$work/resources"
mkdir -p "$resources"
sips -s format png "$root/Assets/installer.svg" --out "$resources/installer.png" >/dev/null

# The inspector Final Cut Pro shows comes from each plugin's own parameter
# registration, so a stale template would ship controls the code no longer has.
"$root/scripts/motion-template.py" check

for manifest in "$root"/*/Template/template.json; do
  plugin=$(basename "$(dirname "$(dirname "$manifest")")")
  # Without a generic destination xcodebuild builds only the architecture of
  # the machine that runs it, and the package would install a Mac-specific
  # plug-in.
  xcodebuild -workspace "$root/Keyframeless.xcworkspace" -scheme "$plugin" \
    -configuration Release -derivedDataPath "$derived/$plugin" \
    -destination 'generic/platform=macOS' build >/dev/null
  app=$(/bin/ls -d "$derived/$plugin/Build/Products/Release"/*.app 2>/dev/null | head -1)
  [ -n "$app" ] && [ -d "$app" ] || { echo "$plugin: no application was built" >&2; exit 1; }

  # Each plugin declares where it installs, and its uninstaller reads the same
  # dictionary back out of the installed application.
  applications=$(plist "$app" "KFInstall:ApplicationDirectory")
  template=$(plist "$app" "KFInstall:TemplateRelativePath")
  product=$(plist "$app" "KFInstall:ProductName")
  summary=$(plist "$app" "KFInstall:Description")
  bundle=$(plist "$app" "CFBundleIdentifier")
  version=$(plist "$app" "CFBundleShortVersionString")
  if [ -z "$applications" ] || [ -z "$template" ] || [ -z "$product" ] || [ -z "$summary" ] ||
     [ -z "$bundle" ]; then
    echo "$plugin: $app is missing its KFInstall entries" >&2
    exit 1
  fi
  package="$bundle.pkg"
  echo "$version" >> "$work/versions"

  payload="$work/payload-$plugin"
  mkdir -p "$payload$applications" "$payload$templates"
  ditto "$app" "$payload$applications/$(basename "$app")"
  "$root/scripts/motion-template.py" stage "$plugin" --into "$payload$templates" >/dev/null
  # Group write is what the postinstall turns into administrator access once
  # the group is root's; nothing is writable by everyone.
  chmod -R g+w "$payload"
  chmod -R o-w "$payload"

  scripts="$work/scripts-$plugin"
  mkdir -p "$scripts"
  category=$(dirname "$templates/$template")
  sed -e "s|@PRODUCT_PATHS@|$applications/$(basename "$app")\\
$templates/$template|" \
      -e "s|@SHARED_PATHS@|$applications\\
$category\\
$(dirname "$category")|" \
      "$root/Distribution/scripts/postinstall.in" > "$scripts/postinstall"
  chmod +x "$scripts/postinstall"

  # Without this the application is a relocatable component: the installer
  # would follow a copy registered from a build directory and update that
  # instead of installing where the payload says.
  pkgbuild --analyze --root "$payload" "$work/component-$plugin.plist" >/dev/null
  plutil -replace 0.BundleIsRelocatable -bool NO "$work/component-$plugin.plist"
  pkgbuild --root "$payload" --component-plist "$work/component-$plugin.plist" \
    --scripts "$scripts" --identifier "$package" --version "$version" \
    --install-location / "$work/parts/$plugin.pkg" >/dev/null

  printf '        <line choice="%s"/>\n' "$package" >> "$work/outline.xml"
  {
    printf '    <choice id="%s" title="%s" description="%s" start_selected="true">\n' \
      "$package" "$(escape "$product")" "$(escape "$summary")"
    printf '        <pkg-ref id="%s"/>\n' "$package"
    printf '    </choice>\n'
    printf '    <pkg-ref id="%s" version="%s" onConclusion="none">%s.pkg</pkg-ref>\n' \
      "$package" "$version" "$plugin"
  } >> "$work/choices.xml"

  # Building the application registered this copy with PlugInKit, which keeps
  # one registration per plug-in identifier: the hosts would run the packaged
  # build instead of the one being developed. Withdraw it again.
  for service in "$app/Contents/PlugIns"/*.pluginkit; do
    [ -d "$service" ] && pluginkit -r "$service" 2>/dev/null || true
  done
  echo "staged $product $version"
done

[ -s "$work/versions" ] || { echo "no plugins found" >&2; exit 1; }
version=$(sort -V "$work/versions" | tail -1)
# Every plugin builds for the same architectures; the last one read speaks for
# the installer as a whole.
executable=$(plist "$app" "CFBundleExecutable")
architectures=$(lipo -archs "$app/Contents/MacOS/$executable" | tr ' ' ',')

sed -e "s|@ARCHITECTURES@|$architectures|g" \
    -e "/@OUTLINE@/r $work/outline.xml" -e "/@OUTLINE@/d" \
    -e "/@CHOICES@/r $work/choices.xml" -e "/@CHOICES@/d" \
    "$root/Distribution/distribution.xml.in" > "$work/distribution.xml"

mkdir -p "$output"
result="$output/Keyframeless-$version.pkg"
if [ "$sign" = yes ]; then
  productbuild --distribution "$work/distribution.xml" --package-path "$work/parts" \
    --resources "$resources" --sign "$identity" "$result" >/dev/null
else
  productbuild --distribution "$work/distribution.xml" --package-path "$work/parts" \
    --resources "$resources" "$result" >/dev/null
fi

# Notarization inspects every nested binary, so the whole payload has to be
# Developer ID signed with a secure timestamp before the package is submitted.
# The ticket is stapled into the package itself, which is what lets it install
# on a Mac that has never seen it online.
if [ "$notarize" = yes ]; then
  xcrun notarytool submit "$result" --keychain-profile "$profile" --wait
  xcrun stapler staple "$result"
fi

# The Keyframeless mark on the package file itself. Finder reads it from the
# file's resource fork, the same place Packages.app and Installer put it, so a
# transfer that drops metadata drops the icon and nothing else. Stapling
# rewrites the package, so this comes last.
icon="$app/Contents/Resources/$(plist "$app" CFBundleIconFile).icns"
if [ -f "$icon" ]; then
  cp "$icon" "$work/package.icns"
  sips -i "$work/package.icns" >/dev/null
  xcrun DeRez -only icns "$work/package.icns" > "$work/package.rsrc"
  xcrun Rez -append "$work/package.rsrc" -o "$result"
  xcrun SetFile -a C "$result"
fi

echo "built $result ($version, $architectures)"
if [ "$sign" = yes ]; then
  pkgutil --check-signature "$result" | sed -n '2,3p'
fi
if [ "$notarize" = yes ]; then
  spctl --assess --type install -vv "$result" 2>&1 | sed -n '1,2p'
fi
exit 0
