/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Feedback intake. The form (public/index.html) is served by Cloudflare's
// static assets; only POST /submit reaches this Worker. We verify the Turnstile
// token, then open a GitHub issue using GITHUB_TOKEN - which never leaves here.

const PLUGIN_NAMES = {
  rounded: "Rounded",
  magicmove: "Magic Move",
  canvas: "Canvas",
  glow: "Glow",
  keyframelessx: "Keyframeless X",
};

const MAX_TITLE = 120;
const MAX_BODY = 8000;
const MAX_IMAGES = 5;
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const ALLOWED_IMAGE_TYPES = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/gif": "gif",
  "image/webp": "webp",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/submit") {
      return handleSubmit(request, env);
    }
    if (request.method === "POST" && url.pathname === "/github-webhook") {
      return handleWebhook(request, env);
    }
    return new Response("Not found", { status: 404 });
  },
};

async function handleSubmit(request, env) {
    let form;
    try {
      form = await request.formData();
    } catch {
      return json({ error: "Invalid form data" }, 400);
    }
    const field = (k) => String(form.get(k) || "").trim();

    // Honeypot - bots fill it, humans never see it. Pretend success.
    if (field("website")) return json({ ok: true }, 200);

    const type = field("type") === "bug" ? "bug" : "idea";
    const title = field("title").slice(0, MAX_TITLE);
    const description = field("description").slice(0, MAX_BODY);
    const email = field("email").slice(0, 200);
    const plugin = field("plugin").slice(0, 40);
    const version = field("version").slice(0, 40);
    const token = field("turnstileToken");

    if (!title || !description) {
      return json({ error: "Missing title or description" }, 400);
    }

    // 1. Verify the human passed Turnstile (the secret stays server-side).
    const ip = request.headers.get("CF-Connecting-IP") || "";
    const passed = await verifyTurnstile(env.TURNSTILE_SECRET, token, ip);
    if (!passed) return json({ error: "Failed anti-spam check" }, 400);

    // 2. Upload any screenshots to R2 first, collecting their public URLs.
    let imageUrls = [];
    let imageKeys = [];
    try {
      ({ urls: imageUrls, keys: imageKeys } = await uploadImages(
        env,
        form.getAll("images")
      ));
    } catch (err) {
      return json({ error: err.message || "Bad image upload" }, 400);
    }

    // 3. Open the issue as the token's account (submitter stays anonymous).
    const niceName = PLUGIN_NAMES[plugin] || plugin || "Keyframeless";
    const issueTitle = `[${niceName}] ${title}`;
    const body = buildBody({
      type,
      description,
      plugin: niceName,
      version,
      email,
      imageUrls,
    });
    const labels = ["feedback", type, plugin].filter(Boolean);

    let issueUrl;
    try {
      issueUrl = await createIssue(env, issueTitle, body, labels);
    } catch (err) {
      // Don't leave orphaned uploads if the issue couldn't be created.
      await Promise.all(
        imageKeys.map((k) => env.ATTACHMENTS.delete(k).catch(() => {}))
      );
      return json({ error: "Could not create issue" }, 502);
    }
    return json({ ok: true, url: issueUrl }, 200);
}

// GitHub webhook: when an issue is closed or deleted, remove its R2 screenshots.
// (A bucket lifecycle TTL is the backstop for anything this misses.)
async function handleWebhook(request, env) {
  const payload = await request.text();
  const valid = await verifySignature(
    env.GITHUB_WEBHOOK_SECRET,
    payload,
    request.headers.get("X-Hub-Signature-256")
  );
  if (!valid) return new Response("Bad signature", { status: 401 });

  if (request.headers.get("X-GitHub-Event") !== "issues") {
    return new Response("Ignored", { status: 200 });
  }

  let data;
  try {
    data = JSON.parse(payload);
  } catch {
    return new Response("Bad JSON", { status: 400 });
  }

  if (data.action !== "closed" && data.action !== "deleted") {
    return new Response("Ignored", { status: 200 });
  }

  const keys = extractAttachmentKeys(env, data.issue?.body || "");
  await Promise.all(
    keys.map((k) => env.ATTACHMENTS.delete(k).catch(() => {}))
  );
  return new Response(`Deleted ${keys.length}`, { status: 200 });
}

