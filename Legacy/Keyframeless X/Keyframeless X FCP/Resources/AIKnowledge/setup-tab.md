---
id: setup-tab
summary: The Setup tab - drop FCP timeline, pick model and language, run transcription
---

Setup is the first of two tabs in the workflow extension. It's where the user loads audio from FCP and runs transcription.

**Loading audio.** The user drags the FCP timeline (or a selection) onto the drop zone in Setup. Keyframeless parses the FCPXML, extracts audio clips with their effect stacks, and shows them as waveforms in a timeline view. Project format (resolution, frame rate, fps display preference) is captured from the drop and used for timecode display later.

**Toolbar filters.** The clip selection toolbar lets the user filter clips by kind: All, Audio (regular), or Compound. This is just a filter - both kinds transcribe identically.

**Model + language pickers.** The user picks one of the available Whisper or Parakeet models (see `transcription-models`) and a language (see `languages`). Settings persist between sessions.

**Terms.** An optional list of keywords that bias the transcriber towards specific spellings - useful for proper nouns, brand names, or technical jargon. See `terms`.

**Process.** Runs transcription on every selected clip with the current model and language. Disabled while a model is downloading, while waveforms are loading, while another process is running, or when no clips are selected.

**Process Selected.** Runs only on a subset, allowing different settings per batch. Useful for mixing models - e.g. heavy model on dialogue, light model on ambient.

**Import SRT.** Skips transcription entirely - imports an .srt file as the source of truth instead. See `srt-import`.

**Processing overlay.** A modal overlay appears with progress, ETA, and a cancel button while transcription runs. On completion, the extension switches to the Edit tab automatically.
