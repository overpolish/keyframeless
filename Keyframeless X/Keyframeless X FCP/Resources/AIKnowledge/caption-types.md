---
id: caption-types
summary: Two caption types - Title (with templates) and Caption (FCP's built-in iTT/SRT/CEA-608)
---

In the Edit tab's export sidebar, the user picks one of two caption types:

**Title** (default).

- Exports as FCP Title clips - fully animatable.
- **Supports caption templates** from the Keyframeless plugin family (Rounded, Canvas, MagicMove, Glow, Template, plus any community templates). See `caption-templates`.
- Supports per-word animation on templates that opt into it.
- Style options apply: text font/size/color/Y-position, max words per line, one or two lines, ALL CAPS, no gaps, censor profanity, strip punctuation (with optional "Keep ? and !" override).

**Caption** (uses FCP's built-in caption format).

- Exports as FCP Caption clips in one of three formats - chosen via a second toggle that appears when Caption is selected:
  - **iTT** (iTunes Timed Text) - FCP's native caption inspector format.
  - **SRT** (SubRip) - `.srt`-style cues delivered as FCP captions.
  - **CEA-608** - broadcast closed-caption format with pop-on style. Lines longer than 32 characters auto-split. Required for some broadcast deliverables.
- **Does not support caption templates** - captions render via FCP's built-in caption styling, not Keyframeless templates.
- Per-word animation is not available.
- Style options that affect text content still apply (caps, no gaps, censor, strip punctuation, max words per line) but font/size/color/position controls are hidden because FCP owns the rendering.

See `drag-paste-fcp` for the four ways to get captions back into FCP (Drag, Paste, FCPXML Import, SRT Export) and which are available for each type.