async function verifySignature(secret, payload, header) {
  if (!secret || !header) return false;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(payload));
  const hex = [...new Uint8Array(sig)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return timingSafeEqual(`sha256=${hex}`, header);
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

// Pull our R2 object keys (feedback/<uuid>.<ext>) out of an issue body.
function extractAttachmentKeys(env, body) {
  if (!env.R2_PUBLIC_URL) return [];
  const base = env.R2_PUBLIC_URL.replace(/\/$/, "").replace(
    /[.*+?^${}()|[\]\\]/g,
    "\\$&"
  );
  const re = new RegExp(`${base}/(feedback/[A-Za-z0-9._/-]+)`, "g");
  const keys = new Set();
  let m;
  while ((m = re.exec(body)) !== null) keys.add(m[1]);
  return [...keys];
}

async function verifyTurnstile(secret, token, ip) {
  if (!secret || !token) return false;
  const form = new FormData();
  form.append("secret", secret);
  form.append("response", token);
  if (ip) form.append("remoteip", ip);
  const res = await fetch(
    "https://challenges.cloudflare.com/turnstile/v0/siteverify",
    { method: "POST", body: form }
  );
  const outcome = await res.json();
  // Keep a single failure line so future Turnstile issues are tailable.
  if (!outcome.success) {
    console.log("turnstile verify failed", outcome["error-codes"]);
  }
  return outcome.success === true;
}

async function uploadImages(env, files) {
  const images = files.filter(
    (f) => f && typeof f.arrayBuffer === "function" && f.size > 0
  );
  if (images.length === 0) return { urls: [], keys: [] };
  if (images.length > MAX_IMAGES) {
    throw new Error(`At most ${MAX_IMAGES} images allowed`);
  }
  if (!env.ATTACHMENTS || !env.R2_PUBLIC_URL) {
    throw new Error("Image uploads are not configured");
  }

  const base = env.R2_PUBLIC_URL.replace(/\/$/, "");
  const urls = [];
  const keys = [];
  for (const file of images) {
    const ext = ALLOWED_IMAGE_TYPES[file.type];
    if (!ext) throw new Error("Images must be PNG, JPEG, GIF or WebP");
    if (file.size > MAX_IMAGE_BYTES) {
      throw new Error("Each image must be under 10MB");
    }
    const key = `feedback/${crypto.randomUUID()}.${ext}`;
    await env.ATTACHMENTS.put(key, file.stream(), {
      httpMetadata: { contentType: file.type },
    });
    keys.push(key);
    urls.push(`${base}/${key}`);
  }
  return { urls, keys };
}

function buildBody({ type, description, plugin, version, email, imageUrls }) {
  const lines = [description];
  if (imageUrls && imageUrls.length) {
    lines.push("", "### Screenshots");
    for (const url of imageUrls) lines.push(`![screenshot](${url})`);
  }
  lines.push(
    "",
    "---",
    `- **Type:** ${type}`,
    `- **Plugin:** ${plugin}`,
    version ? `- **Version:** ${version}` : null,
    email ? `- **Email:** ${email}` : "- **Email:** (not provided)",
    "",
    "_Submitted via the in-app feedback form._"
  );
  return lines.filter((l) => l !== null).join("\n");
}

async function createIssue(env, title, body, labels) {
  const post = (payload) =>
    fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/issues`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.GITHUB_TOKEN}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "keyframeless-feedback-worker",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });

  let res = await post({ title, body, labels });
  // A missing label is the likely 422 cause - retry without labels so genuine
  // feedback is never dropped over a label-setup gap.
  if (res.status === 422 && labels.length) {
    res = await post({ title, body });
  }
  if (!res.ok) throw new Error(`GitHub ${res.status}`);
  const issue = await res.json();
  return issue.html_url;
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
