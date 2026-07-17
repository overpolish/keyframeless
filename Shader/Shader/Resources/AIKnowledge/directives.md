---
id: directives
summary: Declaring inspector controls and on-screen controls in a Custom shader with // # directives
---

# Custom controls: `// #` directives

A Custom shader can expose its own **inspector controls** and **on-screen controls (OSCs)** by annotating its uniforms. Put a `// #<kind>` comment on the line **before** a `uniform` declaration, and Shader builds a matching, fully keyframeable timeline lane for it. The uniform's value then comes from that lane (and its keyposes / OSC) instead of being a fixed constant.

```glsl
// #float label="Amount" min=0 max=2 default=0.5
uniform float uAmount;
```

That one pair adds an animatable **Amount** slider (0-2, default 0.5) to the inspector, and inside the shader `uAmount` reads the live value. Everything a built-in property can do - keyposes, easing, Basic/Advanced timing, motion blur - works on a declared control automatically.

**Rules that always hold:**

- The directive comment must be immediately above the `uniform` line (only blank lines between them; the next directive ends the search).
- The **uniform name is the identity** of the control (its keyframes follow the name). `label=` is display-only - renaming the label keeps the animation; renaming the uniform starts a fresh control.
- Each control needs a **unique uniform name and a unique label** - duplicates are a compile error surfaced in the editor.
- These directives only apply to the **Custom** type (the whole shader system is Custom-only). See the custom-shader doc for the shader language itself.

## Control kinds

| Directive  | Uniform type       | Inspector control         | What the shader receives                            |
| ---------- | ------------------ | ------------------------- | --------------------------------------------------- |
| `#color`   | `vec4 n;`          | colour swatch             | `vec4` RGBA (from the Colours-style swatch)         |
| `#color`   | `vec4 n[N];`       | palette bar (up to N)     | `vec4 n[N]` + `nCount` (int) active count           |
| `#float`   | `float n;`         | slider                    | the raw value                                       |
| `#percent` | `float n;`         | slider shown as `%`       | **0..1** (the inspector shows 0-100%)               |
| `#int`     | `float n;`         | integer slider            | `int`                                               |
| `#seed`    | `float n;`         | dice/seed field (no anim) | the raw integer value                               |
| `#angle`   | `float n;`         | rotation dial (degrees)   | **radians, negated** (`radians(-deg)`)              |
| `#bool`    | `bool n;`          | checkbox                  | `bool`                                              |
| `#choice`  | `int n;`           | segmented pills           | `int` selected index (0-based)                      |
| `#point`   | `vec2 n;`          | 2D point                  | pixels (`value * iResolution.xy`, fragCoord space)  |
| `#multi`   | `vec2` / `vec3 n;` | N-component field         | the raw vector                                      |
| `#audio`   | `vec4 n[N];`       | audio source picker       | live spectrum via `nBand(i)` + `nBands` (see below) |

The uniform TYPE is folded away by the compiler - you use `uAmount` directly as a `float`, `uColor` as a `vec4`, etc. A mistyped uniform type is tolerated (the `#`-kind wins), so `#int` over a `uniform float` still delivers an int.

### Common attributes

- `label="Nice Name"` - inspector display name (defaults to a prettified uniform name: `uCornerRadius` -> "Corner Radius").
- `min=` / `max=` - value range. Omit `max=` to leave the field unbounded (the slider still uses a nominal cap).
- `default=` - starting value. `#point` / `#multi` take `default="x,y"` / `default="a,b,c"`.
- `#choice` adds `options="One,Two,Three"` (the pill labels; `default=` is the 0-based index) and `dropdown` (see below).
- `#multi` adds `fields={Width,Height}` (names + counts the components) and `lockaspect` (components aspect-linked, ratio preserved on an OSC drag).

### `#choice` as a dropdown

A `#choice` is segmented pills by default: every option on screen, one click to switch. Add `dropdown` when that stops being a good deal.

```glsl
// #choice label="Style" options="Bars,Spikes,Dots,Ring,Comet" default=0 dropdown
uniform int uStyle;
```

The row then shows the current pick and expands a searchable list in place. It's the right call when the options are **many** (past a handful the pills wrap into a wall that pushes the rest of the panel down) or **long-worded**. Keep the pills for a short set - a dropdown hides the options behind a click and makes comparing them slower.

