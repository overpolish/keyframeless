---
id: edit-tab
summary: The Edit tab - review transcriptions, edit text, set caption breaks, export
---

The Edit tab shows transcriptions grouped by clip and lets the user prepare captions for export. Available once at least one clip has been transcribed (otherwise the Edit toggle is greyed out).

**Layout.** A timeline at the top mirrors the FCP playhead context. Below, each transcribed clip becomes a group: a header row with the clip name (and compound badge if applicable) followed by per-sentence rows. Untranscribed clips appear in a collapsed section at the bottom with per-clip "Transcribe" buttons.

**Editing a sentence.** Click into a sentence row to edit the text. Word-level timing is preserved: words that survive the edit keep their original timestamps, and new or changed words inherit timing interpolated from neighbouring unchanged words. A reset arrow appears next to any edited sentence to revert to the original transcription.

**Manual caption breaks.** Right-click between two words in a sentence to toggle a manual caption break (a blue vertical line). Caption breaks force the caption to wrap at that point during export, overriding the "Max Words Per Line" auto-wrapping. See `caption-breaks`.

**Per-sentence playback.** Each sentence row has a play/pause button that plays back the FCP-filtered audio for just that sentence's time range.

**Reprocess Selected.** Appears when clips are selected. Clicking it returns the user to the Setup tab with that selection, where they can pick a different model/language and re-transcribe.

**Import SRT.** Per-clip or project-wide SRT imports replace the transcription data with the SRT cues. See `srt-import`.

**Export.** The right sidebar holds all export settings: caption type (Title vs Caption format), style options (max words, lines, ALL CAPS, etc.), and the four export actions (Drag to FCP, Paste to FCP, FCPXML Import, SRT Export). See `caption-types` and `drag-paste-fcp`.
