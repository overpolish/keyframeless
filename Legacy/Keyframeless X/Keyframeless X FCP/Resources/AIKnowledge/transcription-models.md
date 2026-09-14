---
id: transcription-models
summary: Supported transcription models (Whisper and Parakeet) and which to pick
---

Steno supports two transcription engines, with different model options on Apple Silicon vs Intel Macs. All run locally on the user's machine.

**Apple Silicon models:**

- **Tiny** (~390 MB) - Whisper. Fastest, best for rough drafts.
- **Base** (~670 MB) - Whisper. Good speed and accuracy.
- **Small** (~1.4 GB) - Whisper. Handles accents and noise well.
- **Large v3 Turbo** (~1.6 GB) - Whisper. Near-large accuracy at speed.
- **Large v3** (~6 GB) - Whisper. Best accuracy, recommended for final exports.
- **Parakeet 0.6B v2** (~600 MB) - English only, fastest.
- **Parakeet 0.6B v3** (~600 MB) - 25 European languages, fast.

**Intel Macs:**

- **Tiny** (~200 MB), **Base** (~300 MB), **Small** (~600 MB). All ggml/Whisper. Large models are not available on Intel.

The default recommendation is chosen automatically based on the Mac's RAM: Large v3 if 16GB+, Small if 8GB+, otherwise Base. Users can override.

Models are downloaded on first use; the picker shows download progress. The Process button is disabled while a download is in flight.

**Parakeet caveats:**

- Parakeet v2 locks the language picker to English (it's English-only). The picker shows an overlay message when this model is selected.
- Parakeet v3 supports 25 European languages but not the full Whisper set.
