AI

# AI Integration — Planning

Cross-product plan: caption translation in Keyframeless X (workflow ext) and AI-assisted animation in FxPlug plugins (post-Rounded migration). Shared infrastructure so both features ride on the same foundation.

## Goals

- **Workflow ext (Keyframeless X)**: AI-assisted caption translation + custom prompt chat acting on selected rows
- **FxPlug plugins**: AI input field in logo banner, answers questions about the plugin + generates Basic-mode animations from a description
- Bring-your-own API key; cost stays with the user

## Shared infrastructure

### Keychain layer

- Single shared Keychain access group: `$(TeamID).com.overpolish.ai-keys`
- All targets (host apps, FxPlug XPCs, workflow ext) declare `keychain-access-groups` entitlement
- Pure-Swift module: read/write/list/delete by provider
- Items stored: one per provider (`anthropic`, `openai`, `gemini`)

### Provider abstraction

- Day-one providers: **Anthropic, OpenAI, Gemini** (covers ~all users' existing keys)
- Thin protocol with one method: structured request (system prompt + user message + JSON schema → parsed output)
- Each provider implementation handles its own auth header, endpoint, request shape
- Never logs keys; request goes app → provider direct (no proxy server)

### Settings UI

- SwiftUI popover, reused across surfaces via NSHostingView wrapper for FxPlug ViewBridge XPC
- Provider dropdown + secure key field + "Test connection" + "Get a key" link
- **Validation pings on save** (e.g. `/v1/models` for Anthropic) so bad keys fail fast
- First-paste shows a small spend-cap warning

## Surface 1: Workflow ext (translation + chat)

- AI button in edit page
- No key → opens key-input popover
- Has key → opens chat popover
- Acts on **selected rows only**, hint shows count ("Translate 12 selected captions to…")
- **Preview-then-apply** — never auto-write, translation is destructive to edited-words store
- Word-range mapping format: LLM returns `[{src_idx_range:[a,b], translated:"..."}]` so per-word timestamps survive many-to-many word counts across languages
- Batch full sentences per request (not per word) for latency + cost
- Cache by `(source_text + target_lang + model)` hash

## Surface 2: FxPlug logo-banner field

- Always-visible input in logo banner
- No key → opens key-input popover
- Has key → opens chat popover
- Acts on **currently selected KKTimeline segment** by default
- System prompt includes: machine-readable plugin docs + vocabulary + current KKTimeline state (~1000 tokens)
- Response is DSL/JSON → parsed → KKTimeline mutation. **LLM never touches the data model directly.**

## Chat behavior (both surfaces)

- **One-shot with "Refine" button** — no persistent history in v1
- Refine sends `[last output] + [new instruction]` as a fresh one-shot (feels like multi-turn without state management)
- System prompt (hidden, ours): capabilities, output schema, current state, guardrails
- User message (free-form): their ask, prepended/appended to system prompt
- Last response stays visible until applied or dismissed

## Cost expectations

- Translation with Haiku 4.5: ~$0.002/min of video (~500 min = $1)
- Animation generation: similar order — small context, structured output
- No spend gating beyond first-paste warning

## Build order

1. Shared Keychain + entitlements + provider protocol
2. Settings popover (SwiftUI) + on-save validation
3. **Prototype in FxPlug first** (harder env: ViewBridge XPC + AppKit shim). If it works there, workflow ext is trivial.
4. Workflow ext translation flow (word-range mapping, preview-then-apply, cache)
5. FxPlug banner + Basic-mode animation generation

## Deferred (not v1)

- Persistent chat history (per-project or otherwise)
- Multi-turn proper (with token-growth management)
- MCP server (better fit for plugin assistant once stable; not needed for in-app translation)
- Distributed/local model fallback
- Spend caps / usage dashboard

## Open decisions (resolve while building, not now)

- Whether the FxPlug banner is one shared chat across plugins or per-plugin instance
- Default provider/model per surface (translation may want Haiku, animation may want Sonnet)
