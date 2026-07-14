# Mesh Custom Shader - mini spec

The **Custom** type turns Mesh into an empty, animation-aware shader vessel. The
user pastes a Shadertoy shader (or writes their own), and any value they _mark_
becomes a keyframeless lane: a slider, colour, point, or dial that animates on
the timeline. The shader is the commodity. The value is that every marked
parameter drops into the existing lane / timeline / palette system for free.

## Principles

- **Shadertoy-compatible by default.** The canonical entry point is Shadertoy's
  `void mainImage(out vec4 fragColor, in vec2 fragCoord)`, and the built-in
  uniforms use Shadertoy names (`iTime`, `iResolution`, `iMouse`, ...). Paste a
  single-pass Image shader and it runs, unmodified.
- **Marker = opt-in.** An unmarked variable stays private (intermediates, loop
  counters, temporaries never leak into the UI). Only marked declarations become
  controls.
- **Markers are comments.** They start with `//!`, so the shader stays valid
  source exactly as written: the compiler ignores them, our parser reads them. A
  pasted shader with no markers still runs; it just has no knobs until the user
  adds them.
- **Animatable by default.** Every control keyframes. Only `choice` and `seed`
  default to constant (the two things nobody animates). A `const` flag forces
  any control constant.
- **We ship nothing borrowed.** The engine is the product. Users bring their own
  shaders under whatever licence; we don't redistribute them. Any built-in
  starter snippets are ours or CC0/MIT.

## The contract (what the user writes)

The user writes a Shadertoy Image shader:

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = vec4(uv, 0.5, 1.0);
}
```

We wrap it into a complete GLSL unit that (a) supplies the built-in uniforms and
`main()`, and (b) binds each marked parameter, then transpile the whole thing to
Metal with **glslang** (GLSL to SPIR-V) and **SPIRV-Cross** (SPIR-V to MSL). This
is the real GLSL compiler, not a regex approximation, so the full language works.
The user never writes the vertex stage, the argument struct, or the bindings.

### Built-in uniforms (always available, no marker needed)

Shadertoy's set, so pasted shaders find what they expect:

| name          | type    | meaning                                            |
| ------------- | ------- | -------------------------------------------------- |
| `iResolution` | `vec3`  | output size in pixels (`.xy`), `.z` = pixel aspect |
| `iTime`       | `float` | seconds, driven by clip time x the shared Speed    |
| `iTimeDelta`  | `float` | seconds since last frame                           |
| `iFrame`      | `int`   | frame index                                        |
| `iMouse`      | `vec4`  | Shadertoy mouse; mapped to the shared Origin lane  |
| `iDate`       | `vec4`  | year, month, day, seconds-in-day                   |

Plus Mesh extras (this is the value-add over a bare Shadertoy runner):

| name          | type   | meaning                                     |
| ------------- | ------ | ------------------------------------------- |
| `iColor[i]`   | `vec4` | palette swatch `i` (the shared Color lanes) |
| `iColorCount` | `int`  | active palette size                         |
| `iOrigin`     | `vec2` | the shared Origin lane (0..1)               |
| `iScale`      | `vec2` | the shared Scale lane                       |

So a custom shader inherits the palette generator, Speed, and Origin without
declaring anything. Marked parameters are _additional_ knobs on top.

## Marker grammar

A `//!` comment on the declaration line (or the line directly above it):

```
<type> <name>;   //! <control> "<Label>" [range] [= default] [unit"x"] [step N] [flags]
```

`<control>` is required. Everything else has sensible defaults. `<Label>` is
what shows in the inspector; omit it and the variable name is title-cased.
Inline on the declaration is the convention; there is no separate JSON header to
keep in sync.

### Control types to lane mapping

| control  | GLSL type       | lane                                  | default state | notes                                 |
| -------- | --------------- | ------------------------------------- | ------------- | ------------------------------------- |
| `slider` | `float`         | float lane, `componentMin/Max`, units | animatable    | `range` as `min..max`; default `0..1` |
| `color`  | `vec4` / `vec3` | `KKLaneValueTypeColor` (4-comp)       | animatable    | default `#ffffff`; palette path       |
| `point`  | `vec2`          | Generic 2-comp lane (X/Y fields)      | animatable    | default `0.5,0.5`; no OSC (see below) |
| `angle`  | `float`         | angle-dial lane                       | animatable    | value in degrees; default `0`         |
| `choice` | `float` / `int` | integer lane, `choiceLabels` (pills)  | **constant**  | `[A,B,C]`; default first              |
| `seed`   | `float` / `int` | integer stepper lane                  | **constant**  | default `0`                           |

### Params

- **range**: `0..1`, `-1..1`, `0..100`. Slider/angle only. Omit for a default.
- **default**: `= 0.5`, `= #ff8844`, `= 0.5,0.5`, `= 90`, `= Hard`. Sets the
  lane's constant keypose (the starting value).
- **unit**: `unit"px"`, `unit"%"`. Cosmetic, shown in the field.
- **step**: `step 1` for integer-ish sliders.
- **flags**: `const` forces non-animatable (choice/seed already are).

