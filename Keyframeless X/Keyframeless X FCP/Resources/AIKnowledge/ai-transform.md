---
id: ai-transform
summary: AI feature - transforms selected transcriptions and answers questions; BYO API key
---

The AI feature in Steno has two modes triggered from the same sparkles button in the top-left of the workflow extension:

**1. Transform.** The user selects transcribed clips and types a natural-language instruction ("translate to german", "fix capitalization", "strip filler words", "make formal"). Each selected sentence (or SRT cue) is sent independently to the model. The result is shown in a preview modal grouped by clip, where the user can include/exclude individual sentences before clicking Apply. Word-level timing is preserved. Applied transforms behave like sentence-level edits - the per-row reset arrow restores the original.

**2. Answer.** When the user asks a question instead of giving a transform instruction (e.g. "does this support srt export?"), the AI answers inline in the popover. It never modifies the transcription. The classification between transform vs answer happens automatically before any work is done.

**Providers.** Anthropic (Claude Haiku) and OpenAI (GPT-4o mini). The user brings their own API key - there's no hosted option. Keys are stored in the macOS Keychain. The active provider is picked in the popover's top-right selector.

**Why BYOK.** Motion graphics work is often under NDA; routing through a proxy server would mean the user has to trust Keyframeless with the text. BYOK keeps the request between the user and the provider they already have a relationship with.
