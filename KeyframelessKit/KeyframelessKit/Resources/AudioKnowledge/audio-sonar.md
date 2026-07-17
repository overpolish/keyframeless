---
id: audio-sonar
summary: Sonar - make effects in Final Cut Pro react to your music or dialogue
---

# Sonar: make your effects react to the audio

Sonar is a free tab in Keyframeless X. It lets effects in Final Cut Pro move to your audio: a visual that pulses on every kick, bars that dance to the music, a glow that rises and falls with someone's voice.

You pick which audio it listens to, hit Publish, and it becomes available to your effects. In Shader, it shows up as a menu on the effect in the inspector - choose your music and the shader starts moving to it.

**It survives export.** Audio-reactive effects usually look right while you play the timeline and then come out wrong (or frozen) in the exported file, because Final Cut Pro renders the video separately from the sound. Sonar listens to the audio up front instead of during the render, so what you see in the viewer is what you get in the export.

Sonar hears what you hear: your volume changes, fades, and audio effects like compressors and EQ are all included, not the raw untouched file.

## Using it

1. **Drag the project onto Sonar.** The same drag as Steno: the project (or a selection) from the Final Cut Pro timeline. Both tabs share whatever was dropped, so a project loaded in one appears in the other.
2. **Pick the clips to analyse.** Every audio clip in the project appears on the timeline, coloured by role (dialogue blue, music green, effects teal, and so on) with the role named in the corner of each clip box. The toolbar filters by role, by Main / Compound, and offers Select All / Deselect All. Click or drag across clips to select.
3. **Watch the spectrogram.** It builds itself as soon as anything is selected and follows the selection - there's no Analyse button. It draws in a lane under the clips, sharing the timeline's zoom and scroll, so a peak in the picture lines up with the clip that made it.
4. **Publish.** This makes it available to your effects, and it's the only button you have to press.

## What you select is what the effect hears

Whatever you select is the audio your effect reacts to. Select only the music clips and the effect moves to the music and ignores the dialogue. That's usually what you want: one visual driven by the music, another by a voice.

You can be picky about it. Leave a clip out and the effect stays still over that stretch, because as far as it's concerned nothing is playing there. Select just the drums and it only moves to the drums.

## Published sources

Each Publish creates a **source**, listed under the button with its clip count, project and age.

- **It names itself from the roles you picked** - choose the music clips and it's called "Music", two roles gives "Music + Effects". Rename it in the list if you'd rather call it something else.
- **Publishing different clips makes a different source.** Publish three music cues, then three others, and you get both ("Music" and "Music 2"), so one shader can use one and a second shader the other. Publishing the _same_ clips again just updates that source instead of cluttering the list.
- **Changed the audio? Publish again.** A volume change, a fade, a new effect - re-publish and the source updates to match.
- Sources stick around across projects and restarts, on the Mac that published them. Delete removes one for good.

## What gets included

Sonar uses the audio as Final Cut Pro plays it, not as the raw file sounds. Your trims, volume curves, fades and audio effects (compressors, EQ, and the rest) are all in there, so your effect reacts to what your audience actually hears.

If a clip's media is offline it gets left out and Sonar tells you which. Video clips with no audio are ignored.

## "Republish required"

If an effect shows a **Republish required** warning next to its audio menu, it's asking for audio that isn't published on this Mac. The effect still knows exactly what it wants - the menu shows the name, greyed out, like "Music - My Documentary" - it just can't find it here.

Almost always this means the project came from somewhere else: a different Mac, a colleague, a machine you edit on at the weekend. Published audio doesn't travel inside the project, so it doesn't arrive with it.

Fixing it takes one action:

1. **Drag the project onto Sonar.**
2. **The clips are already selected for you.** You don't have to remember what you picked last time - the effect remembers, and Sonar reads it.
3. **Hit Publish.**

Every effect in the project waiting on that audio starts moving again by itself. There's nothing to re-point in the inspector, and it doesn't matter that you're on a different Mac, that the media sits in a different folder, or that it's months later. Publish the same clips and you get the same source.

If the clips _aren't_ already selected when you drop the project, the effect is asking for audio this project no longer has - clips deleted since, or a different project entirely. Pick the audio you want and publish; the effect will need pointing at it by hand.

The warning only means "this isn't here". It isn't a broken effect or a broken project, and the effect renders normally in every other respect - it just sits still, because as far as it can tell nothing is playing.

## Worth knowing

- **Use a source in the project it came from.** Audio published from one project won't line up with a different project's timeline, which is why the menu shows the project next to each source name.
- **Sharing a project? Publish on each Mac.** Sources live on the machine that made them. Whoever opens it elsewhere republishes once, and everything reconnects - see "Republish required" above.
- **Publishing is a snapshot.** Change the audio in Final Cut Pro and your effect keeps moving to the old version until you publish again.
- Nothing published yet, or you haven't picked a source, means the effect simply sits still. It won't error.