### On-screen controls

`point` markers do **not** spawn a canvas handle. The shared **Origin** lane
already gives one draggable point on the canvas, which covers the common case
and keeps the viewer uncluttered. If a shader genuinely needs a second handle,
that is a later, explicit opt-in (an `osc` flag on a `point` marker), not a
default. v1 ships with Origin as the only handle.

### Examples of markers

```glsl
float warmth;   //! slider "Warmth" 0..1 = 0.5
float detail;   //! slider "Detail" 0..10 = 3 unit"px" step 1
vec4  tint;     //! color  "Tint" = #ff8844
vec2  centre;   //! point  "Centre" = 0.5,0.5
float spin;     //! angle  "Spin" = 0
float style;    //! choice "Style" [Soft, Hard, Wild] = Hard
int   seed;     //! seed   "Seed" = 7
```

## Shadertoy paste - what actually works

Copy a single-pass Shadertoy _Image_ shader, paste it, it runs. Since it goes
through the real glslang + SPIRV-Cross toolchain (not a text substitution), the
whole GLSL language is on the table:

**Works out of the box:**

- The `void mainImage(out vec4 fragColor, in vec2 fragCoord)` entry point.
- The full GLSL type system and every builtin (`fract`, `mix`, `mod`, `atan`,
  `inversesqrt`, matrix ctors, `out`/`inout` params, `p.x` passed by reference,
  swizzle compound-assignment, `#define`/`#if` macros, etc.). If it compiles on
  Shadertoy, it compiles here.
- The uniforms: `iTime`, `iResolution`, `iTimeDelta`, `iFrame`, `iMouse`,
  `iDate`.
- Texture channels `iChannel0..3`: bound to a repeating value-noise texture, so
  the near-universal "iChannel = noise" shaders (fbm, hashes, dithering) render
  correctly.

**Not supported yet:**

- Real image / video inputs on the channels (they read noise, not your media).
- Multi-pass shaders (Buffer A/B/C/D), cubemaps, audio, keyboard.

The workflow: **paste, it runs with `iTime` animating, then the user adds `//!`
markers to the numbers they want to control.** A pasted shader starts with zero
knobs and gains them as the user annotates. That is the whole loop.

### Worked example - paste, then annotate

Pasted verbatim from Shadertoy (runs immediately, no knobs yet):

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float w = 0.5 + 0.5 * sin(iTime + uv.x * 10.0);
    fragColor = vec4(vec3(w), 1.0);
}
```

The user annotates two numbers and swaps the greyscale for the palette:

```glsl
float freq;   //! slider "Frequency" 0..20 = 10
float speed;  //! slider "Speed" 0..4 = 1

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float w = 0.5 + 0.5 * sin(iTime * speed + uv.x * freq);
    fragColor = vec4(mix(iColor[0].rgb, iColor[1].rgb, w), 1.0);
}
```

Now `Frequency` and `Speed` are keyframeless lanes and the shader draws from the
palette generator via `iColor[]`.

## Implementation notes (contained, not research)

- **Render fork.** Types 0..11 stay statically compiled from `Mesh.metal`.
  `Custom` branches to a runtime pipeline: `KKGLSLTranspiler` transpiles the
  wrapped GLSL to MSL (glslang + SPIRV-Cross, memoised by source hash), and the
  `newLibraryWithSource:` pipeline is cached per device on the emitted MSL hash.
  The main render and the inspector mini-viewer share the same transpiler path.
  A transpile/compile failure draws the hazard-stripe error shader; render never
  blocks or crashes.
- **Uniforms.** The built-in uniform block is all-`vec4` (`KKGLSLUniforms`), so
  its std140 layout maps 1:1 to the fill struct with no packing to reconcile.
  `iResolution/iTime/iTimeDelta/iFrame` are aliased onto its lanes; flipY, the
  sRGB encode and premultiply live in the generated `main()`.
- **Channels.** Only channels the source references are declared; SPIRV-Cross
  reflection reports each one's MSL texture/sampler index, and a per-device
  value-noise texture is bound there.
- **Parameter binding.** The marker parser produces (a) a list of lanes to
  register (so the inspector, timeline, and palette light up) and (b) the
  generated argument struct plus per-frame bindings from each lane's current
  value.
- **Error mapping.** The prelude prepends N lines, so compile-error line numbers
  must be offset back into the editor's coordinates or every error points at the
  wrong line.
- **Persistence.** The shader source is a string param (same as the timeline
  blob): it travels with the clip and survives relaunch.
- **Editor.** `NSTextView` in the inspector with a `NSTextStorage` re-colour
  pass on edit. Highlighting is the easy part; the real care is ViewBridge
  keyboard/focus behaviour for a continuously-typed multiline field.

## Decisions (resolved)

- **Language / names:** conventional Shadertoy. `mainImage` entry, Shadertoy
  uniform names, real GLSL via glslang + SPIRV-Cross. Copy-paste is the headline.
- **OSC:** none by default. Origin already provides the one canvas handle; a
  per-`point` `osc` flag is a possible later opt-in.
- **Markers:** inline on the declaration line. No separate header block.
