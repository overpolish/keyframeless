/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Activation endpoint. Verifies a license key against Payhip, then returns a
// payload SIGNED with a P-256 private key that exists only here. The plugin
// verifies that signature offline forever after, against the public half
// compiled into the binary (KKLicense.m / LicenseManager.swift), so a user can
// activate once and never need a connection again - while a hand-written
// activation record fails, because forging one needs this key.
//
// Stateless by design: Payhip stays the source of truth for which keys are
// valid and which have been disabled, so there is no database to keep.
//
// Secrets (wrangler secret put):
//   LICENSE_PRIVATE_KEY_PKCS8  base64 PKCS#8 of the P-256 private key
//   PAYHIP_SECRET_<PRODUCT>    Payhip product secret, one per product
//                              (e.g. PAYHIP_SECRET_MIRAGE)

const PRODUCTS = ['mirage', 'canvas', 'steno']

// Binds each record to the machine that activated it, so a copied activation
// record fails on the machine it was copied to. Activations stay UNCAPPED: this
// Worker holds no state, so the same key re-signs for any machine that asks. A
// new machine just activates again, needing the internet once, exactly like the
// first install. It does not stop a shared KEY, which would need a cap, which
// would need state.
const BIND_TO_MACHINE = true

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url)
    if (request.method !== 'POST' || pathname !== '/activate') {
      return new Response('Not found', { status: 404 })
    }

    let body
    try {
      body = await request.json()
    } catch {
      return json({ error: 'bad request' }, 400)
    }
    const licenseKey = String(body.licenseKey ?? '').trim()
    const product = String(body.product ?? '').trim()
    const machineID = String(body.machineID ?? '').trim()
    if (!licenseKey || !PRODUCTS.includes(product)) return json({ error: 'bad request' }, 400)

    const secret = env[`PAYHIP_SECRET_${product.toUpperCase()}`]
    if (!secret) return json({ error: 'product not configured' }, 500)

    // Payhip decides whether the key is real and still enabled.
    const verify = await fetch(
      `https://payhip.com/api/v2/license/verify?license_key=${encodeURIComponent(licenseKey)}`,
      { headers: { 'product-secret-key': secret } }
    )
    if (verify.status >= 400 && verify.status < 500) return json({ error: 'invalid key' }, 400)
    if (!verify.ok) return json({ error: 'upstream' }, 502)

    const root = await verify.json().catch(() => null)
    const data = root?.data ?? root
    if (!data) return json({ error: 'invalid key' }, 400)
    const enabled = data.enabled === true || data.enabled === 1 || data.enabled === 'true' || data.enabled === '1'
    if (!enabled) return json({ error: 'disabled' }, 403)

    // Claims the client re-checks. `keyHash` rather than the key itself so a
    // stored record doesn't carry the purchase credential in the clear.
    const claims = {
      product,
      keyHash: await sha256Hex(licenseKey),
      issuedAt: Math.floor(Date.now() / 1000),
    }
    if (data.buyer_email) claims.email = data.buyer_email
    if (BIND_TO_MACHINE && machineID) claims.machineID = machineID

    // The client stores and verifies these EXACT bytes. Never re-serialize the
    // payload on either side: a different key order or spacing is a different
    // message and the signature stops matching.
    const payload = new TextEncoder().encode(JSON.stringify(claims))
    const signature = await sign(payload, env.LICENSE_PRIVATE_KEY_PKCS8)

    return json({ payload: b64(payload), signature: b64(signature) })
  },
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function b64(bytes) {
  let s = ''
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b)
  return btoa(s)
}

function fromB64(str) {
  const bin = atob(str)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

async function sign(payload, pkcs8B64) {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    fromB64(pkcs8B64),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  )
  const raw = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, payload)
  return derFromP1363(new Uint8Array(raw))
}

// WebCrypto emits r||s fixed-width; Security.framework and CryptoKit both want
// DER. Without this conversion every signature fails to verify on the client.
function derFromP1363(sig) {
  const half = sig.length / 2
  const r = trimInt(sig.slice(0, half))
  const s = trimInt(sig.slice(half))
  const body = new Uint8Array(2 + r.length + 2 + s.length)
  body.set([0x02, r.length], 0)
  body.set(r, 2)
  body.set([0x02, s.length], 2 + r.length)
  body.set(s, 4 + r.length)
  const der = new Uint8Array(2 + body.length)
  der.set([0x30, body.length], 0)
  der.set(body, 2)
  return der
}

// DER integers are signed and minimally encoded: strip leading zero bytes, then
// prepend one back if the top bit would otherwise read as negative.
function trimInt(bytes) {
  let i = 0
  while (i < bytes.length - 1 && bytes[i] === 0) i++
  const trimmed = bytes.slice(i)
  if (trimmed[0] & 0x80) {
    const padded = new Uint8Array(trimmed.length + 1)
    padded.set(trimmed, 1)
    return padded
  }
  return trimmed
}
