---
id: audio-filters
summary: FCP audio filters - compressor, EQ, etc - are applied before transcription and playback
---

When the user drops a timeline onto Keyframeless, any audio effects applied to each clip in FCP (compressor, EQ, gain, third-party Audio Units, etc.) come through with the audio. These filters are applied automatically before the audio is transcribed and before in-app playback - so what the user hears in the Edit tab and what the transcriber processed are identical to what FCP plays during preview.

**Compound clips.** Filters on the inner clip apply first, then the filters on the outer compound apply on top. Outer volume curves and fades are also respected. See `compound-clips`.

**Why this matters for transcription quality.** A heavy compressor or noise-reduction filter in FCP will materially change what the transcriber hears. If a clip transcribes badly, it can be worth checking whether an aggressive filter in FCP is altering the audio. Bypassing the filter in FCP (toggling its enable checkbox) and re-dropping the timeline gives the transcriber the raw audio.

**No UI controls.** Filters are passed through silently - there's no toggle to disable them inside Keyframeless. Filter changes in FCP require a fresh timeline drop to be picked up.
