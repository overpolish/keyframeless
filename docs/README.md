# docs/ - the keyframeless.com site

Served by GitHub Pages at https://keyframeless.com/ (Settings > Pages > deploy
from `main`, folder `/docs`; the domain comes from `CNAME`).

- `index.html` is the hand-written landing page. The generator never touches it.
- `<product>/index.html` are the release-notes pages. Each carries a
  `<meta name="kk-version">` tag that `KKUpdateChecker` reads to decide whether
  to show the in-app update banner.
- `feedback/` bounces to the Cloudflare worker in `feedback-worker/`.

**The `*.html` files under `<product>/` are GENERATED - do not edit them.** They
are built by `scripts/build-changelog.py`. Edit these sources instead, then
rerun the script:

- `changelog/<product>/<version>.md` - one file per release (also pasteable as a
  GitHub Release body). The filename is the version, which becomes the meta tag.
- `changelog/plugins.json` - per-product metadata (name, kind, Payhip URL,
  aliases) plus the site-wide `download` URL.
- `assets/style.css` - release-notes styling. `assets/landing.css` is the
  landing page only.

## Update-check paths

`KKUpdateChecker` derives its path from the running bundle's ID
(`KKComponentForBundleID`), so the folder under `changelog/` must match that
slug: `mirage`, `canvas`, `keyframelessx`. Kai's check is hardcoded to
`kai`. Rename a folder without changing the code and the in-app
update banner silently stops appearing for that product.

**One binary, one version.** Keyframeless X ships Steno and Sonar in a single
extension, so they are not versioned separately: there is one changelog
(`changelog/keyframelessx/`) and its entries say which tool changed. The
updater compares the page's `kk-version` against the running bundle's
`CFBundleShortVersionString`, so a per-tool version could not be read anyway.

## Media (images / GIFs / video)

**Do not commit media to the repo** - especially video. Upload it to the R2 media bucket and reference its public URL, so the changelog can grow without bloating git:

```sh
wrangler r2 object put keyframeless-media/<component>/<version>/demo.mp4 --file ./demo.mp4
```

(or drag-drop in the Cloudflare dashboard). The bucket is served over the custom domain `media.keyframeless.com`, so the absolute URL renders both on the site and in a GitHub Release body:

- `![caption](https://media.keyframeless.com/<component>/<version>/shot.png)` - image or GIF
- a bare `https://media.keyframeless.com/.../demo.mp4` URL on its own line - video

This bucket is separate from the feedback Worker's bucket (whose uploads auto-delete) - changelog media is permanent.

`CNAME` is the GitHub Pages custom domain (do not remove). See `CONTRIBUTING.md` for the local preview loop and how to test the update banner against a local server.
