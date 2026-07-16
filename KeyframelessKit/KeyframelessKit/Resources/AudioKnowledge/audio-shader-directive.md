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

That adds a **Music** control to the Shader group in the inspector, whose picker lists the analyses Sonar has published, named `<source> - <project>`. Pick one and the shader is fed that audio at every frame, matched to the timeline - so it lines up on playback AND bakes correctly on export.

The directive never names a source. It declares a slot, and the picker binds it. That means a shader shared with someone else opens fine on their machine - they just pick their own audio. It also means a shader with nothing bound (the picker's "None") renders silence rather than failing.

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
- **`smooth=<seconds>`** - how much the spectrum is averaged over time. Default `0.08`. Raw bands are violently transient (speech and drums are spikes), so a shader mapping them straight to geometry judders. The window calms it. `smooth=0` gives the raw data, higher values give slower, heavier movement.

Smoothing has to happen here rather than in the shader: a fragment shader has no memory of previous frames, and Final Cut Pro renders frames out of order (scrubbing, motion blur, pre-render), so a shader-side running filter would make a frame look different depending on how you reached it.

## Making it look good

The raw levels sit near the floor most of the time, so a linear mapping barely moves. Shaping is the shader's job, and it's where most of the character comes from:

- **`pow(level, 0.6)`** lifts the quiet detail without clipping peaks.
- **Split the spectrum by purpose** - average the first few bands for a bass pulse, use the higher ones for detail. Kicks then land as a pulse rather than a wobble.
- **Interpolate between bands** (`mix(uMusicBand(b0), uMusicBand(b1), fract(f))`) when mapping bands onto a smooth shape, or the coarse band count shows as facets.
- **Compose with the other directives.** `#color`, `#float`, `#point` and friends still work, so audio can drive some of the look while keyframed lanes drive the rest.

## Limits worth knowing

- The bound source must come from the project the shader lives in. Sources from other projects have a different timeline, so their audio won't line up - which is why the picker names the project.
- Nothing bound, a deleted source, or a moment outside the published range all read as silence (all bands zero), never as an error.
- The inspector's mini-viewer previews the audio at the playhead, so it matches the viewer.
- Two `#audio` uniforms per shader.
