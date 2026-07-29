---
id: custom-shader
summary: Writing and editing custom Shadertoy-style shaders in Mirage
---

# The Custom shader

Mirage is a blank shader canvas: paste a Shadertoy "Image" shader (or write your own GLSL) into the **Mirage** editor and it runs live on the clip. The **full GLSL language works** - so if a single-pass Image shader runs on Shadertoy, it almost always runs here unchanged. Paste it and go.

- The editor is the **Mirage** lane in its own **Shader** group: a syntax-highlighted code pane with live error reporting, with the shader's name field above it.
- Your entry point is Shadertoy's `void mainImage(out vec4 fragColor, in vec2 fragCoord)`, and the built-in inputs (`iTime`, `iChannel0`, `iResolution`, ...) all work.
- Every Image shader declares its browser/runtime type with exactly one `// #template generator`, `filter`, `layout`, or `transition` line.
- Add your own sliders, colours, and on-screen handles by annotating uniforms with `// #` directives (see the directives help).

## Built-in inputs (no declaration needed)

Use them exactly as on Shadertoy:

| Name                     | Type        | Meaning                                                                                                                                                                                                                       |
| ------------------------ | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `iResolution`            | `vec3`      | output size in px (`.xy`), `.z` = 1                                                                                                                                                                                           |
| `iTime`                  | `float`     | seconds, scaled by **Speed** and offset by **Seed** when the shader declares `// #speed` / `// #seed` (otherwise plain clip time)                                                                                             |
| `iProgress`              | `float`     | clip fraction, `0` at the first frame to `1` at the last, linear. Deliberately NOT scaled by Speed/Seed. In a transition template this is the GL Transitions `progress`; see the `// #progress` directive to expose the curve |
| `iTransitionMode`        | `int`       | transition coverage: `0` = Transition, `1` = In (transparent From), `2` = Out (transparent To). Available to transition shaders for mode-specific backdrops or embellishments                                                 |
| `iTimeDelta`             | `float`     | seconds/frame (approx)                                                                                                                                                                                                        |
| `iFrame`                 | `int`       | frame index (approx)                                                                                                                                                                                                          |
| `iMouse`                 | `vec4`      | present but currently always 0 (no mouse input wired yet)                                                                                                                                                                     |
| `iDate`                  | `vec4`      | present but currently always 0                                                                                                                                                                                                |
| `iChannel0`              | `sampler2D` | **the source clip** Mirage is applied to (the footage / adjustment-layer composite below)                                                                                                                                     |
| `iChannel1`              | `sampler2D` | **the "To" image well** when the user fills it - a SECOND clip, which is what makes transitions and picture-in-picture possible (see below). Falls back to the noise texture when the well is empty                           |
| `iChannel2`, `iChannel3` | `sampler2D` | bound to a repeating value-noise texture                                                                                                                                                                                      |
| `iMotionBlur`            | `float`     | shutter `0..1` from the user's Motion Blur popover (`0` when off). Non-zero **only** in a `// #motionblur native` shader; otherwise the plugin owns the blur and this stays `0`. See the `// #motionblur` directive           |
| `iMotionBlurSamples`     | `int`       | Motion Blur sample count, for a `native` shader that loops internally                                                                                                                                                         |

## What works, what doesn't

Under the hood the GLSL is compiled to Metal at runtime with the real glslang + SPIRV-Cross toolchain, not a hand-rolled subset - which is why the whole language is available.

**Works out of the box:** the whole GLSL language - `mod`, `atan`, `inversesqrt`, matrix constructors, `out`/`inout` params, passing a vector component like `p.x` by reference, swizzle compound-assignment (`p.xy *= rot`), `#define`/`#if` macros, loops, etc. Two Shadertoy-compat behaviours are matched deliberately:

- **Uninitialised locals read as zero** (like Chrome/ANGLE, which Shadertoy runs on). Golfed shaders that rely on `float i;` starting at 0 (e.g. `for (O *= i; i < n; i++)`) work.
- **Output is forced opaque by default.** Shadertoy ignores `fragColor.a`; so does this, because golfed pastes leave garbage there. A shader that wants its alpha honoured (to punch a hole in the clip so a lower lane shows through) opts in with the `// #alpha` directive - see `directives`.

