# Distribution

- Use `Packages` for generating the `pkg`.
- All plugins are separate packages allowed end users to customize which plugins they want to install.
- `<Plugin>.app` are installed to `/Applications/Keyframeless`.
- The `postinstall` script automatically moves the package templates into the correct Motion Templates folder.

## Version Management

Each component (`rounded`, `magicmove`, `keyframelessx`, `glow`, `canvas`) is versioned independently.

### Bumping a version

```sh
scripts/bump-version.sh <component> <breaking|major|minor|alpha|release>
```

Version format is `BREAKING.MAJOR.MINOR[-vN]`. The script reads the current version, increments the specified segment, and updates the relevant `Info.plist` / `.pbxproj` files.

```sh
scripts/bump-version.sh magicmove minor    # 1.0.0 -> 1.0.1
scripts/bump-version.sh magicmove major    # 1.0.0 -> 1.1.0
scripts/bump-version.sh magicmove breaking # 1.0.0 -> 2.0.0
scripts/bump-version.sh magicmove alpha    # 1.0.1 -> 1.0.1-v0, then 1.0.1-v1, etc.
scripts/bump-version.sh magicmove release  # 1.0.1-v2 -> 1.0.1
```

`alpha` adds or increments a `-vN` suffix and creates no changelog entry. `release` strips the suffix and creates the prefilled `docs/changelog/<component>/<version>.md`. Users running `1.0.1-v0` will see the update banner when the official `1.0.1` ships because a release version is always considered newer than a pre-release with the same base version.

### How update checking works

On app launch, `KKUpdateChecker` GETs the component's release-notes page (`<base>/<component>/`) and reads the `<meta name="kk-version">` tag, comparing it to the running bundle's `CFBundleShortVersionString`. If the page advertises a newer version, the update banner is shown. Pre-release suffixes (e.g. `-v0`) are stripped for comparison, and a release version is treated as newer than a pre-release with the same base version. The published version is just the changelog `.md` filename (which the build emits into the meta tag) - there is no `manifest.json`.

### Releasing

1. Bump the component(s) that changed using the script above.
2. Fill in `docs/changelog/<component>/<version>.md`.
3. Run `scripts/build-changelog.py`.
4. Build, sign, and notarize the per-product `.pkg` (see below).
5. Upload the signed `.pkg` to its Payhip product - buyers re-download the new file from there.
6. Publish the docs (commit + push) so the `kk-version` meta tag advertises the new version to installed builds.

### KeyframelessKit

`KeyframelessKit` is a shared framework linked by all components - it carries no version of its own. When it changes, bump whichever components ship with the new behaviour. If it's a framework-wide fix, bump all components.

### Adding a new component

The component key is the project name lowercased with no spaces or separators (e.g. `MagicMove` → `magicmove`, `Keyframeless X` → `keyframelessx`).

1. Add the key to `KKBundleIDToComponent()` in `KKUpdateChecker.m` - map both the wrapper app and XPC service bundle IDs.
2. Add a case to `scripts/bump-version.sh` that updates the relevant `Info.plist` / `.pbxproj` files.
3. Call `addUpdateBannerParameterWithAPI:error:` at the start of `addParametersWithError:` and pass `[KKPlugin servicePrincipalDelegate]` to `startServicePrincipalWithDelegate:` in `main()` to wire up update checking.
4. Add the component to the combined `Distribution/Keyframeless.pkgproj` in Packages.app, and add its `key -> package identifier` to `COMPONENT_ID` in `scripts/split-pkgproj.py`. The per-product `.pkgproj` and per-plugin uninstaller are then generated automatically by `build-and-sign.sh`.
5. Add it to `docs/changelog/plugins.json` (name, kind, payhip) so it gets a changelog page + meta tag.

## Code Signing & Notarization

### Pre-requisites

Generate the following in XCode (`Settings > Apple Accounts > Manage Certificates`):

- Developer ID Application - signing the `.app`
- Developer ID Installer - signing the `.pkg`
- Enable `Hardened Runtime` for each project (`Build Settings > Enable hardened runtime`)

- `Signing & Capabilities` for each target:
  - Turn off `Automatically manage signing` (wasn't showing my Developer ID Application Cert)
  - Set `Team`
  - Set `Signing Certificate`
  - [Keyframeless X FCP] `Disable Library Validation` under `Hardened Runtime`

### Code-Signing

1. Code signing should be happening on archive `Product > Archive`.
2. Click `Distribute` and `Direct Distribution`.
3. Wait for status to become `Ready to distribute`.

With the app selected under `Notarization`, click `Export Notarized App` and select the `Distribution > release` folder. This will place the signed and notarized app ready for Packages to build it into an installer.

### Building & signing `.pkg`

Build an installer and sign it in one step. The first argument is the target:

```sh
scripts/build-and-sign.sh combined "<apple-id>" "<team-id>"   # all-in-one Keyframeless.pkg
scripts/build-and-sign.sh rounded  "<apple-id>" "<team-id>"   # just Rounded.pkg
scripts/build-and-sign.sh all      "<apple-id>" "<team-id>"   # every plugin, one .pkg each
```

Per-product targets generate a single-product `.pkgproj` and a per-plugin uninstaller
from `Distribution/Keyframeless.pkgproj` + `scripts/uninstall.template` (via
`scripts/split-pkgproj.py`), build, sign, then delete those temp files - nothing
per-plugin is committed. `combined` builds the committed `Keyframeless.pkgproj`. Each
runs `packagesbuild`, then signs, notarizes, staples, and verifies the resulting `.pkg`.

To sign an already-built `.pkg` without rebuilding (base name, no `.pkg`):

```sh
scripts/sign-pkg.sh "Rounded" "<apple-id>" "<team-id>"
```

To just generate a per-product `.pkgproj` for an unsigned local build:

```sh
python3 scripts/split-pkgproj.py rounded
packagesbuild "Distribution/Rounded.pkgproj"
```
