---
id: srt-export
summary: SRT export options - both as a Caption format and as a standalone .srt file
---

There are two ways to export to SRT in Steno:

**1. Standalone .srt file ("SRT Export" button).** In the Edit tab's export sidebar, the "SRT Export" button writes a `.srt` file to disk via a save dialog. Works regardless of caption type and is **not blocked by overlapping clips** (SRT allows overlapping cues).

**2. SRT-format captions to FCP.** When the caption type is set to Caption, the Caption Format toggle includes SRT alongside iTT and CEA-608. This routes SRT cues into FCP's native caption system (rather than writing a .srt file). See `caption-types`.

Both routes use the same underlying caption data - text, timing, and any manual breaks. The standalone .srt file is the right choice if you need to deliver an SRT file (e.g. to a client, YouTube, social media). The Caption / SRT format is the right choice if you want the captions to live inside FCP's caption inspector with the SRT role.
