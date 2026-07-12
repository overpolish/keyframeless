---
id: custom-shader
summary: Writing and editing custom Shadertoy-style shaders in Shader's Custom type
---

# The Custom shader type

Set **Type** to **Custom** to turn Shader into a blank shader canvas: paste a
Shadertoy "Image" shader (or write your own GLSL) into the **Shader** editor and
it runs live on the clip. Under the hood the GLSL is compiled to Metal at runtime
with the real glslang + SPIRV-Cross toolchain, so the **full GLSL language
works** - not a hand-rolled subset. If a single-pass Image shader compiles on
Shadertoy, it almost always runs here unchanged.

- Entry point is Shadertoy's `void mainImage(out vec4 fragColor, in vec2 fragCoord)`.
- The **Shader** lane sits at the bottom of the Core section (only visible when
  Type is Custom). It opens a syntax-highlighted code editor.

## Built-in inputs (no declaration needed)

Use them exactly as on Shadertoy:

| Name                     | Type        | Meaning                                                                                   |
| ------------------------ | ----------- | ----------------------------------------------------------------------------------------- |
| `iResolution`            | `vec3`      | output size in px (`.xy`), `.z` = 1                                                       |
| `iTime`                  | `float`     | seconds, scaled by the shared **Speed** and offset by **Seed**                            |
| `iTimeDelta`             | `float`     | seconds/frame (approx)                                                                    |
| `iFrame`                 | `int`       | frame index (approx)                                                                      |
| `iMouse`                 | `vec4`      | present but currently always 0 (no mouse input wired yet)                                 |
| `iDate`                  | `vec4`      | present but currently always 0                                                            |
| `iChannel0`              | `sampler2D` | **the source clip** Shader is applied to (the footage / adjustment-layer composite below) |
| `iChannel1`..`iChannel3` | `sampler2D` | bound to a repeating value-noise texture                                                  |

## What works, what doesn't

**Works out of the box:** the whole GLSL language - `mod`, `atan`,
`inversesqrt`, matrix constructors, `out`/`inout` params, passing a vector
component like `p.x` by reference, swizzle compound-assignment (`p.xy *= rot`),
`#define`/`#if` macros, loops, etc. Two Shadertoy-compat behaviours are matched
deliberately:

- **Uninitialised locals read as zero** (like Chrome/ANGLE, which Shadertoy runs
  on). Golfed shaders that rely on `float i;` starting at 0 (e.g.
  `for (O *= i; i < n; i++)`) work.
- **Output is forced opaque.** Shadertoy ignores `fragColor.a`; so does this. A
  shader can't punch a hole in the clip by writing a low alpha.

**Pasting non-Shadertoy shaders:** shaders written for raw WebGL, three.js,
glslCanvas, or Book of Shaders use a different convention (`void main()` +
`gl_FragColor`, host-named uniforms like `uTexture` / `vUv` / `u_time`). A
compatibility shim rewrites the common cases automatically: it converts the entry
point + output, and maps the well-known names (`uTexture` / `tDiffuse` /
`u_texture` -> `iChannel0`, `vUv` / `vTexCoord` -> the pixel coordinate,
`u_time` / `iGlobalTime` -> `iTime`, `u_resolution` -> `iResolution.xy`,
`u_mouse` -> `iMouse.xy`, `texture2D` -> `texture`). Any declared `sampler2D`
uniform is routed to `iChannel0..3` in declaration order whatever its name, so a
single-texture shader binds its texture to the source clip automatically (the name
doesn't have to be recognised). What still needs a hand edit is an unusual NON-
texture uniform - a resolution / time / mouse value under a name the list doesn't
know (say `screenSize`) - which surfaces as an "undeclared identifier" pointing at
the fix. Shaders already written to the `mainImage` convention pass through
untouched. Shadertoy remains the best-supported source because its shaders need no
translation at all.

**Source footage on `iChannel0`:** Shader is a Final Cut effect, so the clip it's
applied to is bound to `iChannel0`. A pasted shader that samples `iChannel0` (e.g.
`texture(iChannel0, uv)`) processes your footage - blur, displace, tint, feed it
into a reaction-diffusion, etc. Apply Shader to an **adjustment layer** to run the
shader over everything beneath it. `iChannel1`..`iChannel3` still read procedural
noise.

**Not supported yet:** extra image/video inputs beyond the source (you can't wire
`iChannel1-3` to your own separate media - they read noise or a buffer), cubemaps,
audio, and keyboard input.

## Multi-pass (tabs: Common + Buffer A-D)

The editor has a tab strip. It starts on the single **Image** tab; the **+** menu
adds **Common** and **Buffer A** through **Buffer D**, and **✕** removes a tab.
This mirrors Shadertoy's multi-pass model:

- **Common** is prepended to every pass - put shared helpers / `#define`s /
  constants here. It renders nothing itself.
- **Buffer A-D** are offscreen passes (16-bit float) that run before Image, in
  order. Each stores DATA a later pass reads, not display pixels (no grain / sRGB
  / opaque forcing is applied to a buffer's output).
- **Channel routing is positional:** `iChannel0` -> Buffer A, `iChannel1` ->
  Buffer B, `iChannel2` -> Buffer C, `iChannel3` -> Buffer D, for any buffer that
  exists. A channel with no matching buffer falls back to the source clip (ch0) or
  noise. So a paste-in that expects "iChannel0 = Buffer A" works, but one wiring a
  channel to external footage does not (there's no per-pass routing UI yet).
- **Feedback works.** A buffer may read its own (or a later buffer's) _previous_
  frame - the engine keeps persistent ping-pong state per pass. That's what makes
  motion trails, fluid, and reaction-diffusion (Gray-Scott etc.) possible.
  Scrubbing is deterministic: the engine re-simulates from checkpoints so a given
  timeline frame always looks the same. Feedback sims run at a capped resolution
  (~360-tall) on purpose - reaction-diffusion / fluid patterns are a few cells
  wide and barely develop on a fine grid; the mini-viewer matches.

## Shared controls that affect a Custom shader

- **Speed** multiplies `iTime` (0 freezes it, 2 runs it twice as fast).
- **Seed** offsets where `iTime` starts, for per-clip variety. A looping shader
  built around `mod(iTime, N)` can show a visible "jump" once per loop; nudging
  Seed or lowering Speed slides that seam out of the clip.
- **Grain** / **Grain Size** overlay the same core film grain the built-in types
  use, applied on top of the shader's output.
- **Origin**, **Scale** and **Rotation** do **not** affect a Custom shader - they
  drive the built-in gradient types only. A custom shader positions itself.

## The editor

The Shader editor is a small dark (GitHub-Dark) code pane: live GLSL syntax
highlighting, a line-number gutter, and live error reporting. A shader that fails
to compile shows a red bar reading `Line N: <message>` and flags line N in both
the code and the gutter; fix it and the flag clears. When asking for an edit,
refer to lines by the gutter numbers.

## Tips

- Animate by driving values off `iTime`.
- Start single-pass (one `mainImage` in the Image tab); reach for Buffer tabs only
  when a shader needs an offscreen pass or frame-to-frame feedback.
- Sampling an unused `iChannel1-3` gives smooth value noise - good for grain, fbm,
  hashing (unless you've added a Buffer that routes to that channel).
- If a pasted shader renders differently near the end of a clip, it's usually the
  shader's own `mod(iTime, N)` loop seam positioned by Seed, not a bug.
