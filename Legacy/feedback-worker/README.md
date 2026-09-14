# keyframeless-feedback

Cloudflare Worker behind the in-app "Send feedback" button. It is an API only: the form is a page on the site (`docs/feedback/index.html`, live at keyframeless.com/feedback) and this Worker exposes `POST /feedback/submit`, which verifies a Cloudflare Turnstile token, uploads any screenshots to R2, and opens a GitHub issue in `overpolish/keyframeless`. A second route (`/feedback/github-webhook`) deletes an issue's screenshots from R2 when it's closed. The GitHub token, Turnstile secret, and webhook secret live only in Worker secrets - they never reach the client.

## Architecture

```mermaid
flowchart TD
  Btn["in-app Send feedback button"] -->|"GET / (plugin + version)"| Form["Feedback form<br/>(static asset)"]
  Form -->|"POST /submit (multipart)"| Submit

  subgraph Worker["Worker (API only) · keyframeless.com/feedback/*"]
    Submit["/feedback/submit"]
    Hook["/feedback/github-webhook"]
  end

  Submit -->|"verify token"| TS["Turnstile siteverify"]
  Submit -->|"upload"| R2[("R2 bucket")]
  Submit -->|"create issue"| GH["GitHub issue<br/>(+ image URLs)"]
  GH -.->|"issue link"| Form
  GH -->|"issue closed / deleted"| Hook
  Hook -->|"verify signature + delete"| R2
```

Only `/feedback/submit` and `/feedback/github-webhook` are routed to the
Worker code.

## One-time setup

1. **Cloudflare account** + wrangler: `npm i -g wrangler && wrangler login`.
2. **Turnstile widget** (dashboard → Turnstile). Add domains `keyframeless.com` and `localhost`. Note the **site key** and **secret key**.
3. Put the **site key** into `docs/feedback/index.html` (replace `TURNSTILE_SITE_KEY` in the `data-sitekey` attribute).
4. **GitHub PAT**: fine-grained, scoped to `overpolish/keyframeless` only, permission **Issues: Read and write**.
5. **Labels**: create these in the repo so they can be applied - `feedback`, `bug`, `idea`, `rounded`, `magicmove`, `canvas`, `glow`, `keyframelessx`. (Missing labels are tolerated: the Worker retries without them, but the issue then lands unlabelled.)
6. **R2 bucket** for screenshots: `wrangler r2 bucket create keyframeless-feedback`, then enable the public **r2.dev** URL (dashboard → R2 → bucket → Settings) and set it as `R2_PUBLIC_URL` in `wrangler.jsonc`. Uploads cap at 5 images, 10MB each.
7. **Webhook** (screenshot cleanup): repo → Settings → Webhooks → Add. Payload URL `https://keyframeless.com/feedback/github-webhook`, content type `application/json`, secret = `GITHUB_WEBHOOK_SECRET`, events: **Issues** only. As a TTL backstop, add a bucket lifecycle rule deleting the `feedback/` prefix after ~180 days.

## Secrets

Local (`wrangler dev`): copy `.dev.vars.example` to `.dev.vars` and fill in.

Production:

```
wrangler secret put TURNSTILE_SECRET
wrangler secret put GITHUB_TOKEN
wrangler secret put GITHUB_WEBHOOK_SECRET
```

`GITHUB_REPO` and `R2_PUBLIC_URL` are non-secret vars in `wrangler.jsonc`.

## Develop

```
npm install
npm run dev      # serves form + /submit at http://localhost:8787
```

The in-app DEBUG build points the feedback button at `http://localhost:8787/`, so run this while testing the plugins locally.

## Deploy

```
npm run deploy
```

The Worker is mounted on the site's own domain via exact routes, while Cloudflare Pages serves the form and every other site path. `keyframeless.com` must remain proxied (orange cloud), with SSL mode Full. The Worker and form share an origin, so no CORS is needed. Until the routes are configured, the Worker is reachable at its `*.workers.dev` URL (update the production URL in `KKUpdateChecker.m` if you ship before the custom domain is live).
