---
id: terms
summary: Custom vocabulary terms - help the transcriber catch proper nouns, brand names, and jargon
---

The Setup tab has a **Terms** section where the user can add keywords that bias the transcriber towards specific spellings. Useful for proper nouns (people, places, products), technical jargon, or anything Whisper/Parakeet would otherwise mishear or misspell.

**How it works.** Each term is tokenised and fed into the transcription pipeline. When the model hears a word that sounds close to a registered term, it's more likely to output the term's exact spelling. This catches things like "Keyframeless" (instead of "key frameless"), product names, foreign names, etc.

**Limits.**

- Up to **15 terms** per project.
- Each term up to **30 characters** long.
- Duplicates (case-insensitive) are rejected.

**Adding a term.** Type into the "Add a term..." field and press Return (or the small return icon). The term appears in the list below. Click the x next to a term to remove it.

**Parakeet caveat.** When using a Parakeet model, the Terms feature requires a separate "CTC engine" to be downloaded. If it isn't present, the Terms panel shows a lock overlay with a Download button. Whisper models don't need this extra download.

**When to use it.** Most useful when transcribing content with niche vocabulary - tech podcasts, medical conferences, brand-heavy marketing copy, foreign names. For general dialogue with common words, terms are unnecessary.
