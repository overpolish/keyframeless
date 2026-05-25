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

**Do not commit media to the repo** - especially video. Upload it to the R2 media bucket and reference its public URL, so the changelog can grow without bloating git:

```sh
wrangler r2 object put keyframeless-media/<component>/<version>/demo.mp4 --file ./demo.mp4
```

(or drag-drop in the Cloudflare dashboard). The bucket is served over the custom domain `media.keyframeless.overpolish.co`, so the absolute URL renders both on the site and in a GitHub Release body:

- `![caption](https://media.keyframeless.overpolish.co/<component>/<version>/shot.png)` - image or GIF
- a bare `https://media.keyframeless.overpolish.co/.../demo.mp4` URL on its own line - video

This bucket is separate from the feedback Worker's bucket (whose uploads auto-delete) - changelog media is permanent.

`CNAME` is the GitHub Pages custom domain (do not remove). See `CONTRIBUTING.md` for the local preview loop and how to test the update banner against a local server.
