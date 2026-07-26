---
id: directives
summary: Declaring inspector controls and on-screen controls in a Custom shader with // # directives
---

# Custom controls: `// #` directives

A Custom shader can expose its own **inspector controls** and **on-screen controls (OSCs)** by annotating its uniforms. Put a `// #<kind>` comment on the line **before** a `uniform` declaration, and Mirage builds a matching, fully keyframeable timeline lane for it. The uniform's value then comes from that lane (and its keyposes / OSC) instead of being a fixed constant.

- **Value controls:** `#float` / `#percent` / `#int` (sliders), `#bool` (switch), `#choice` (a menu or pill), `#angle` (a dial), `#color` (a colour well), `#gradient` (a colour ramp), `#multi` (2-4 numbers), `#random` (a dice field).
- **Spatial controls:** `#point` (a draggable position handle). Add `osc` to a value control for an on-screen ring, box, or rotation ring that edits the same lane.
- **Reactive:** `#audio` binds a Sonar-published spectrum; `#progress` exposes a transition's sweep.
- **Built-ins:** `#speed`, `#seed`, `#grain` opt into engine controls and stand alone (no uniform).
- Attributes tune each one: `label=`, `min=` / `max=`, `default=`, `group=` (which inspector group it lands in), and `osc=` place the on-screen control. The rest of this doc details every kind.

```glsl
// #float label="Amount" min=0 max=2 default=0.5
uniform float uAmount;
```

That one pair adds an animatable **Amount** slider (0-2, default 0.5) to the inspector, and inside the shader `uAmount` reads the live value. Everything a built-in property can do - keyposes, easing, Basic/Advanced timing, motion blur - works on a declared control automatically.

**Rules that always hold:**

- The directive comment must be immediately above the `uniform` line (only blank lines between them; the next directive ends the search). The three built-ins (`#speed` / `#seed` / `#grain`) are the exception: they annotate nothing and stand on their own line.
- The **uniform name is the identity** of the control (its keyframes follow the name). `label=` is display-only - renaming the label keeps the animation; renaming the uniform starts a fresh control.
- Each control needs a **unique uniform name** - a duplicate uniform is a compile error surfaced in the editor. Labels may repeat freely (two controls can both show "Size"); the uniform is the identity, the label is just what the rows display.
- These directives only apply to the **Custom** type (the whole shader system is Custom-only). See the custom-shader doc for the shader language itself.

## Control kinds

| Directive   | Uniform type       | Inspector control                                | What the shader receives                                                      |
| ----------- | ------------------ | ------------------------------------------------ | ----------------------------------------------------------------------------- |
| `#color`    | `vec4 n;`          | colour swatch                                    | `vec4` RGBA (from the Colours-style swatch)                                   |
| `#color`    | `vec4 n[N];`       | palette bar (up to N)                            | `vec4 n[N]` + `nCount` (int) active count                                     |
| `#gradient` | `vec4 n[N];`       | gradient bar (stops up to N)                     | `nAt(t)` → `vec3` at position t; `nStops` (int) live stop count               |
| `#float`    | `float n;`         | slider                                           | the raw value                                                                 |
| `#percent`  | `float n;`         | slider shown as `%`                              | **0..1** (the inspector shows 0-100%)                                         |
| `#progress` | `float n;`         | slider shown as `%`, keyframed 0→100% by default | **0..1** — transition progress; see below                                     |
| `#int`      | `float n;`         | integer slider                                   | `int`                                                                         |
| `#random`   | `float n;`         | dice/seed field (no anim)                        | the raw integer value                                                         |
| `#angle`    | `float n;`         | rotation dial (whole degrees)                    | **radians, negated** (`radians(-deg)`)                                        |
| `#bool`     | `bool n;`          | checkbox                                         | `bool`                                                                        |
| `#choice`   | `int n;`           | segmented pills                                  | `int` selected index (0-based)                                                |
| `#point`    | `vec2 n;`          | 2D point                                         | pixels (`value * iResolution.xy`, fragCoord space)                            |
| `#multi`    | `vec2` / `vec3 n;` | N-component field                                | the raw vector                                                                |
| `#audio`    | `vec4 n[N];`       | audio source picker                              | live spectrum `nBand(i)`+`nBands`; `flow` adds cumulative `nFlow` (see below) |
| `#speed`    | _(none)_           | Speed slider                                     | nothing directly - scales `iTime`                                             |
| `#seed`     | _(none)_           | Seed field                                       | nothing directly - offsets `iTime`                                            |
| `#grain`    | _(none)_           | Grain + Grain Size                               | nothing directly - grain is overlaid on the output                            |

