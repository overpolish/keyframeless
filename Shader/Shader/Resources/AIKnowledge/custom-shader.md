---
id: custom-shader
summary: Writing and editing custom Shadertoy-style shaders in Shader
---

# The Custom shader

Shader is a blank shader canvas: paste a Shadertoy "Image" shader (or write your own GLSL) into the **Shader** editor and it runs live on the clip. Under the hood the GLSL is compiled to Metal at runtime with the real glslang + SPIRV-Cross toolchain, so the **full GLSL language works** - not a hand-rolled subset. If a single-pass Image shader compiles on Shadertoy, it almost always runs here unchanged.

- Entry point is Shadertoy's `void mainImage(out vec4 fragColor, in vec2 fragCoord)`.
- The **Shader** lane sits at the bottom of the Core section. It opens a syntax-highlighted code editor.

## Built-in inputs (no declaration needed)

Use them exactly as on Shadertoy:

| Name                     | Type        | Meaning                                                                                                                                                                                                                       |
| ------------------------ | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `iResolution`            | `vec3`      | output size in px (`.xy`), `.z` = 1                                                                                                                                                                                           |
| `iTime`                  | `float`     | seconds, scaled by the shared **Speed** and offset by **Seed**                                                                                                                                                                |
| `iProgress`              | `float`     | clip fraction, `0` at the first frame to `1` at the last, linear. Deliberately NOT scaled by Speed/Seed. In a transition template this is the GL Transitions `progress`; see the `// #progress` directive to expose the curve |
| `iTimeDelta`             | `float`     | seconds/frame (approx)                                                                                                                                                                                                        |
| `iFrame`                 | `int`       | frame index (approx)                                                                                                                                                                                                          |
| `iMouse`                 | `vec4`      | present but currently always 0 (no mouse input wired yet)                                                                                                                                                                     |
| `iDate`                  | `vec4`      | present but currently always 0                                                                                                                                                                                                |
| `iChannel0`              | `sampler2D` | **the source clip** Shader is applied to (the footage / adjustment-layer composite below)                                                                                                                                     |
| `iChannel1`              | `sampler2D` | **the "To" image well** when the user fills it - a SECOND clip, which is what makes transitions and picture-in-picture possible (see below). Falls back to the noise texture when the well is empty                           |
| `iChannel2`, `iChannel3` | `sampler2D` | bound to a repeating value-noise texture                                                                                                                                                                                      |

## What works, what doesn't

**Works out of the box:** the whole GLSL language - `mod`, `atan`, `inversesqrt`, matrix constructors, `out`/`inout` params, passing a vector component like `p.x` by reference, swizzle compound-assignment (`p.xy *= rot`), `#define`/`#if` macros, loops, etc. Two Shadertoy-compat behaviours are matched deliberately:

- **Uninitialised locals read as zero** (like Chrome/ANGLE, which Shadertoy runs on). Golfed shaders that rely on `float i;` starting at 0 (e.g. `for (O *= i; i < n; i++)`) work.
- **Output is forced opaque by default.** Shadertoy ignores `fragColor.a`; so does this, because golfed pastes leave garbage there. A shader that wants its alpha honoured (to punch a hole in the clip so a lower lane shows through) opts in with the `// #alpha` directive - see `directives`.