It's opt-in rather than automatic on a count, because a control that changed shape at the 6th option would surprise you more than either default.

### `#audio` is the odd one out

Every other directive builds a keyframeable lane whose value you set. `#audio` doesn't: its lane is a **picker** listing the audio a user has published from Sonar, and the value arrives from that audio, frame by frame.

```glsl
// #audio label="Music"
uniform vec4 uMusic[16];
```

Read it with the generated `uMusicBand(i)` (band `i`, roughly `0...1`, low frequency first) and `uMusicBands` (how many there are, 4 per `vec4`), never by indexing the `vec4` packing by hand. Two per shader, up to 24 `vec4`s each.

One `#audio` builds an **Audio** group of four lanes, not one control: the source picker, plus animatable **Noise Gate** (dB), **Release** (seconds, how long a band takes to fall to zero once gated) and **Smoothness** (seconds) lanes. The directive takes `label=`, and `gate=` / `release=` / `smooth=` to seed those three - they're starting values, not settings, since the right gate depends on the mix rather than on the shader.

Nothing picked reads as silence rather than an error, so a shader with an unbound `#audio` still renders.

A binding also survives leaving the Mac it was made on. Published audio doesn't travel inside a project, so one opened elsewhere can't find what it's bound to - the picker keeps naming it, greyed out, under a **Republish required** warning, and the user gets it back by dropping the project on Sonar (the clips are already selected) and pressing Publish. Nothing needs re-pointing. Shader authors don't have to do anything for this: it's the picker's job, not the shader's, and no directive attribute affects it.

See `audio-shader-directive` for shaping the levels into something that looks good, and `audio-sonar` for how a user publishes the audio in the first place, including the walkthrough for that warning.

## On-screen controls (`osc`)

Add `osc` (or `osc=<kind>`) to a directive to also draw a **draggable control on the viewer and mini-viewer**. The control edits the same lane, so dragging is just another way to keyframe the value.

| `osc` value         | Valid on                                                   | On-screen control                                       |
| ------------------- | ---------------------------------------------------------- | ------------------------------------------------------- |
| `osc` / `osc=point` | `#point` (vec2)                                            | a position handle at the point                          |
| `osc=ring`          | `#float` / `#percent` / `#int`, or 2-field `#multi` (vec2) | a radius **ellipse**; drag its edge to set the value(s) |
| `osc=box`           | same as `osc=ring`                                         | a **rectangle** with 8 handles + a value readout        |
| `osc={z}`           | `#angle` (float)                                           | a single **rotation ring** on the Z axis                |
| `osc={y,x}`         | 2-field `#multi` (vec2)                                    | two rotation rings (Y and X axes)                       |
| `osc={z,x,y}`       | 3-field `#multi` (vec3)                                    | three rotation rings (Z, X, Y axes)                     |

A bare `osc` on `#point` defaults to a point handle; a bare `osc` on `#angle` defaults to a single-axis (Z) rotation ring.

### Ring vs box

`osc=ring` and `osc=box` are the same control in two shapes - both size the value across `[min, max]`. A single-value field is a circle / square; a 2-field `#multi` (vec2) is an ellipse / rectangle with an independent radius per component. Drag a handle to resize; with `lockaspect` on the `#multi`, the ratio is held (Shift inverts the lock; Cmd = fine drag). The box also shows a readout in the field's units (e.g. `40%`, `5`, `0.4 x 0.2`).

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

// A palette of up to 5 colours (built-in palette generator + swatches).
// #color min=1 max=5 default=3
uniform vec4 uPalette[5];

void mainImage(out vec4 O, in vec2 I) {
  // uOrient is (Z,X,Y) in radians; uRadius in 0..1; uPivot in pixels; ...
}
```

## Tips

- Reach for an OSC when a value is spatial (a position, a size, an angle) - it's faster than typing and reads at a glance. Keep purely numeric knobs as plain `#float` / `#int` sliders.
- `#percent` is the friendliest way to expose a 0..1 factor: the artist sees 0-100%, the shader gets 0..1.
- Editing a directive live re-derives the control set (and its OSCs) without a clip reselect - add / rename / re-`osc` a uniform and the inspector + viewer update on the next commit.
