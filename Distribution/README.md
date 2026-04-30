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

`alpha` adds or increments a `-vN` suffix and **skips** `manifest.json` — the manifest only ever contains official release versions. `release` strips the suffix and updates the manifest. Users running `1.0.1-v0` will see the update banner when the official `1.0.1` ships because a release version is always considered newer than a pre-release with the same base version.

### How update checking works

On app launch, `KKUpdateChecker` fetches the latest GitHub release and looks for a `manifest.json` asset. It compares each component version in the manifest against the `CFBundleShortVersionString` of the locally installed bundle at `/Applications/Keyframeless/`. If any component has a newer version, or a component exists in the manifest but isn't installed, the update banner is shown. Pre-release suffixes (e.g. `-v0`) are stripped for comparison, and a release version is treated as newer than a pre-release with the same base version.

### Releasing

GitHub releases are tagged by date (e.g. `2026-03-24`) rather than a component version — the `manifest.json` asset is what communicates individual component versions to the update checker.

1. Bump the component(s) that changed using the script above.
2. Build, sign, and notarize the `.pkg` (see below).
3. Create a GitHub release tagged with today's date and attach both the signed `.pkg` and the repo root `manifest.json` as release assets.

### KeyframelessKit

`KeyframelessKit` is a shared framework linked by all components — it has no version in the manifest. When it changes, bump whichever components ship with the new behaviour. If it's a framework-wide fix, bump all components.

### Adding a new component

The manifest key is the project name lowercased with no spaces or separators (e.g. `MagicMove` → `magicmove`, `Keyframeless X` → `keyframelessx`).

1. Add an entry to `manifest.json` with the key and initial version (e.g. `"newplugin": "1.0.0"`).
2. Add the key to `KKKnownComponents()` and `KKBundleIDToComponent()` in `KKUpdateChecker.m` — map both the wrapper app and XPC service bundle IDs.
3. Add a case to `scripts/bump-version.sh` that updates the relevant `Info.plist` files and calls `bump_manifest`.
4. Call `addUpdateBannerParameterWithAPI:error:` at the start of `addParametersWithError:` and pass `[KKPlugin servicePrincipalDelegate]` to `startServicePrincipalWithDelegate:` in `main()` to wire up update checking.
5. Add the component to `Packages` as a separate package so end users can install it independently.

## Code Signing & Notarization

### Pre-requisites

Generate the following in XCode (`Settings > Apple Accounts > Manage Certificates`):

- Developer ID Application - signing the `.app`
- Developer ID Installer — signing the `.pkg`
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

Build the installer and sign it in one step:

```sh
scripts/build-and-sign.sh "<apple-id>" "<team-id>"
```

This runs `packagesbuild` on `Distribution/Keyframeless.pkgproj`, then signs, notarizes, staples, and verifies the resulting `.pkg`.

To sign an already-built `.pkg` without rebuilding:

```sh
scripts/sign-pkg.sh "<apple-id>" "<team-id>"
```