**Pasting non-Shadertoy shaders:** shaders written for raw WebGL, three.js, glslCanvas, or Book of Shaders use a different convention (`void main()` + `gl_FragColor`, host-named uniforms like `uTexture` / `vUv` / `u_time`). A compatibility shim rewrites the common cases automatically: it converts the entry point + output, and maps the well-known names (`uTexture` / `tDiffuse` / `u_texture` -> `iChannel0`, `vUv` / `vTexCoord` -> the pixel coordinate, `u_time` / `iGlobalTime` -> `iTime`, `u_resolution` -> `iResolution.xy`, `u_mouse` -> `iMouse.xy`, `texture2D` -> `texture`). Any declared `sampler2D` uniform is routed to `iChannel0..3` in declaration order whatever its name, so a single-texture shader binds its texture to the source clip automatically (the name doesn't have to be recognised). What still needs a hand edit is an unusual NON-texture uniform - a resolution / time / mouse value under a name the list doesn't know (say `screenSize`) - which surfaces as an "undeclared identifier" pointing at the fix. Shaders already written to the `mainImage` convention pass through untouched. Shadertoy remains the best-supported source because its shaders need no translation at all.

**Source footage on `iChannel0`:** Shader is a Final Cut effect, so the clip it's applied to is bound to `iChannel0`. A pasted shader that samples `iChannel0` (e.g. `texture(iChannel0, uv)`) processes your footage - blur, displace, tint, feed it into a reaction-diffusion, etc. Apply Shader to an **adjustment layer** to run the shader over everything beneath it. `iChannel1` carries a second clip when the **"To" image well** is filled (see below); `iChannel2`/`iChannel3` read procedural noise.

**Audio works, but not the Shadertoy way.** Shadertoy binds audio to an `iChannel` as a texture (row 0 the spectrum, row 1 the waveform), and that isn't supported - a pasted Shadertoy music visualiser reads noise from its channel and needs an edit. Shader instead has the `#audio` directive, which binds the audio a user published from Sonar and reads it as `uMusicBand(i)`. The port is usually small: swap the `texture(iChannel0, vec2(x, 0.0)).r` spectrum lookup for `uMusicBand(int(x * float(uMusicBands)))`. Unlike Shadertoy's, it stays in sync on export. See `directives` and `audio-shader-directive`.

**Not supported yet:** a THIRD image input (`iChannel0` is the clip and `iChannel1` the "To" well, but `iChannel2`/`iChannel3` can't be wired to your own media - they read noise or a buffer), cubemaps, an audio waveform (`#audio` gives the spectrum, not raw samples), and keyboard input.

## Two clips: transitions and picture-in-picture

A shader can read a **second clip** on `iChannel1`, which is what makes real transitions possible - not just an effect that distorts one clip, but a genuine A-to-B blend.

Fill the **"To"** image well in the inspector and it lands on `iChannel1`. Combined with `iProgress` (0 at the effect's first frame, 1 at its last) that's everything a cross-dissolve needs:

```glsl
void mainImage(out vec4 O, in vec2 fc) {
  vec2 uv = fc / iResolution.xy;
  O = mix(texture(iChannel0, uv), texture(iChannel1, uv), iProgress);
}
```

**As a Final Cut transition** (dropped on a cut, both clips fed automatically): that needs a Motion transition template with the Shader on the **Transition A layer** and **Drop Zone Transition B** dragged into its "To" well. Put the Shader on the template's _Group_ instead and Motion flattens A and B into one image before the shader sees them - it silently degrades to a single texture with no error. The well is left unpublished, so the editor never sees it: they drop the transition on a cut and it just works.

**As a picture-in-picture**, two routes:

- **Two clips, one shader:** apply Shader to the main clip, drop the inset clip into the "To" well, and composite `iChannel1` into a corner. Here the manual pick is right - there's no implicit second clip, the user genuinely chooses it.
- **Stacked clips, same shader on each:** give the shader a `#choice` for its region and `// #alpha`, so each instance draws its own clip into its own area and stays transparent elsewhere; Final Cut's lane compositing stacks them. This is the one that generalises to quarters and grids, because it isn't limited to two sources.

## gl-transitions.com shaders

Shaders from the **GL Transitions** catalogue paste in and run unmodified. They use a neighbouring dialect, detected automatically by the `vec4 transition(vec2 uv)` signature and adapted:

| GL Transitions              | becomes                                              |
| --------------------------- | ---------------------------------------------------- |
| `vec4 transition(vec2 uv)`  | the entry point (no `mainImage` needed)              |
| `getFromColor(uv)`          | the clip Shader is applied to (`iChannel0`)          |
| `getToColor(uv)`            | the **"To"** well (`iChannel1`)                      |
| `progress`                  | `iProgress`                                          |
| `ratio`                     | the frame's aspect (`iResolution.x / iResolution.y`) |
| `uniform float x; // = 1.0` | a constant with that default                         |

So a catalogue shader needs no edits at all - paste it, set up the transition template, and it runs exactly as it does on the web, `progress` sweeping linearly.

Two caveats. Its custom uniforms currently become **constants** at their authored defaults, so they aren't inspector controls yet - to expose one, rewrite it as a `// #float` directive (see `directives`). And `progress` is only special inside a GL transition; in an ordinary shader `progress` is an ordinary name you can use freely, and the built-in is `iProgress`.

Where the catalogue beats its own spec: `progress` is linear-only on the web, but here `// #progress` turns it into a lane on the timing engine, so a transition can be eased, held, or reshaped like any other property.

## Multi-pass (tabs: Common + Buffer A-D)

The editor has a tab strip. It starts on the single **Image** tab; the **+** menu adds **Common** and **Buffer A** through **Buffer D**, and **✕** removes a tab. This mirrors Shadertoy's multi-pass model:

- **Common** is prepended to every pass - put shared helpers / `#define`s / constants here. It renders nothing itself.
- **Buffer A-D** are offscreen passes (16-bit float) that run before Image, in order. Each stores DATA a later pass reads, not display pixels (no grain / sRGB / opaque forcing is applied to a buffer's output).
- **Channel routing is positional:** `iChannel0` -> Buffer A, `iChannel1` -> Buffer B, `iChannel2` -> Buffer C, `iChannel3` -> Buffer D, for any buffer that exists. A channel with no matching buffer falls back to the source clip (ch0) or noise. So a paste-in that expects "iChannel0 = Buffer A" works, but one wiring a channel to external footage does not (there's no per-pass routing UI yet).
- **Feedback works.** A buffer may read its own (or a later buffer's) _previous_ frame - the engine keeps persistent ping-pong state per pass. That's what makes motion trails, fluid, and reaction-diffusion (Gray-Scott etc.) possible. Scrubbing is deterministic: the engine re-simulates from checkpoints so a given timeline frame always looks the same. Feedback sims run at a capped resolution (~360-tall) on purpose - reaction-diffusion / fluid patterns are a few cells wide and barely develop on a fine grid; the mini-viewer matches.

## Shared controls that affect a Custom shader

- **Speed** multiplies `iTime` (0 freezes it, 2 runs it twice as fast).
- **Seed** offsets where `iTime` starts, for per-clip variety. A looping shader built around `mod(iTime, N)` can show a visible "jump" once per loop; nudging Seed or lowering Speed slides that seam out of the clip.
- **Grain** / **Grain Size** overlay a core film grain applied on top of the shader's output.
- Any positioning, scale, rotation, colour, etc. a shader wants is exposed by **declaring its own controls** with `// #` directives (see the directives doc), not by fixed shared controls. A shader otherwise positions itself in code.

## The editor

The Shader editor is a small dark (GitHub-Dark) code pane: live GLSL syntax highlighting, a line-number gutter, and live error reporting. A shader that fails to compile shows a red bar reading `Line N: <message>` and flags line N in both the code and the gutter; fix it and the flag clears. When asking for an edit, refer to lines by the gutter numbers.

## Tips

- Animate by driving values off `iTime`.
- Start single-pass (one `mainImage` in the Image tab); reach for Buffer tabs only when a shader needs an offscreen pass or frame-to-frame feedback.
- Sampling an unused `iChannel1-3` gives smooth value noise - good for grain, fbm, hashing. Two exceptions: a Buffer routed to that channel, and `iChannel1` when the "To" image well is filled (then it's a second clip, not noise).
- If a pasted shader renders differently near the end of a clip, it's usually the shader's own `mod(iTime, N)` loop seam positioned by Seed, not a bug.
