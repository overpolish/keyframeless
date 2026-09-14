---
id: compound-clips
summary: FCP compound clips are fully supported with inner and outer audio adjustments
---

FCP compound clips are fully supported. Each audio clip inside the compound is shown individually in Keyframeless, with the compound's trimming, filters, volume, and fades layered on top during audio render.

**Visibility window.** Only the portion of an inner clip that falls inside the compound's trim range is extracted - clips entirely outside the compound's visible window are skipped. Partially-trimmed clips are clipped to just the visible portion and repositioned to the main timeline.

**Layered audio adjustments.** When audio is rendered for transcription and playback, the inner clip's own adjustments apply first, then the compound's outer adjustments are layered on top. This matches what FCP plays during preview, so transcription operates on the same audio the user hears.

**UI badge.** Compound clips show with an orange badge in the Setup and Edit tabs (vs blue for regular clips). The Setup tab's toolbar lets users filter "All / Audio / Compound" - this is just a display filter, not a processing restriction.

**No special restrictions.** Compound and regular clips can be mixed in any selection. All transcription, editing, and export actions behave identically for both.
