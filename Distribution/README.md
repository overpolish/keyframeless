# Distribution

`scripts/build-pkg.sh` builds the Keyframeless installer with Apple's own tools. It finds every plugin in the repository, builds each one, and produces a single package whose Customize pane lists them, so a buyer installs the whole suite or picks from it. Everything the build needs is committed here as text: `distribution.xml.in` is the installer script and `scripts/postinstall.in` the permissions script, both filled in from what the build discovered.

```sh
scripts/build-pkg.sh             # unsigned, for local testing
scripts/build-pkg.sh --sign      # signed with a Developer ID Installer certificate
scripts/build-pkg.sh --notarize  # signed, notarized and stapled: what releases ship
```

The result is `Distribution/build/Keyframeless-<version>.pkg`, versioned by the newest plugin in it while each component package keeps its own version. `MM_PACKAGE_DERIVED_DATA` chooses the build directory, `MM_INSTALLER_IDENTITY` the signing identity, and `MM_NOTARY_PROFILE` the stored notarytool credentials, which default to a keychain profile named `keyframeless`. Create that profile once with:

```sh
xcrun notarytool store-credentials keyframeless --apple-id "<apple-id>" --team-id "<team-id>"
```

The build checks each committed Motion template against the plugin's registered parameters, builds Release for both architectures, stages the payload, and turns off bundle relocation so the installer cannot follow a copy registered from a build directory. `--notarize` submits the package, waits for the result, staples the ticket into it so it installs on a Mac that has never been online with it, and reports what `spctl` makes of the result.

Notarization inspects every nested binary, which is why the Release configurations sign with `--timestamp` and set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`. Without the first the signature carries no secure timestamp; without the second Xcode adds `com.apple.security.get-task-allow` to a Release build and the submission comes back Invalid.

## What a plugin declares

Each plugin's application carries a `KFInstall` dictionary in its `Info.plist`:

| Key | Meaning |
| --- | --- |
| `ApplicationDirectory` | Where the application is installed, `/Applications/Keyframeless` |
| `TemplateRelativePath` | The template's path under either template folder, for example `Effects.localized/Keyframeless/Magic Move` |
| `PreferencesSuite` | The defaults domain the plugin writes |
| `ProductName` | The name shown in the installer and in the uninstall window |
| `Description` | The sentence the installer shows beside the plugin in its Customize pane |

The build reads that dictionary out of the built application to lay out the payload, and the uninstaller reads it back at runtime, so the two halves cannot drift. `scripts/motion-template.py check` fails if `TemplateRelativePath` and the template manifest disagree. The component package identifier is the application's bundle identifier with `.pkg` appended.

## Presentation

The installer's artwork is drawn from `Assets/installer.svg`, rasterized during the build by `sips` at the 1240x840 the source declares, which is the installer window at 2x. It is the mark on a transparent canvas, and the installer honours the alpha, so its own window shows through and one image serves both the light and dark appearances. The package file carries the Keyframeless icon, taken from the icns Xcode builds for the application. That icon lives in the file's resource fork, which is where Finder looks and where Packages.app put it too, so a transfer that drops metadata drops the icon and nothing else.

## What is installed

| Path | Contents |
| --- | --- |
| `/Applications/Keyframeless/<Plugin>.app` | The wrapper application and the FxPlug service PlugInKit registers |
| `/Library/Application Support/Final Cut Pro/Templates.localized/<Kind>.localized/Keyframeless/<Name>` | The Motion template Final Cut Pro shows the effect through |

The template is installed once for every account rather than copied into one user's `~/Movies/Motion Templates.localized`, so the package needs no script to guess who is logged in. Both locations are read by Final Cut Pro and Motion.

The postinstall script leaves the payload owned by root but writable by the `admin` group, which is how `/Applications` itself behaves and how any dragged-in application ends up. Only the paths this package wrote are changed, and the folders shared with other products are adjusted on their own rather than recursively.

## Removing it

Each plugin's application is its own uninstaller. Opening `/Applications/Keyframeless/<Plugin>.app` shows the plugin's name and version, a **Keep saved defaults** checkbox and an Uninstall button, and nothing else; the window says "Not installed" in place of the version when there is nothing to remove. Uninstalling removes the template, the application itself, the PlugInKit registration and, unless the checkbox is set, the saved preferences. Because the payload is writable by administrators, this normally needs no password and no authentication of any kind.

macOS does not offer Touch ID for administrator authorization. A prompt for a right such as `authenticate-session-owner-or-admin` does show it, but `system.privilege.admin`, the right that grants root execution, is password-only, and bridging the two needs a permanently installed privileged helper. An install that needs no privileges to remove avoids the question.

Anything the user still cannot delete, on a Mac where permissions were changed or for an account that is not an administrator, goes into one privileged command with the standard password dialog. The installer receipt is forgotten there too, since only root can retire one; after an ordinary uninstall the receipt outlives the files it recorded, which is harmless and is replaced on the next install. A receipt on its own is not treated as an installation.

Shared folders, `/Applications/Keyframeless` and the `Keyframeless` template category, are removed only when nothing else is left in them, and the empty sandbox container the hosts create for the service stays behind, because only containermanagerd may delete one.

`MagicMove/Tests/run-uninstall.sh` covers that model: what is found, what needs privileges, how paths are quoted for the privileged command, that an ordinary removal authenticates nothing, and that a folder another plugin still uses survives.
