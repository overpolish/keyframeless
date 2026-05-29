---
id: style-options
summary: Caption styling controls - max words per line, lines, ALL CAPS, no gaps, censor, strip punctuation
---

The Edit tab's export sidebar has a set of style controls that apply to all caption types. Some apply to text rendering (Title mode); others rewrite the caption text content (any mode).

**Text rendering (Title mode only).**

- **Font picker** with RGBA colour sliders.
- **Text Width** - 10 to 100% (horizontal padding from frame edges).
- **Text Size** - 10 to 200 pt.
- **Y Position** - 0 to 100% (vertical placement in the frame).
- A "Dimensions Preview" shows where the caption will land at the project's export resolution.

These hide in Caption mode because FCP renders the captions, not Keyframeless.

**Text content (all modes).**

- **Max Words Per Line** - slider 1 to 10, controls auto-wrapping. Overridden by manual `caption-breaks`.
- **Lines** - One or Two. Controls how many lines of caption are visible at once.
- **ALL CAPS** - uppercases the caption text.
- **No Gaps** - removes blank gaps between caption segments so captions stay on screen continuously.
- **Censor** - replaces profane words with `****`, using the language's profanity list. Toggle is only meaningful for languages with a profanity list (see `languages`).
- **Strip Punctuation** - removes `.!?,;:` etc.
- **Keep ? and !** - only active when Strip Punctuation is on; preserves question marks and exclamation marks even when other punctuation is stripped.

**Defaults.** "Make Default" saves the current settings as the user's defaults; "Reset" restores values to whatever the defaults are. Defaults persist across sessions and projects.

For text transformations beyond what these toggles cover (translation, tone changes, filler-word removal, etc.), use the AI Transform feature - see `ai-transform`.
