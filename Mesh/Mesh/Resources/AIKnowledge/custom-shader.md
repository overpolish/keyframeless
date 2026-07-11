---
id: custom-shader
summary: Writing and editing custom Shadertoy-style shaders in Mesh's Custom type
---

# The Custom shader type

Set **Type** to **Custom** to turn Mesh into a blank shader canvas: paste a
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

| Name                     | Type        | Meaning                                                        |
| ------------------------ | ----------- | -------------------------------------------------------------- |
| `iResolution`            | `vec3`      | output size in px (`.xy`), `.z` = 1                            |
| `iTime`                  | `float`     | seconds, scaled by the shared **Speed** and offset by **Seed** |
| `iTimeDelta`             | `float`     | seconds/frame (approx)                                         |
| `iFrame`                 | `int`       | frame index (approx)                                           |
| `iMouse`                 | `vec4`      | present but currently always 0 (no mouse input wired yet)      |
| `iDate`                  | `vec4`      | present but currently always 0                                 |
| `iChannel0`..`iChannel3` | `sampler2D` | bound to a repeating value-noise texture                       |

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

**Not supported yet:** real image or video inputs on the channels (they read
procedural noise, not your media), multi-pass shaders (Buffer A/B/C/D), cubemaps,
audio, and keyboard input.

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
- Keep it single-pass (one `mainImage`); multi-pass buffers aren't available.
- Sampling `iChannel0` gives smooth value noise - good for grain, fbm, hashing.
- If a pasted shader renders differently near the end of a clip, it's usually the
  shader's own `mod(iTime, N)` loop seam positioned by Seed, not a bug.
