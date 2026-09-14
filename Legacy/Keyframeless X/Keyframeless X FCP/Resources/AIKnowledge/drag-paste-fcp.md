---
id: drag-paste-fcp
summary: Four ways to send captions back to FCP - Drag, Paste, FCPXML, SRT - and when each is available
---

The Edit tab's export sidebar offers four export actions. Availability depends on caption type and whether overlapping clips were detected.

**Drag to FCP** (Title mode only).

- Click and drag the labelled drop zone onto the FCP timeline.
- Preserves Title styling and templates.
- Disabled when: caption type is Caption (hidden entirely), no clips selected, or any selected cues overlap in time.

**Paste to FCP** (works for Title and Caption).

- Sends the data via Cmd+V keyboard automation while FCP is frontmost.
- **Requires macOS Accessibility permission** to be granted to Final Cut Pro. If permission isn't granted, the button is disabled - the user can grant it in System Settings > Privacy & Security > Accessibility.
- Disabled when no clips selected, or when caption type is Caption AND there are overlapping cues.
- In Caption mode the user also needs to enable the caption role in FCP's Timeline Index after pasting (Keyframeless shows a hint about this).

**FCPXML Import** (Title mode only).

- Writes an `.fcpxml` file the user manually imports via FCP's File menu.
- Disabled in Caption mode when there are overlapping cues.
- Useful when Accessibility permission isn't available, or for archival.

**SRT Export** (any mode).

- Writes a `.srt` file to disk.
- **Not blocked by overlapping cues** - SRT allows overlapping timing.

**Why caption-format exports are blocked by overlaps.** FCP's native captions (iTT, CEA-608, and SRT-as-caption) cannot occupy the same time range - FCP's caption track only allows one caption at a time. Title clips can overlap freely (they're on separate video lanes), and standalone .srt files have no FCP restriction.

**Why drag is Title-only.** FCP only accepts dragged title clips through its title pasteboard; there's no equivalent path for caption clips. Caption mode falls back to Paste, FCPXML Import, or SRT Export.
