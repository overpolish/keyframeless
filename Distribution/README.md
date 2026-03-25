# Distribution

- Use `Packages` for generating the `pkg`.
- All plugins are separate packages allowed end users to customize which plugins they want to install.
- `<Plugin>.app` are installed to `/Applications/Keyframeless`.
- The `postinstall` script automatically moves the package templates into the correct Motion Templates folder.

## Version Management

Each component (`motionblur`, `rounded`, `keyframelessx`) is versioned independently.

### Bumping a version

```sh
scripts/bump-version.sh <component> <version>
```

This updates the relevant `Info.plist` / `.pbxproj` files and writes the new version into `manifest.json`.

### Pre-release / alpha builds

Use a `-` suffix for pre-release versions (e.g. `1.0.1-v0`). Pre-release versions update the app version but **skip** `manifest.json` — the manifest only ever contains official release versions.

```sh
scripts/bump-version.sh keyframelessx 1.0.1-v0   # alpha build, manifest unchanged
scripts/bump-version.sh keyframelessx 1.0.1       # official release, manifest updated
```

When the official `1.0.1` release ships, users running `1.0.1-v0` will see the update banner because a release version is always considered newer than a pre-release with the same base version.

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

The manifest key is the project name lowercased with no spaces or separators (e.g. `MotionBlur` → `motionblur`, `Keyframeless X` → `keyframelessx`).

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

### Signing `.pkg`

After using `Packages` to build an installer you'll need to sign it with a certificate.

```sh
productsign --sign "<cert>" \
    ./Distribution/build/Keyframeless.pkg \
    ./Distribution/build/Keyframeless-signed.pkg
```

Then notarize it with:

```sh
xcrun notarytool submit ./Distribution/build/Keyframeless-signed.pkg \
  --apple-id "<email>" \
  --team-id "<team id>" \
  --wait
```

Finally, staple it:

```sh
xcrun stapler staple ./Distribution/build/Keyframeless-signed.pkg
xcrun stapler validate ./Distribution/build/Keyframeless-signed.pkg
```

For good measure verify the `.pkg` will not get a gatekeeper warning:

```sh
spctl --assess --type install ./Distribution/build/Keyframeless-signed.pkg
```