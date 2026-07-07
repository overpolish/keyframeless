---
id: srt-import
summary: SRT import - per-clip or project-wide; replaces transcription data with SRT cues
---

Steno imports SRT (.srt) subtitle files in two modes:

**Per-clip SRT.** From a clip's row in the Edit tab, "Import SRT" replaces that clip's transcription with the imported SRT cues. Existing word-level edits for the clip are cleared. The cue timing is preserved exactly (cues are not re-aligned against the audio).

**Project-wide SRT.** "Import SRT" at the top of the Edit tab imports a single SRT file that spans the entire timeline. The cues are shown as a synthetic "Timeline-Wide" entry rather than attached to any one clip. Useful when the SRT was authored externally for the whole edit.

**Delete SRT.** Once imported, the clip (or project-wide entry) gets a "Delete SRT" button to remove the imported cues and restore the original transcription (if any).

**Overlap detection.** Imported SRT cues are checked for time overlaps with other clips' transcriptions. If overlaps exist, certain export actions are restricted - see `drag-paste-fcp`.

**Editing imported SRT.** SRT cues behave just like transcription sentences: text is editable, manual breaks can be set, AI transforms work on them. But they have one timestamp per cue (start + end) rather than per-word.