The uniform TYPE is folded away by the compiler - you use `uAmount` directly as a `float`, `uColor` as a `vec4`, etc. A mistyped uniform type is tolerated (the `#`-kind wins), so `#int` over a `uniform float` still delivers an int.

## Groups

Every control lands in an inspector **group**. Without `group=` a control goes to **Options**. Name a group and the control moves there, creating it if it's the first to ask:

```glsl
// #float label="Glow" group="Glow Options" min=0 max=1
uniform float uGlow;

// #percent label="Falloff" group={"Glow Options", "sparkles"}
uniform float uFalloff;
```

Both forms are accepted: `group="Name"` on its own, or `group={"Name", "sf.symbol"}` to give the group an icon. The icon only has to be named **once** per group - any other control joining the group inherits it, so the short form is fine everywhere else. The symbol is any SF Symbol name macOS knows (the editor offers a curated list and flags a name that doesn't resolve).

- **Group order** is: `Shader`, `Audio`, `Colors` first (always, in that order), then your own groups in the order the shader first names them. Move a directive above another and its group moves up with it.
- **`#color`, `#audio` and `#gradient` reject `group=`** - they collect into their own dedicated groups, and a group there would either be ignored or split a colour set away from its swatches. Using it is a compile error in the editor.

## The built-ins: `#speed`, `#seed`, `#grain`

Three controls the engine provides rather than the shader. They **stand alone** (no uniform beneath them), and they are **opt-in** - a shader that doesn't declare them renders with speed 1, no time offset and no grain:

```glsl
// #speed group={"Motion", "wind"}
// #seed group="Motion"
// #grain default=20 size=3
```

- `#speed` multiplies `iTime`. `#seed` offsets where `iTime` starts.
- `#grain` adds **two** lanes, the amount and its cell size. `default=` seeds the amount (a percentage), `size=` the cell size in pixels. `label=` renames the amount only.
- All three take `label=` and `group=` like any other control.

### `#alpha` (masking your own clip)

By default a shader's alpha is decided for it, by whether it samples the source:

- **Doesn't sample `iChannel0`** (a generator): its transparent areas composite over the footage, so it never renders on black.
- **Does sample `iChannel0`** (a filter): output is forced **opaque** - the source IS the background, and golfed pastes leave garbage in `fragColor.a`.

`// #alpha` (on its own line, no uniform) opts into a third mode: **your alpha is authoritative**, emitted premultiplied, with no compositing and no forced-opaque.

Use it when the shader **masks its own clip** - drawing it into part of the frame and needing to be genuinely transparent elsewhere so a lower lane shows through. The classic case is a stacked-clips picture-in-picture: apply one shader to several clips, give each a different region, and let Final Cut's lane compositing stack them.

```glsl
// #alpha

// #choice label="Layout" options="Main,Top Left,Top Right" default=0
uniform int uLayout;

void mainImage(out vec4 O, in vec2 fc) {
  if (uLayout == 0) {                                  // backplate: opaque
    O = vec4(texture(iChannel0, fc / iResolution.xy).rgb, 1.0);
    return;
  }
  // ... draw this clip small, and set O.a = 0 outside the box so the clip
  // on the lane below shows through.
}
```

Without it, that shader can't work: the corner instance samples `iChannel0`, gets `a = 1`, and covers the clip below with clamped edge pixels smeared out from the box.

### `#progress` and `iProgress` (transitions)

Every shader gets a built-in **`iProgress`**: the clip fraction, `0` at the effect's first frame and `1` at its last, rising linearly. In a Motion transition template that window IS the transition, so `iProgress` is the GL Transitions `progress` with nothing to declare:

```glsl
void mainImage(out vec4 O, in vec2 fc) {
    vec2 uv = fc / iResolution.xy;
    O = mix(texture(iChannel0, uv), texture(iChannel1, uv), iProgress); // cross-dissolve
}
```

`// #progress` gives the user **control over the curve**:

```glsl
// #progress label="Progress"
uniform float uProgress;
```

Unlike every other directive, its lane defaults to a **ramp** rather than a constant: 0% at the start, 100% at the end, linear. So a `#progress` lane left untouched evaluates to exactly the same thing as `iProgress`, and declaring it never changes what the shader does. What it adds is the timing engine - the user can ease it, move the keyposes, or reshape it entirely, which is something the upstream GL Transitions spec (linear only) can't express.

Use `iProgress` when the shader should always run linearly; use `#progress` when the transition's pacing is worth exposing. Note the uniform receives **0..1** even though the inspector shows 0-100%, matching `#percent`.

### `#motionblur` (who owns the blur)

The user's **Motion Blur** popover (on/off, shutter, samples) is separate from any directive. `// #motionblur <mode>` (on its own line, no uniform) only decides **who applies** those settings. Absent, the default is `accumulate`.

- **`accumulate`** (default): the plugin re-renders the shader at N sub-frame times across the shutter and averages them. Correct for any ordinary animated shader with **nothing to declare** - it just works. Multi-pass is fine: a buffer chain that only reads earlier buffers is a pure function of the current uniforms, so it is encoded ONCE and each sample re-runs only the Image pass. That makes a buffer the right home for an expensive precompute (a source blur, say) - inline, it would be recomputed inside every sample. A **feedback** chain (a buffer reading itself or a later buffer) is the exception: its state depends on history, so it can't be shared across samples and validation asks you to declare `native` or `off` instead.
- **`native`**: the shader **blurs itself** - a feedback trail, or its own internal sampling loop. The plugin renders once and hands you the popover settings as globals:
  - **`iMotionBlur`** - shutter as `0..1` (`0` when Motion Blur is off). Map it onto your effect, e.g. a trail's decay.
  - **`iMotionBlurSamples`** - the sample count, if you loop internally.
- **`off`**: no motion blur for this shader.

Add a bare **`on`** (`// #motionblur on`, `// #motionblur native on`) to start ENABLED when the shader is applied from the browser, for an effect that is wrong without it - a transform, say, which otherwise reads as a hard cut every frame. It seeds the control at apply time only, so a user who turns blur off keeps it off. Leave it out otherwise: blur costs N renders per frame.

```glsl
// #motionblur native

void mainImage(out vec4 O, in vec2 fc) {
  vec2 uv = fc / iResolution.xy;
  // longer shutter -> longer trail (a feedback shader would read its own
  // previous frame from a Buffer; shown here as a decay factor).
  float trail = mix(0.85, 0.98, iMotionBlur);
  // ...
}
```

Reach for `native` only when the shader genuinely produces its own smear (trails / feedback) or wants an internal loop; otherwise leave it off and let `accumulate` handle it.

### `#audio` is the odd one out

Every other directive builds a keyframeable lane whose value you set. `#audio` doesn't: its lane is a **picker** listing the audio a user has published from Sonar, and the value arrives from that audio, frame by frame.

```glsl
// #audio label="Music"
uniform vec4 uMusic[16];
```

Read it with the generated `uMusicBand(i)` (band `i`, roughly `0...1`, low frequency first) and `uMusicBands` (how many there are, 4 per `vec4`), never by indexing the `vec4` packing by hand. Two per shader, up to 24 `vec4`s each.

One `#audio` builds an **Audio** group of four lanes, not one control: the source picker, plus animatable **Noise Gate** (dB), **Release** (seconds, how long a band takes to fall to zero once gated) and **Smoothness** (seconds) lanes. The directive takes `label=`, and `gate=` / `release=` / `smooth=` to seed those three - they're starting values, not settings, since the right gate depends on the mix rather than on the shader.

Add `flow` to also expose `uMusicFlow`, a **cumulative energy clock**: it counts up as beats go by and never counts down, so a beat pushes geometry FORWARD and it stays there. Use it when a live band value would pull back the moment the sound fades - e.g. particles that should be shoved outward on each hit and hold, not zoom in and out. Because it's stateless-safe (read from the analysis, not a remembered running sum), it survives scrubbing and export. It accumulates the lowest 4 bands by default; `flowlo=` / `flowhi=` set the shader-band range (e.g. `flowhi=1` for a tight kick, mids for bass) and `flowgate=` its dB floor (default -45, so a quiet noise floor never advances it). The value is in band-seconds and grows over the clip, so scale it down and wrap: `fract(birth + uMusicFlow * pushAmount)`.

```glsl
// #audio label="Beat" flow flowlo=0 flowhi=3 flowgate=-45
uniform vec4 uBeat[16];
// ... particle radius advances on every beat, never retreats:
float life = fract(birthPhase + iTime * baseSpeed + uBeatFlow * uPush);
```

Nothing picked reads as silence rather than an error, so a shader with an unbound `#audio` still renders.

A binding also survives leaving the Mac it was made on. Published audio doesn't travel inside a project, so one opened elsewhere can't find what it's bound to - the picker keeps naming it, greyed out, under a **Republish required** warning, and the user gets it back by dropping the project on Sonar (the clips are already selected) and pressing Publish. Nothing needs re-pointing. Mirage authors don't have to do anything for this: it's the picker's job, not the shader's, and no directive attribute affects it.

See `audio-shader-directive` for shaping the levels into something that looks good, and `audio-sonar` for how a user publishes the audio in the first place, including the walkthrough for that warning.

## On-screen controls (`osc`)

Add `osc` (or `osc=<kind>`) to a directive to also draw a **draggable control on the viewer and mini-viewer**. The control edits the same lane, so dragging is just another way to keyframe the value.

Each `osc=` value is **sugar** - a standard control with no math to write. For a **fully custom** control (a handle at a corner, a crop box, a ring whose value isn't its radius), author a `// @osc` block instead; see the osc-blocks reference for the primitives and their expressions.

| `osc` value            | Valid on                                                   | On-screen control                                                |
| ---------------------- | ---------------------------------------------------------- | ---------------------------------------------------------------- |
| `osc` / `osc=position` | `#point` (vec2)                                            | the full position control: a handle plus an editable motion path |
| `osc=point`            | `#point` (vec2)                                            | a plain draggable handle - just the glyph, no path               |
| `osc=ring`             | `#float` / `#percent` / `#int`, or 2-field `#multi` (vec2) | a radius **ellipse**; drag its edge to set the value(s)          |
| `osc=box`              | same as `osc=ring`                                         | a **rectangle** with 8 handles + a value readout                 |
| `osc={z}`              | `#angle` (float)                                           | a single **rotation ring** on the Z axis                         |
| `osc={y,x}`            | 2-field `#multi` (vec2)                                    | two rotation rings (Y and X axes)                                |
| `osc={z,x,y}`          | 3-field `#multi` (vec3)                                    | three rotation rings (Z, X, Y axes)                              |

A bare `osc` on `#point` defaults to the **position** control (motion path and all) - write `osc=point` when you only want a handle. A bare `osc` on `#angle` defaults to a single-axis (Z) rotation ring.

### Ring vs box

`osc=ring` and `osc=box` are the same control in two shapes - both size the value across `[min, max]`. A single-value field is a circle / square; a 2-field `#multi` (vec2) is an ellipse / rectangle with an independent radius per component. Drag a handle to resize; with `lockaspect` on the `#multi`, the ratio is held (Shift inverts the lock; Cmd = fine drag). The box also shows a readout in the field's units (e.g. `40%`, `5`, `0.4 x 0.2`).

The centre comes from `center=x,y` (object space) or `link=<uniform>`, which tracks a `#point`'s live value. For a centre that isn't simply one point, `link="<expression>"` takes a full expression over the shader's own uniforms - e.g. a scale box whose content pivots about an anchor rather than about its position:

```glsl
// #multi percent label="Scale" fields={X,Y} lockaspect osc=box
//   link="uPosition + (uAnchor - vec2(0.5)) * (vec2(1.0) - uScale)"
//   min={1,1} max={800,800} default="100,100"
uniform vec2 uScale;
```

Get this wrong and the control still _works_ - it just stops agreeing with the render as soon as the other uniforms move, which is easy to miss because it looks correct at the defaults.

A box can also grow **from an anchor** rather than symmetrically about its centre. `anchor=<#point uniform>` pins the anchor side: a centred anchor is unchanged, an anchor in a corner keeps that corner put and grows the opposite one - the behaviour a transform's scale gizmo needs, so the box agrees with a render that scales about the same anchor.

```glsl
// #point label="Anchor" osc=point square default="0.5,0.5"
uniform vec2 uAnchor;

// #multi percent label="Scale" fields={X,Y} lockaspect osc=box
//   link="uPosition + uAnchor - vec2(0.5)" anchor=uAnchor
//   min={1,1} max={800,800} default="100,100"
uniform vec2 uScale;
```

`link=` places the box's pivot; `anchor=` decides which way it grows from there. They are usually used together on a transform: the pivot is where the render scales from, and the anchor is where inside the content that pivot sits.

### Rotation: `osc={...}`

The braces list the axes AND their order, and **the Nth listed axis drives value component N**:

- `#angle ... osc={z}` on a `uniform float` -> one Z ring; the float is the Z angle.
- `#multi ... osc={y,x}` on a `uniform vec2` -> `value.x` is the Y-axis angle, `value.y` is the X-axis angle.
- `#multi ... osc={z,x,y}` on a `uniform vec3` -> `value` is (Z, X, Y) angles.

Each axis angle reaches the shader as **radians, negated** (a clockwise ring reads as a clockwise turn), so a `#multi` rotation vector is ready to drop into rotation matrices. Rings are tinted X=red, Y=green, Z=blue (matching the inspector dials), and the drag composes per-axis (Cmd snaps to 15°).

### Placing the control: `center=` and `link=`

`osc=ring`, `osc=box` and `osc={...}` sit at the clip centre by default. Move them with:

- `center=0.3,0.7` - a fixed object-space point (0..1, origin bottom-left).
- `link=uPivot` - centre tracks another `#point` uniform's **live value**, so the control follows a draggable point. Useful for centring a ring / rotation on a position handle.

(`#point` handles sit at their own value, so they don't take `center=` / `link=`.)

### Glyph style

A handle draws as a filled dot by default. Add a bare style word beside the `osc=` to change it:

| word     | glyph                                     |
| -------- | ----------------------------------------- |
| `dot`    | filled dot (the default)                  |
| `square` | filled square - reads as a pivot / anchor |
| `hollow` | small hollow ring                         |
| `arc`    | arc handle, like a position control's     |

```glsl
// #point label="Anchor" osc=point square default="0.5,0.5"
uniform vec2 uAnchor;
```

It is the sugar for an authored block's `style =`, so the same words mean the same thing in both forms. Word order does not matter and it composes with the other bare flags (`osc=point square skipsnapping`). Style words are only read outside quotes, so a `label="Square Frame"` is safe.

### Snapping

Point and position handles snap while dragging: hold **Cmd** and the handle snaps to the canvas centre / edges / quarters and onto the other point/position handles (with guides - yellow for the canvas, the accent colour for another handle). It is on by default; add **`skipsnapping`** to opt a handle out (`osc=point skipsnapping`, or on a bare `osc` / `osc=position`).

### Hiding OSCs

Every declared OSC is a hideable element in the viewer's On-Screen Controls settings (Option-click a control to hide it; Option-hold reveals hidden ones as dimmed ghosts). A rotation gizmo is one group with per-axis X/Y/Z children, each hideable on its own.

## Worked example

```glsl
// A pivot the rotation + a ring both follow.
// #point label="Pivot" osc default="0.5,0.5"
uniform vec2 uPivot;

// A vec3 of euler angles, driven by 3 rotation rings centred on the pivot.
// #multi fields={Yaw,Pitch,Roll} osc={z,x,y} link=uPivot label="Orient"
uniform vec3 uOrient;

// A scalar radius, shown as a draggable circle centred on the pivot.
// #float label="Radius" min=0 max=1 default=0.3 osc=ring link=uPivot
uniform float uRadius;

// A palette of up to 5 colours; the hex list seeds three swatches (users can
// add up to 5 and reroll them with the built-in palette generator).
// #color max=5 default="#1B1035,#5B2A8C,#E86BFF"
uniform vec4 uPalette[5];

void mainImage(out vec4 O, in vec2 I) {
  // uOrient is (Z,X,Y) in radians; uRadius in 0..1; uPivot in pixels; ...
}
```

## Tips

- Reach for an OSC when a value is spatial (a position, a size, an angle) - it's faster than typing and reads at a glance. Keep purely numeric knobs as plain `#float` / `#int` sliders.
- `#percent` is the friendliest way to expose a 0..1 factor: the artist sees 0-100%, the shader gets 0..1.
- Editing a directive live re-derives the control set (and its OSCs) without a clip reselect - add / rename / re-`osc` a uniform and the inspector + viewer update on the next commit.
