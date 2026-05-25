# docs/ - changelog + update site

Served by GitHub Pages at https://update.keyframeless.overpolish.co/. Each plugin's
page carries a `<meta name="kk-version">` tag that `KKUpdateChecker` reads to decide
whether to show the in-app update banner.

**The `*.html` files are GENERATED - do not edit them.** They are built by
`scripts/build-changelog.py`. Edit these sources instead, then rerun the script:

- `changelog/<component>/<version>.md` - one file per release (also pasteable as a
  GitHub Release body). The filename is the version, which becomes the meta tag.
- `changelog/plugins.json` - per-plugin metadata (name, kind, Payhip URL, releases URL).
- `assets/style.css` - styling.

## Media (images / GIFs / video)

**Do not commit media to the repo.** Drag the file into any GitHub editor (a release
draft, issue, or comment) to upload it - GitHub returns a `user-attachments` CDN URL.
Use that absolute URL in the release `.md` so it renders both on the site and on GitHub,
and the repo stays small as the changelog grows:

- `![caption](https://github.com/user-attachments/assets/...)` - image or GIF
- a bare `https://...` URL on its own line - video

`CNAME` is the GitHub Pages custom domain (do not remove). See `CONTRIBUTING.md` for the
local preview loop and how to test the update banner against a local server.
