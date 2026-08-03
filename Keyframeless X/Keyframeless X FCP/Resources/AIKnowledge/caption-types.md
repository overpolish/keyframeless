---
id: caption-types
summary: Three caption types - Title (Keyframeless templates), Subtitles (FCP 12.3 native Subtitle), and Caption (FCP's built-in iTT/SRT/CEA-608)
---

In the Edit tab's export sidebar, the user picks one of three caption types:

**Title** (default).

- Exports as FCP Title clips - fully animatable.
- **Supports caption templates** from the Keyframeless plugin family (Canvas, Mirage, Template, plus any community templates). See `caption-templates`.
- Supports per-word animation on templates that opt into it.
- Style options apply: text font/size/color/Y-position, max words per line, one or two lines, ALL CAPS, no gaps, censor profanity, strip punctuation (with optional "Keep ? and !" override).

**Subtitles** (FCP's built-in Subtitle, FCP 12.3+).

- FCP 12.3 introduced a native **Subtitles** title. Steno generates it directly and lands it in FCP's built-in Subtitles role, so the captions arrive as first-class subtitles rather than a workaround.
- **Availability is gated.** The option only appears on FCP 12.3 or later, and only when the host's bundled `Subtitle.moti` is present (`FCPHost.supportsSubtitles`). On older hosts the type is hidden and the user falls back to Title or Caption.
- Animatable through FCP's own Subtitle: Steno parses the built-in template's published parameters and exposes a curated set in the customize panel - **Animation Style**, **Animate By**, Font / Size / Text Color, Highlight, Background Color / Opacity / Corner Radius, Width / Height, X / Y Offset, Vertical Alignment, and Social Safe. Params are re-parsed each launch, so they track FCP updates.
- Font, Size, and Text Color ride in the subtitle's `<text-style>` (where FCP keeps them), not as param overrides. The rest export as param overrides.
- Content style options still apply (max words per line, ALL CAPS, no gaps, censor, strip punctuation).

**Caption** (uses FCP's built-in caption format).

- Exports as FCP Caption clips in one of three formats - chosen via a second toggle that appears when Caption is selected:
  - **iTT** (iTunes Timed Text) - FCP's native caption inspector format.
  - **SRT** (SubRip) - `.srt`-style cues delivered as FCP captions.
  - **CEA-608** - broadcast closed-caption format with pop-on style. Lines longer than 32 characters auto-split. Required for some broadcast deliverables.
- **Does not support caption templates** - captions render via FCP's built-in caption styling, not Keyframeless templates.
- Per-word animation is not available.
- Style options that affect text content still apply (caps, no gaps, censor, strip punctuation, max words per line) but font/size/color/position controls are hidden because FCP owns the rendering.

Title and Subtitles both use FCP's `subtitles` role (a plain role string that FCP 12.3+ resolves to the built-in Subtitles role and older FCP creates as a custom role), so they overlap freely on video lanes. Caption formats occupy FCP's single caption track and cannot overlap in time. See `drag-paste-fcp` for the four ways to get captions back into FCP (Drag, Paste, FCPXML Import, SRT Export) and which are available for each type.
