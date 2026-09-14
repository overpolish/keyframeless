---
id: transcription
summary: How audio gets transcribed - on-device, supports FCP audio filters and compound clips
---

Transcription runs locally on the user's Mac. No audio leaves the machine.

**Audio source.** The audio fed to the transcriber is the FCP-filtered audio of each clip - any audio effects applied in FCP's effect stack (compressor, EQ, etc.) are applied first. See `audio-filters` for detail. Playback in the Edit tab also uses the same filtered audio so the user hears what the transcriber heard.

**Compound clips** are handled transparently: each inner clip inside an FCP compound is extracted with its own filters, and the outer compound's filters, volume, and fades are applied on top during render. See `compound-clips`.

**Re-transcribing.** "Reprocess Selected" in the Edit tab returns to Setup with the selected clips, letting the user pick a different model/language combination and re-run on just those. This is how users mix and match - e.g. Large v3 on the keynote clip, Small on the b-roll.
