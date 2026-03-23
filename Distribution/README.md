# Distribution

- Use `Packages` for generating the `pkg`.
- All plugins are separate packages allowed end users to customize which plugins they want to install.
- `<Plugin>.app` are installed to `/Applications/Keyframeless`.
- The `postinstall` script automatically moves the package templates into the correct Motion Templates folder.

## Version Management

- Each package has its own version inside `Packages` tool.
- Additionally, versions need to be bumped in the `Info.plist` of the corresponding plugin.

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