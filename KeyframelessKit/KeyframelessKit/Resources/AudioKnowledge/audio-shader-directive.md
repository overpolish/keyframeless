---
id: audio-shader-directive
summary: The #audio directive - bind a Sonar-published spectrum to a shader and drive the render from it
---

# Making a shader react to audio

A shader reads audio through the `#audio` directive, which binds a spectrum published by Sonar (see `audio-sonar`) to a uniform. Declare it exactly like the other directives - a comment, then the uniform it describes:

```glsl
// #audio label="Music"
uniform vec4 uMusic[16];
```

That adds an **Audio** group to the inspector holding four controls:

- **Music** - the picker, listing the analyses Sonar has published, named `<source> - <project>`. Pick one and the shader is fed that audio at every frame, matched to the timeline - so it lines up on playback AND bakes correctly on export.
- **Noise Gate** (dB) - bands quieter than this fall silent. Off at the bottom of its range. Nothing is ever truly quiet (room tone, hiss, a preamp), so an ungated visual never fully settles between beats - that floor is what shows as a permanent tremble in a shader mapping the low end to a radius.
- **Release** (seconds) - how long a band takes to reach zero once it drops under the gate. Attack is always instant, so signal returning snaps straight back. At 0 the gate is a switch and a bar goes from full height to nothing in one frame, which reads as a glitch rather than as a sound stopping - a little release is what makes it read as decay.
- **Smoothness** (seconds) - how much the spectrum is averaged over time. Raw bands are violently transient (speech and drums are spikes), so a shader mapping them straight to geometry judders. 0 is raw, higher is slower and heavier.

Noise Gate, Release and Smoothness are ordinary animatable lanes, so they keyframe like anything else: gate shut through a quiet section and open for the drop, or ease smoothness up as a track thickens. (The picker isn't animatable - a shader swapping its audio source mid-clip would be a different shader.)

Note what each one fixes, because they're easy to confuse. **Smoothness** is how twitchy the movement is: it averages the level. **Release** is how long a bar takes to die once the gate closes. They act on different things, so turning smoothness up will never soften the gate's cut - if bars vanish abruptly, that's Release.

The directive never names a source. It declares a slot, and the picker binds it. That means a shader shared with someone else opens fine on their machine - they just pick their own audio. It also means a shader with nothing bound (the picker's "None") renders silence rather than failing.

A _project_ is different from a shader. Its bindings are real and are meant to survive, so a project opened on a Mac where its audio was never published doesn't quietly forget them - the picker keeps showing what it wants, greyed out, with a **Republish required** warning beside it. Drop the project on Sonar, where the clips will already be selected, and publish: the binding comes back on its own. See the Sonar doc for the walkthrough.

This is worth telling apart from "None". Both render silence, but "None" is a choice and Republish required is a missing ingredient.

## Reading the spectrum

The uniform is a `vec4` array because four bands pack into each `vec4`, but a shader never indexes that packing by hand. Two things are generated for it:

- **`uMusicBand(i)`** - band `i`, from `0` (low) to `uMusicBands - 1` (high), as a float roughly `0...1`.
- **`uMusicBands`** - how many bands there are. `vec4 uMusic[16]` gives 64.

Both are named after the uniform: a `uKick` uniform gets `uKickBand(i)` and `uKickBands`.

Declare more `vec4`s for finer frequency detail, fewer for less. 16 (64 bands) suits most visuals, and 8 (32 bands) is plenty for chunky bars.

```glsl
// #audio label="Music"
uniform vec4 uMusic[16];

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    int band = int(min(uv.x * float(uMusicBands), float(uMusicBands) - 1.0));
    float level = uMusicBand(band);
    float bar = smoothstep(level, level - 0.01, uv.y);
    fragColor = vec4(vec3(bar), bar);
}
```

## Attributes

- **`label="..."`** - the control's name in the inspector.
- **`smooth=<seconds>`** - the Smoothness lane's starting value. Default `0.08`.
- **`gate=<dB>`** - the Noise Gate lane's starting value. Default: off.
- **`release=<seconds>`** - the Release lane's starting value. Default `0.15`.

The last three only **seed** their lanes. Once a shader is on a clip the user owns those values, and can keyframe them - so don't reach for a directive attribute to dial a look in, set a sensible start and let them take it from there.

Smoothing and release have to happen here rather than in the shader: a fragment shader has no memory of previous frames, and Final Cut Pro renders frames out of order (scrubbing, motion blur, pre-render), so anything that decayed a remembered value would make a frame look different depending on how you reached it - and would not survive an export. Release is worked out by looking _backward_ for when a band last cleared the gate, which answers identically however the frame is reached.

## Making it look good

The raw levels sit near the floor most of the time, so a linear mapping barely moves. Shaping is the shader's job, and it's where most of the character comes from:

- **`pow(level, 0.6)`** lifts the quiet detail without clipping peaks.
- **Split the spectrum by purpose** - average the first few bands for a bass pulse, use the higher ones for detail. Kicks then land as a pulse rather than a wobble.
- **Interpolate between bands** (`mix(uMusicBand(b0), uMusicBand(b1), fract(f))`) when mapping bands onto a smooth shape, or the coarse band count shows as facets.
- **Compose with the other directives.** `#color`, `#float`, `#point` and friends still work, so audio can drive some of the look while keyframed lanes drive the rest.
- **Don't shape away a settling problem.** If the visual never rests between beats, that's the noise floor, and Gate + Release fix it properly. No amount of curve-tweaking in the shader will, because the level genuinely isn't reaching zero.

## Limits worth knowing

- The bound source must come from the project the shader lives in. Sources from other projects have a different timeline, so their audio won't line up - which is why the picker names the project.
- Nothing bound, a deleted source, or a moment outside the published range all read as silence (all bands zero), never as an error.
- The inspector's mini-viewer previews the audio at the playhead, so it matches the viewer.
- Two `#audio` uniforms per shader.