**Pasting non-Shadertoy shaders:** shaders written for raw WebGL, three.js, glslCanvas, or Book of Shaders use a different convention (`void main()` + `gl_FragColor`, host-named uniforms like `uTexture` / `vUv` / `u_time`). A compatibility shim rewrites the common cases automatically: it converts the entry point + output, and maps the well-known names (`uTexture` / `tDiffuse` / `u_texture` -> `iChannel0`, `vUv` / `vTexCoord` -> the pixel coordinate, `u_time` / `iGlobalTime` -> `iTime`, `u_resolution` -> `iResolution.xy`, `u_mouse` -> `iMouse.xy`, `texture2D` -> `texture`). Any declared `sampler2D` uniform is routed to `iChannel0..3` in declaration order whatever its name, so a single-texture shader binds its texture to the source clip automatically (the name doesn't have to be recognised). What still needs a hand edit is an unusual NON-texture uniform - a resolution / time / mouse value under a name the list doesn't know (say `screenSize`) - which surfaces as an "undeclared identifier" pointing at the fix. Shaders already written to the `mainImage` convention pass through untouched. Shadertoy remains the best-supported source because its shaders need no translation at all.

**Source footage on `iChannel0`:** Mirage is a Final Cut effect, so the clip it's applied to is bound to `iChannel0`. A pasted shader that samples `iChannel0` (e.g. `texture(iChannel0, uv)`) processes your footage - blur, displace, tint, feed it into a reaction-diffusion, etc. Apply Mirage to an **adjustment layer** to run the shader over everything beneath it. `iChannel1` carries a second clip when the **"To" image well** is filled (see below); `iChannel2`/`iChannel3` read procedural noise.

**Audio works, but not through a Shadertoy channel texture.** Mirage's `#audio` directive binds audio published from Sonar. Use `uMusicBand(i)` for the spectrum, or opt into a time-domain window with `waveform=128` and read `uMusicWave(i)`. A Shadertoy music visualiser therefore needs its row-0 lookup replaced with `uMusicBand(...)` and its row-1 lookup with `uMusicWave(...)`. Unlike a live channel texture, both remain deterministic during scrubbing and export. See `directives` and `audio-shader-directive`.

**Not supported yet:** a THIRD image input (`iChannel0` is the clip and `iChannel1` the "To" well, but `iChannel2`/`iChannel3` can't be wired to your own media - they read noise or a buffer), cubemaps, an audio waveform (`#audio` gives the spectrum, not raw samples), and keyboard input.

## Two clips: transitions and picture-in-picture

A shader can read a **second clip** on `iChannel1`, which is what makes real transitions possible - not just an effect that distorts one clip, but a genuine A-to-B blend.

Fill the **"To"** image well in the inspector and it lands on `iChannel1`. Combined with `iProgress` (0 at the effect's first frame, 1 at its last) that's everything a cross-dissolve needs:

```glsl
vec4 transitionMix(vec4 fromColor, vec4 toColor, float amount)
{
    float alpha = mix(fromColor.a, toColor.a, amount);
    vec3 premultiplied = mix(fromColor.rgb * fromColor.a, toColor.rgb * toColor.a, amount);
    vec3 color = alpha > 0.0001 ? premultiplied / alpha : vec3(0.0);
    return vec4(color, alpha);
}

void mainImage(out vec4 O, in vec2 fc)
{
    vec2 uv = fc / iResolution.xy;
    O = transitionMix(texture(iChannel0, uv), texture(iChannel1, uv), iProgress);
}
```

**As a Final Cut transition** (dropped on a cut, both clips fed automatically): the Motion transition template keeps Mirage on its **Group**, wires **Drop Zone Transition A** into the hidden **From** well, and wires **Drop Zone Transition B** into the hidden **To** well. A `// #template transition` shader then receives those clean inputs as `iChannel0` and `iChannel1`; ordinary filters still receive the effect clip as `iChannel0`. Neither well is published, so the editor only sees the shared Transition / In / Out control.

**As a picture-in-picture**, two routes:

- **Two clips, one shader:** apply Mirage to the main clip, drop the inset clip into the "To" well, and composite `iChannel1` into a corner. Here the manual pick is right - there's no implicit second clip, the user genuinely chooses it.
- **Stacked clips, same shader on each:** give the shader a `#choice` for its region and `// #alpha`, so each instance draws its own clip into its own area and stays transparent elsewhere; Final Cut's lane compositing stacks them. This is the one that generalises to quarters and grids, because it isn't limited to two sources.

## gl-transitions.com shaders

Shaders from the **GL Transitions** catalogue use a neighbouring dialect, detected automatically by the `vec4 transition(vec2 uv)` signature and adapted. Add `// #template transition` to classify the template; the transition body itself otherwise needs no port:

| GL Transitions              | becomes                                              |
| --------------------------- | ---------------------------------------------------- |
| `vec4 transition(vec2 uv)`  | the entry point (no `mainImage` needed)              |
| `getFromColor(uv)`          | the clip Mirage is applied to (`iChannel0`)          |
| `getToColor(uv)`            | the **"To"** well (`iChannel1`)                      |
| `progress`                  | `iProgress`                                          |
| `ratio`                     | the frame's aspect (`iResolution.x / iResolution.y`) |
| `uniform float x; // = 1.0` | a constant with that default                         |

With that one template declaration, the catalogue shader runs as it does on the web, with `progress` sweeping linearly.

Transition output alpha is preserved automatically. This matters for a single-sided transition at the start or end of a connected clip: the missing side remains transparent, allowing the timeline beneath to show through instead of producing an opaque black frame.

Interpolate transition colours in premultiplied space as in `transitionMix` above. A raw `mix(fromColor, toColor, amount)` is only equivalent when both inputs are opaque; with an empty side it darkens RGB while alpha is also fading.

Two caveats. Its custom uniforms currently become **constants** at their authored defaults, so they aren't inspector controls yet - to expose one, rewrite it as a `// #float` directive (see `directives`). And `progress` is only special inside a GL transition; in an ordinary shader `progress` is an ordinary name you can use freely, and the built-in is `iProgress`.

Where the catalogue beats its own spec: `progress` is linear-only on the web, but here `// #progress` turns it into a lane on the timing engine, so a transition can be eased, held, or reshaped like any other property.

## Multi-pass (tabs: Common + Buffer A-D)

The editor has a tab strip. It starts on the single **Image** tab; the **+** menu adds **Common** and **Buffer A** through **Buffer D**, and **✕** removes a tab. This mirrors Shadertoy's multi-pass model:

- **Common** is prepended to every pass - put shared helpers / `#define`s / constants here. It renders nothing itself.
- **Buffer A-D** are offscreen passes (16-bit float) that run before Image, in order. Each stores DATA a later pass reads, not display pixels (no grain / sRGB / opaque forcing is applied to a buffer's output).
- **Channel routing is positional:** `iChannel0` -> Buffer A, `iChannel1` -> Buffer B, `iChannel2` -> Buffer C, `iChannel3` -> Buffer D, for any buffer that exists. A channel with no matching buffer falls back to the source clip (ch0) or noise. So a paste-in that expects "iChannel0 = Buffer A" works, but one wiring a channel to external footage does not (there's no per-pass routing UI yet).
- **Feedback works.** A buffer may read its own (or a later buffer's) _previous_ frame - the engine keeps persistent ping-pong state per pass. That's what makes motion trails, fluid, and reaction-diffusion (Gray-Scott etc.) possible. Scrubbing is deterministic: the engine re-simulates from checkpoints so a given timeline frame always looks the same. Feedback sims run at a capped resolution (~360-tall) on purpose - reaction-diffusion / fluid patterns are a few cells wide and barely develop on a fine grid; the mini-viewer matches.

## Built-in controls a shader can opt into

These three are **opt-in**: a shader that doesn't declare them gets neither the controls nor their effect (speed 1, no time offset, no grain). They are the only directives that stand alone rather than annotating a uniform, because they drive shared engine values rather than something the shader declares.

- `// #speed` adds **Speed**, multiplying `iTime` (0 freezes it, 2 runs it twice as fast).
- `// #seed` adds **Seed**, offsetting where `iTime` starts, for per-clip variety. A looping shader built around `mod(iTime, N)` can show a visible "jump" once per loop; nudging Seed or lowering Speed slides that seam out of the clip. For a per-shader random seed bound to your own uniform, use `#random` instead - see the directives doc.
- `// #grain` adds **Grain** and **Grain Size**, a film grain overlaid on the shader's output. `default=` seeds the amount, `size=` the cell size.
- Any positioning, scale, rotation, colour, etc. a shader wants is exposed by **declaring its own controls** with `// #` directives (see the directives doc). A shader otherwise positions itself in code.

## The editor

The Mirage editor is a small dark (GitHub-Dark) code pane: live GLSL syntax highlighting, a line-number gutter, and live error reporting. A shader that fails to compile shows a red bar reading `Line N: <message>` and flags line N in both the code and the gutter; fix it and the flag clears. When asking for an edit, refer to lines by the gutter numbers.

## Tips

- Animate by driving values off `iTime`.
- Start single-pass (one `mainImage` in the Image tab); reach for Buffer tabs only when a shader needs an offscreen pass or frame-to-frame feedback.
- Sampling an unused `iChannel1-3` gives smooth value noise - good for grain, fbm, hashing. Two exceptions: a Buffer routed to that channel, and `iChannel1` when the "To" image well is filled (then it's a second clip, not noise).
- If a pasted shader renders differently near the end of a clip, it's usually the shader's own `mod(iTime, N)` loop seam positioned by Seed, not a bug.
- Grain is opt-in. A shader ported from elsewhere that looks flatter than expected in 8-bit may want `// #grain` back.
