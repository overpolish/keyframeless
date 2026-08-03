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

`alpha` adds or increments a `-vN` suffix and creates no changelog entry. `release` strips the suffix and creates the prefilled `docs/changelog/<product>/<version>.md`. Users running `1.0.1-v0` will see the update banner when the official `1.0.1` ships because a release version is always considered newer than a pre-release with the same base version.

### How update checking works

On app launch, `KKUpdateChecker` GETs the component's release-notes page (`<base>/<component>/`) and reads the `<meta name="kk-version">` tag, comparing it to the running bundle's `CFBundleShortVersionString`. If the page advertises a newer version, the update banner is shown. Pre-release suffixes (e.g. `-v0`) are stripped for comparison, and a release version is treated as newer than a pre-release with the same base version. The published version is just the changelog `.md` filename (which the build emits into the meta tag) - there is no `manifest.json`.

### Releasing

1. Bump the component(s) that changed using the script above.
2. Fill in `docs/changelog/<product>/<version>.md`.
3. Run `scripts/build-changelog.py`.
4. Build, sign, and notarize the per-product `.pkg` (see below).
5. Upload the signed `.pkg` to its Payhip product - buyers re-download the new file from there.
6. Publish the docs (commit + push) so the `kk-version` meta tag advertises the new version to installed builds.
7. Feedback (first release that ships the button, or after any Worker change): deploy the Worker (`cd feedback-worker && npm run deploy`) and make sure `KKFeedbackBaseURL()` in `KKUpdateChecker.m` points at a URL that resolves - `keyframeless.com/feedback/`, which needs the zone proxied through Cloudflare so the `/feedback/submit` route fires. Confirm the Turnstile widget allows `keyframeless.com` and the GitHub webhook points at `keyframeless.com/feedback/github-webhook`. See [Feedback Worker](#feedback-worker).

### KeyframelessKit

`KeyframelessKit` is a shared framework linked by all components - it carries no version of its own. When it changes, bump whichever components ship with the new behaviour. If it's a framework-wide fix, bump all components.

### Adding a new component

The component key is the project name lowercased with no spaces or separators (e.g. `Keyframeless X` → `keyframelessx`, `Canvas` → `canvas`).

1. Add the key to `KKBundleIDToComponent()` in `KKUpdateChecker.m` - map both the wrapper app and XPC service bundle IDs.
2. Add a case to `scripts/bump-version.sh` that updates the relevant `Info.plist` / `.pbxproj` files.
3. Call `addUpdateBannerParameterWithAPI:error:` at the start of `addParametersWithError:` and pass `[KKPlugin servicePrincipalDelegate]` to `startServicePrincipalWithDelegate:` in `main()` to wire up update checking.
4. Add the component to the combined `Distribution/Keyframeless.pkgproj` in Packages.app, and add its `key -> package identifier` to `COMPONENT_ID` in `scripts/split-pkgproj.py`. The per-product `.pkgproj` and per-plugin uninstaller are then generated automatically by `build-and-sign.sh`.
5. Add it to `docs/changelog/plugins.json` (name, kind, payhip) so it gets a changelog page + meta tag.
6. (Optional) Add the component's display name to `PLUGIN_NAMES` in `feedback-worker/src/index.js` and `docs/feedback/index.html`, and create a matching issue label, so feedback from it is attributed nicely. The feedback URL is derived from the component key automatically (step 1).

## Feedback Worker

The "Send feedback" button opens a form served by the Cloudflare Worker in `feedback-worker/`, which verifies a Turnstile token and opens a GitHub issue. It deploys independently of the plugin `.pkg`s - no plugin rebuild is needed unless the feedback URL changes.

### First-time setup

1. `cd feedback-worker && npm install`, then `wrangler login`.
2. Create a Turnstile widget (Cloudflare dashboard → Turnstile). Add `keyframeless.com` (where the form is served) **and** `localhost`. Put the **site key** into `docs/feedback/index.html` (`data-sitekey`).
3. Set the secrets (never committed):
   ```sh
   wrangler secret put TURNSTILE_SECRET       # the widget's secret key
   wrangler secret put GITHUB_TOKEN           # fine-grained PAT, Issues: RW on this repo
   wrangler secret put GITHUB_WEBHOOK_SECRET  # any random string; reused in the webhook (see below)
   ```
4. Create the issue labels so they can be applied: `feedback`, `bug`, `idea`, and one per component (`rounded`, `magicmove`, `canvas`, `glow`, `keyframelessx`). Missing labels are auto-created and colored grey (GitHub default).
5. Create the R2 bucket for screenshot uploads and enable public access:
   ```sh
   wrangler r2 bucket create keyframeless-feedback
   ```
   In the dashboard (R2 → the bucket → Settings) turn on the public **r2.dev** URL, then set it as `R2_PUBLIC_URL` in `wrangler.jsonc`. Uploads are capped at 5 images, 10MB each (enforced client- and server-side).

### Deploy

```sh
cd feedback-worker && npm run deploy
```

`deploy` re-syncs the form's CSS/icons from `docs/assets` first. Run it after any change to the form or Worker when ready to release.

### Custom domain

The Worker answers `keyframeless.com/feedback/submit` via Cloudflare routes, so the zone must be proxied (orange cloud) in front of GitHub Pages. Otherwise the Worker lives at `keyframeless-feedback.<account>.workers.dev` - set that URL as the production base in `KKFeedbackBaseURL()` in `KKUpdateChecker.m`.

### Screenshot cleanup

Uploaded screenshots are removed two ways:

- **On issue close (webhook).** In the repo: Settings → Webhooks → Add webhook. Payload URL `https://keyframeless.com/feedback/github-webhook`, content type `application/json`, secret = the `GITHUB_WEBHOOK_SECRET` set above, events: **Issues** only. When an issue is closed or deleted, the Worker parses its body for R2 URLs and deletes them. (Reopening a closed issue won't restore its images.)
- **TTL backstop.** In the dashboard (R2 → the bucket → Settings → Object lifecycle rules), add a rule to delete objects under the `feedback/` prefix after e.g. 180 days, to sweep anything the webhook misses (issues never formally closed, edited-out URLs).

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
scripts/build-and-sign.sh combined       "<apple-id>" "<team-id>"   # all-in-one Keyframeless.pkg
scripts/build-and-sign.sh canvas          "<apple-id>" "<team-id>"   # just Canvas.pkg
scripts/build-and-sign.sh all             "<apple-id>" "<team-id>"   # every plugin, one .pkg each
scripts/build-and-sign.sh keyframelessai  "<apple-id>" "<team-id>"   # the local-AI helper .pkg
```

Per-product targets generate a single-product `.pkgproj` and a per-plugin uninstaller
from `Distribution/Keyframeless.pkgproj` + `scripts/uninstall.template` (via
`scripts/split-pkgproj.py`), build, sign, then delete those temp files - nothing
per-plugin is committed. `combined` builds the committed `Keyframeless.pkgproj`. Each
runs `packagesbuild`, then signs, notarizes, staples, and verifies the resulting `.pkg`.

Per-product installers are named with their version, e.g. `Canvas-v2.0.0.pkg` (the
version comes from the package's `.pkgproj` entry, the same one `bump-version.sh`
maintains). `combined` still emits `Keyframeless.pkg`.

Before packaging an app/plugin, the script verifies that the notarized app in
`Distribution/release` exists and its `CFBundleShortVersionString` matches the package
version. Re-archive and export after every version bump; the script will not package an
older app under a newer installer version. The AI payload is built during packaging and
its manifest and complete SwiftPM runtime-bundle set are validated separately.

**Notarization credentials.** The scripts prefer a stored keychain profile named
`keyframeless` so notarization is non-interactive. Create it once:

```sh
xcrun notarytool store-credentials keyframeless --apple-id "<apple-id>" --team-id "<team-id>"
```

After that, the `<apple-id>`/`<team-id>` args passed to `build-and-sign.sh` are only a
fallback - the profile is used automatically. (The profile is selected by name, not by
probing the keychain: modern notarytool stores it in the data-protection keychain that
the legacy `security` tool can't read.) To ignore the profile and use the Apple ID +
app-specific-password path, run with an empty profile name:

```sh
KK_NOTARY_PROFILE= scripts/build-and-sign.sh all "<apple-id>" "<team-id>"
```

The unified `combined` installer always runs `stage_ai_helper` before packaging, so
Keyframeless AI cannot be omitted or picked up from a stale staging directory.
`stage_ai_helper` `xcodebuild`s the `kk-ai-helper` scheme in `KeyframelessAI/` (only the
Metal toolchain compiles MLX's metallib), thins it to arm64 (MLX is Apple-Silicon only),
Developer-ID signs it with the app-group + hardened-runtime entitlements, and stages it
plus its SwiftPM resource bundles into `Distribution/helper/staging` where the
`.pkgproj` payload points.

**`keyframelessai` remains a separate target and is NOT included in `all`.** Use that
target only when producing the standalone AI installer. `all` means the standalone
app/plugin packages; the supported suite installer is `combined`, which includes AI.

To sign an already-built `.pkg` without rebuilding (base name, no `.pkg`):

```sh
scripts/sign-pkg.sh "Canvas" "<apple-id>" "<team-id>"
```

To just generate a per-product `.pkgproj` for an unsigned local build:

```sh
python3 scripts/split-pkgproj.py rounded
packagesbuild "Distribution/Canvas.pkgproj"
```
