---
id: directives
summary: Declaring inspector controls and on-screen controls in a Custom shader with // # directives
---

# Custom controls: `// #` directives

A Custom shader can expose its own **inspector controls** and **on-screen controls (OSCs)** by annotating its uniforms. Put a `// #<kind>` comment on the line **before** a `uniform` declaration, and Mirage builds a matching, fully keyframeable timeline lane for it. The uniform's value then comes from that lane (and its keyposes / OSC) instead of being a fixed constant.

- **Value controls:** `#float` / `#percent` / `#int` (sliders), `#bool` (switch), `#choice` (a menu, pill, or multi-select checklist), `#angle` (a dial), `#color` (a colour well), `#gradient` (a colour ramp), `#multi` (2-4 numbers), `#random` (a dice field).
- **Spatial controls:** `#point` (a draggable position handle). Add `osc` to a value control for an on-screen ring, box, or rotation ring that edits the same lane.
- **Reactive:** `#audio` binds a Sonar-published spectrum; `#progress` hands the user a transition's sweep curve (the sweep itself is the built-in `iProgress`, no directive needed); `#frames` delivers the source clip at other frames; `#easing` picks which curve a transition's shared Easing menu starts on.
- **Grading:** `#color-surface` opts the shader into the inspector's Color panel - a scope you can drag - and `surface=` maps a control onto its puck.
- **Repeatable:** `#slots` ... `#slots-end` wraps a group of controls the user adds and removes copies of, numbered with `{n}`.
- **Template type:** every Image shader requires exactly one `#template generator|filter|layout|transition|color-transform` directive.
- **Built-ins:** `#speed`, `#seed`, `#grain` opt into engine controls and stand alone (no uniform).
- Attributes tune each one: `label=`, `min=` / `max=`, `default=`, `group=` (which inspector group it lands in), and `osc=` place the on-screen control. The rest of this doc details every kind.

```glsl
// #float label="Amount" min=0 max=2 default=0.5
uniform float uAmount;
```

That one pair adds an animatable **Amount** slider (0-2, default 0.5) to the inspector, and inside the shader `uAmount` reads the live value. Everything a built-in property can do - keyposes, easing, Basic/Advanced timing, motion blur - works on a declared control automatically.

**Rules that always hold:**

- The Image shader must contain exactly one standalone template declaration: `// #template generator`, `filter`, `layout`, `transition`, or `color-transform`. This drives browser classification and runtime input behavior.
- The directive comment must be immediately above the `uniform` line (only blank lines between them; the next directive ends the search). The whole-shader directives (`#speed` / `#seed` / `#grain` / `#template` / `#alpha` / `#motionblur` / `#frames` / `#easing` / `#color-surface` / `#slots` / `#slots-end`) are the exception: they annotate nothing and stand on their own line.
- The **uniform name is the identity** of the control (its keyframes follow the name). `label=` is display-only - renaming the label keeps the animation; renaming the uniform starts a fresh control.
- Each control needs a **unique uniform name** - a duplicate uniform is a compile error surfaced in the editor. Labels may repeat freely (two controls can both show "Size"); the uniform is the identity, the label is just what the rows display.
- These directives only apply to the **Custom** type (the whole shader system is Custom-only). See the custom-shader doc for the shader language itself.

### Multi-tab interchange: `// #tab`

A multi-pass template lives in several editor tabs (Image, Common, Buffer A-D), but an assistant answers in one block of text. `// #tab <name>` on a line of its own is how that one block says where each part goes:

```glsl
// #tab common
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
// #tab image
void mainImage(out vec4 O, in vec2 I) { O = vec4(hash(I), 0.0, 0.0, 1.0); }
```

Paste that into the code editor and it lands in the right tabs, marker lines stripped. The rules:

- Names resolve loosely: `image`, `common`, `buffer-a`, `Buffer A` and `BUFFER_A` all name the same tab, since only letters and digits are compared.
- A named tab is **replaced whole**. A tab the blob never names keeps what it had, so a paste of just `// #tab image` leaves your buffers alone.
- A named tab the template does not have yet is **created**, as long as it is one the **+** menu offers.
- Text before the first marker belongs to the **Image** tab, so a single-pass shader needs no marker at all and pastes exactly as it always did.
- If any marker names something that is not a tab (`// #tab buffer-e`), the whole paste is treated as ordinary text and drops at the cursor. Nothing is ever silently discarded.
- Blank space around each section is trimmed, so two markers with nothing between them give an empty tab.

`// #tab` is **not a directive**. It never reaches the shader compiler or the directive parser, because it only exists between the marker being pasted and the text reaching a tab. Option-clicking **Copy Schema** exports the current template in exactly this format, so what the assistant reads is what it should write back.

### Slider range vs field range

`min=` and `max=` are the values the control will **accept**. `slidermin=` and `slidermax=` move the ends of the **slider** without touching them, so the handle spans the range the control is actually used in while the field still takes a typed value out past it:

```glsl
// #float label="Amount" min=0 max=300 slidermax=100 default=25
uniform float uAmount;
```

The slider covers 0 to 100, where nearly every useful setting lives, and 250 is still reachable by typing it. Without the override a hard `max=300` spends two thirds of the handle's travel on values nobody drags to, and lowering the max to 100 instead takes the extreme away entirely.

- Either may be given on its own. The end that is not overridden keeps its `min=` / `max=` bound.
- On a control with no bound at all the slider uses the nominal range its kind gets, so `slidermax=` is also how an unbounded field gets a handle worth dragging.
- Honoured by `#float`, `#percent`, `#int` and `#multi`. `#progress` ignores them for the same reason it ignores `min=` / `max=`: 0 to 100% is what progress means.
- They are display only. Nothing about the stored value, the keyframes, or what the shader receives changes.

### Units: `units=`

`units=` says what the number **means**, and shows next to the field. Two spellings also carry behaviour; every other spelling is a label and nothing else:

| `units=`               | What it does                                                                                                                                                                                                                          |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `"px"`                 | Pixels. On a single-value control the stored value **is** a pixel count (whole numbers), rescaled with the render so a proxy or half-res render matches. On a `#multi` component it is a 0..1 fraction of the frame, shown in pixels. |
| `"%"` (or `"percent"`) | The field shows `%` and takes whole numbers. It does **not** divide - the shader gets what the field shows. Use the `#percent` kind (or `#multi percent`) when you want 0..1 in the shader.                                           |
| anything else          | A **display suffix**: `stops`, `dB/oct`, `°`, `×`, `/s`, whatever fits. Nothing is rounded, scaled or divided - the shader receives exactly the value it would with no `units=` at all.                                               |

```glsl
// #float label="Exposure" units="stops" min=-5 max=5 default=0
uniform float uExposure;

// #float label="Hue Rotate" units="°" min=-180 max=180 default=0
uniform float uHueRotate;
```

A `#multi` takes one per component in a braced list, and an empty slot leaves that component unitless:

```glsl
// #multi label="Offset" fields={X,Y} units={px,°}
uniform vec2 uOffset;
```

A rotate OSC labels each of its dials in degrees already, so a `units="°"` beside one is ignored rather than doubled. A plain `#angle` has no suffix of its own, so `units="°"` there does add one.

### Reactive maximums

A single-value numeric lane can make its effective upper bound follow another lane with `maxby=` and `maxvalues={}`:

```glsl
// #choice label="Grid" options="2 × 2,3 × 2,3 × 3" default=0
uniform int uGrid;

// #int label="Cell" min=1 max=9 default=1 maxby=uGrid maxvalues={4,6,9}
uniform float uCell;
```

The rounded value of `uGrid` indexes `maxvalues`, so Cell is capped at 4, 6 or 9. `max=` remains the stable authored/storage range: lowering the reactive cap clamps the editor, OSC and value sent to the shader; it does not overwrite a larger stored or keyframed value. If the controller is absent or outside the `maxvalues` list, the static `max=` applies. `maxvalues` must be a non-empty comma-separated list of numbers and may contain at most 32 entries.

### Conditional controls

A scalar control can appear only for selected values of another scalar control with `visibleby=` and `visiblevalues={}`:

```glsl
// #choice label="Style" options="Wave,Bars,Needles" default=0
uniform int uStyle;

// #percent label="Bar Width" visibleby=uStyle visiblevalues={1,2} default=70
uniform float uBarWidth;
```

Values are compared after rounding, matching choice indices and integer controls. Both attributes must be present. The controller is identified by its uniform name, and `visiblevalues` accepts up to 32 comma-separated numbers.

## Control kinds

| Directive        | Uniform type       | Inspector control                                | What the shader receives                                                                             |
| ---------------- | ------------------ | ------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `#color`         | `vec4 n;`          | colour swatch                                    | `vec4` RGBA (from the Colours-style swatch)                                                          |
| `#color`         | `vec4 n[N];`       | palette bar (up to N)                            | `vec4 n[N]` + `nCount` (int) active count                                                            |
| `#gradient`      | `vec4 n[N];`       | gradient bar (stops up to N)                     | `nAt(t)` → `vec3` at position t; `nStops` (int) live stop count                                      |
| `#float`         | `float n;`         | slider                                           | the raw value                                                                                        |
| `#percent`       | `float n;`         | slider shown as `%`                              | **0..1** (the inspector shows 0-100%)                                                                |
| `#progress`      | `float n;`         | slider shown as `%`, keyframed 0→100% by default | **0..1** - OPT-IN reshapeable sweep; the sweep itself is the built-in `iProgress`, see below         |
| `#int`           | `float n;`         | integer slider                                   | `int`                                                                                                |
| `#random`        | `float n;`         | dice/seed field (no anim)                        | the raw integer value                                                                                |
| `#angle`         | `float n;`         | rotation dial (whole degrees)                    | **radians, negated** (`radians(-deg)`)                                                               |
| `#bool`          | `bool n;`          | checkbox                                         | `bool`                                                                                               |
| `#choice`        | `int n;`           | pills or dropdown; `multiple` makes a checklist  | selected index, or an option bitmask with `multiple`                                                 |
| `#point`         | `vec2 n;`          | 2D point                                         | pixels (`value * iResolution.xy`, fragCoord space)                                                   |
| `#multi`         | `vec2` / `vec3 n;` | N-component field                                | the raw vector                                                                                       |
| `#audio`         | `vec4 n[N];`       | audio source picker                              | spectrum `nBand(i)`; optional `flow` and `waveform=N` helpers (see below)                            |
| `#speed`         | _(none)_           | Speed slider                                     | nothing directly - scales `iTime`                                                                    |
| `#seed`          | _(none)_           | Seed field                                       | nothing directly - offsets `iTime`                                                                   |
| `#grain`         | _(none)_           | Grain + Grain Size                               | nothing directly - grain is overlaid on the output                                                   |
| `#template`      | _(none)_           | no separate control                              | declares `generator`, `filter`, `layout`, or `transition`; transition adds the shared coverage pills |
| `#color-surface` | _(none)_           | the Color panel (a draggable scope)              | nothing directly - controls opt in with `surface=`                                                   |
| `#frames`        | _(none)_           | no separate control                              | the source clip at other frames: `iNeighborAt(i, uv)`, `iNeighborCount`, `iNeighborOffset(i)`        |
| `#easing`        | _(none)_           | no separate control                              | which curve a transition's shared Easing menu starts on                                              |
| `#slots`         | _(none)_           | repeats the controls it wraps, per instance      | each uniform inside becomes `[max]`, plus an injected `u<Name>Count`                                 |

The uniform TYPE is folded away by the compiler - you use `uAmount` directly as a `float`, `uColor` as a `vec4`, etc. A mistyped uniform type is tolerated (the `#`-kind wins), so `#int` over a `uniform float` still delivers an int.

### `#bool` defaults

A switch starts **off** unless its directive says otherwise. `default=` accepts `true` / `false`, `yes` / `no`, `on` / `off`, and `1` / `0`, in any capitalisation:

```glsl
// #bool label="Preserve Brightness" default=true
uniform bool uPreserveLuma;
```

Anything else - `default=maybe` - is a compile error rather than a quiet off, because a switch that reads as on in the source and renders as off is the hardest kind of bug to see.

## Groups

Every control lands in an inspector **group**. Without `group=` a control goes to **Options**. Name a group and the control moves there, creating it if it's the first to ask:

```glsl
// #float label="Glow" group="Glow Options" min=0 max=1
uniform float uGlow;

// #percent label="Falloff" group={"Glow Options", "sparkles"}
uniform float uFalloff;
```

Both forms are accepted: `group="Name"` on its own, or `group={"Name", "sf.symbol"}` to give the group an icon. The icon only has to be named **once** per group - any other control joining the group inherits it, so the short form is fine everywhere else. The symbol is any SF Symbol name macOS knows (the editor offers a curated list and flags a name that doesn't resolve).

`#color` takes `group=` on the same grammar, so a swatch can sit with the controls it belongs to instead of in the shared **Colors** group:

```glsl
// #color label="Sky" group={"Sky", "cloud"}
uniform vec4 uSky;

// #color label="Ramp" group="Sky" min=1 max=4 default=2
uniform vec4 uRamp[4];
```

A colour **array** moves whole - its count lane and every swatch land in the named group together. A `#color` with no `group=` stays in **Colors** exactly as before. `#audio` and `#gradient` still have dedicated groups of their own and reject `group=` as a compile error.

### Multiple-choice dropdowns

`#choice` is pick-one by default. Add both `dropdown` and `multiple` to turn it into a searchable checklist:

```glsl
// #choice label="Patterns" options="Grid,Dots,Rings,Crosses" dropdown multiple default="Grid,Dots"
uniform int uPatterns;
```

The shader receives an integer bitmask: option 0 is bit 0, option 1 is bit 1, and so on. Test a selection with `(uPatterns & (1 << index)) != 0`. `default="..."` names one or more option labels separated by commas; a numeric `default=` may provide the bitmask directly. The checklist stays open while the user toggles options. Multiple choices support at most 24 options because lane values pass through an exactly representable float.

A colour array can map one-to-one onto a multiple-choice checklist with `optionsby=`:

```glsl
// #choice label="Patterns" options="Grid,Dots,Rings" dropdown multiple default="Grid,Dots"
uniform int uPatterns;

// #color optionsby=uPatterns default="#333333,#B3523A,#4E7F86"
uniform vec4 uPatternColours[3];
```

The Colors group shows “Grid Colour”, “Dots Colour” and “Rings Colour” only while their corresponding options are enabled. Array slot order always matches option order, and no colour-count control is added. `optionsby` requires a `multiple` choice and exactly one array slot per option.

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
- `#grain` adds **two** lanes, the amount and its cell size. `default=` seeds the amount (a percentage), `size=` the cell size in pixels. `label=`, `min=` and `max=` all apply to the **amount only**, which is the lane the directive is named for. Leave the bounds out and the amount runs 0 to 100%. The size lane keeps its own 1 to 12 px range and is not authorable.
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

### `iProgress` (transitions) and the optional `#progress` lane

**`iProgress` is how a transition reads its sweep.** It is built in, always available, needs no declaration, and advances by itself over the item: the clip fraction, `0` at the effect's first frame and `1` at its last, paced by the user's Easing choice (Linear by default, which is the identity). In a Motion transition template that window IS the transition, so `iProgress` is the GL Transitions `progress`:

```glsl
void mainImage(out vec4 O, in vec2 fc)
{
    vec2 uv = fc / iResolution.xy;
    O = mixTransitionColors(texture(iChannel0, uv), texture(iChannel1, uv), iProgress);
}
```

`mixTransitionColors` is injected, not declared. See **Injected helpers** below.

Write a transition against `iProgress` unless you have a reason not to. A transition's own SIGNATURE curve - a whip's cubic ratio, a card flip's snap - belongs baked into the shader, applied to `iProgress`, because that curve is the effect's look. A plain ease is not: the user has a menu for that.

#### The Easing lane

Every `// #template transition` gets a non-animatable **Easing** menu alongside the Transition / In / Out pill, with no code at all. Its curves are the timing engine's own - the same set the timeline's segment editor offers:

**Linear** (the identity), **Ease In**, **Ease Out**, **Ease In/Out**, **Elastic**, **Bounce**.

The chosen curve is applied HOST-SIDE, to the clip fraction, before it becomes `iProgress`. The shader sees only the eased value, so a baked signature curve composes on top of the user's choice rather than fighting it. `iTime` is never eased: Speed and Seed pace the shader's motion, Easing paces the cut, and every curve still lands exactly on `1.0` at the edit.

A template that has always looked eased says so, and stops baking it:

```glsl
// #template transition
// #easing default="ease-in-out"
```

`default=` takes `linear`, `ease-in`, `ease-out`, `ease-in-out`, `elastic` or `bounce` (separators and case are ignored, so `Ease In/Out` as the menu spells it also works). It moves only where the menu STARTS - the user still picks any curve. Declare nothing and the menu starts on Linear, which renders exactly the raw clip fraction. Only one `#easing` line per Image shader, and an unknown curve name is an error rather than a silent fallback.

`// #progress` is a separate, **opt-in** feature: it adds a user-reshapeable Progress lane on the timing engine.

```glsl
// #progress label="Progress"
uniform float uProgress;
```

Unlike every other directive, its lane defaults to a **ramp** rather than a constant: 0% at the start, 100% at the end, linear. Left untouched it evaluates to exactly what `iProgress` does, so declaring it changes nothing on its own. What it adds is the lane - the user can ease it, move the keyposes, or reshape it entirely, which is something the upstream GL Transitions spec (linear only) can't express.

The two reshapers COMPOSE, in a stated order: **Easing paces the sweep, the lane shapes it.** The eased fraction is the clock, and the Progress lane is read at the moment that clock has reached - `lane(ease(t))`. That is what keeps the directive's contract true: an untouched Progress lane still evaluates to exactly `iProgress`, whichever curve the Easing menu is on.

So: `iProgress` is the default and the fallback; declare `#progress` only when handing the user the pacing curve is a feature of that particular transition. Declaring it is not a substitute for shaping the sweep yourself. Note the uniform receives **0..1** even though the inspector shows 0-100%, matching `#percent`.

### `#template` and shader behavior

Every Image shader declares what it is:

```glsl
// #template generator
```

- **generator** draws its own image. It may still use `#audio`.
- **filter** processes the source clip on `iChannel0`.
- **layout** places or masks its source, normally with `#alpha`.
- **transition** receives outgoing/incoming clips on `iChannel0`/`iChannel1` and gets a non-animatable **Transition / In / Out** pill:

- **Transition** binds the outgoing clip to `iChannel0` and incoming clip to `iChannel1`.
- **In** binds transparent black to `iChannel0`, allowing the incoming clip to appear over the timeline beneath it.
- **Out** binds transparent black to `iChannel1`, allowing the outgoing clip to disappear into the timeline beneath it.

  It also gets the shared **Easing** menu, which paces `iProgress` (see above). `// #easing default="..."` picks where that menu starts.

- **color-transform** converts a declared camera or display encoding into a practical output space. The shipped **Color Transform** is standalone and shader-backed, so its transformed pixels flow normally into effects stacked after it. A `color-transform` shader consumes and produces the host's LINEAR values on a float destination: the ordinary Shadertoy gamma round-trip is skipped on both the source and the output so log curves and wide-gamut linear values survive. Both of its menus therefore name a real space rather than offering an "unknown" entry, because a transform cannot start from an undeclared origin. An ordinary colour-managed SDR clip arrives as `Linear Rec.709`, which is the default on both sides and an exact identity. To bypass the transform, set Mix to 0.

  Its input menu covers the three linear host spaces (Rec.709, Display P3, Rec.2020), the encoded display spaces (sRGB, Rec.709, Display P3, Rec.2020 HLG, Rec.2020 PQ), the ACES spaces (ACES2065-1, ACEScg, ACEScct) and sixteen camera log spaces (Apple, ARRI LogC3/LogC4, Blackmagic Film Gen 5, Canon C-Log2/C-Log3, DaVinci Intermediate, DJI D-Log, Fujifilm F-Log/F-Log2, Nikon N-Log, Panasonic V-Log, RED Log3G10, Sony S-Log2 and S-Log3 in both S-Gamut3 and S-Gamut3.Cine). Every **output** is a linear space (Linear Rec.709, Linear Display P3, Linear Rec.2020, ACEScg, ACES2065-1) because Final Cut owns the display encode: emitting HLG or PQ code values from a shader would encode twice, so HDR delivery is a transform to Linear Rec.2020 and then the project's own output. The HDR inputs place BT.2408 diffuse white (PQ 203 nits, HLG signal 0.75) at 1.0 so an HDR and an SDR clip agree on where white is, with specular highlights above 1.0. HLG receives its inverse OETF only, since the OOTF is display rendering rather than a technical transform.

FxPlug does not report whether a transition side is genuinely absent, so the coverage choice is intentionally explicit. The empty side is a real transparent texture, not an unbound channel (whose normal Mirage fallback is procedural noise).

Transition shaders can read `iTransitionMode` (`0` = Transition, `1` = In, `2` = Out) when an intentional background or source-specific embellishment must behave differently for a transparent endpoint. For ordinary blends, call the injected `mixTransitionColors`; a raw `mix` darkens an image twice when its colour and alpha fade together.

### `#motionblur` (who owns the blur)

The user's **Motion Blur** popover (on/off, shutter, samples) is separate from any directive. `// #motionblur <mode>` (on its own line, no uniform) only decides **who applies** those settings. Absent, the default is `accumulate`.

- **`accumulate`** (default): the plugin re-renders the shader at N sub-frame times across the shutter and averages them. Correct for any ordinary animated shader with **nothing to declare** - it just works. Multi-pass is fine: a buffer chain that only reads earlier buffers is a pure function of the current uniforms, so it is encoded ONCE and each sample re-runs only the Image pass. That makes a buffer the right home for an expensive precompute (a source blur, say) - inline, it would be recomputed inside every sample. A **feedback** chain (a buffer reading itself or a later buffer) is the exception: its state depends on history, so it can't be shared across samples and validation asks you to declare `native` or `off` instead. (For when a feedback chain is the right way to depend on history at all, see "Feedback or `#frames`" below.)
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

### Feedback or `#frames`: picking the temporal tool

Mirage has two ways to make an effect depend on time rather than only on the current frame, and they are not interchangeable. **Feedback remembers, `#frames` looks.** Ask one question: can the history be summarised as running state, or does the shader need to look at specific other frames? Running state is feedback (a buffer reading itself, or reading a later buffer). Specific frames are `#frames`.

**Feedback costs one extra pass, flat**, no matter what the shader sits on: the state texture is already there from last frame, so nothing beneath the shader is re-rendered to produce it. Its temporal reach is **unbounded** - a decaying accumulator draws on seconds of history for the same per-frame cost as one that decays in three frames. What it does not have is **random access**: individual past frames only exist blended into the state, so there is no way to ask what the picture looked like exactly 7 frames ago. Distinct true delayed frames can be built as a buffer delay line (each buffer passing its content to the next), but that caps at about 3, which is the buffer budget. Scrub determinism reconstructs feedback state through checkpoints with a 90-frame window, so sequential playback is exact and a seek may settle a very long tail slightly differently.

**`#frames` looks at real frames**, and pays per look - see the cost section below for what a look costs where.

| Reach for feedback                                                   | Reach for `#frames`                                       |
| -------------------------------------------------------------------- | --------------------------------------------------------- |
| Trails, echo, ghosting, light streaks, long exposure                 | Anything that sees the **future** (feedback never can)    |
| Warp accumulation (each frame displaced a little further)            | True frame blending at exact taps                         |
| Simulations: reaction-diffusion, fluid, particles, cellular automata | Motion-compensated temporal comparison of real neighbours |
| Running temporal averages                                            | Frame difference / time displacement between real frames  |
| Motion-energy buildup                                                | Freeze or hold of one specific offset                     |

#### Worked example: motion-gated trails with no `#frames` at all

A trail that only builds where the picture is actually moving needs the previous **source** frame, which sounds like `#frames offsets="-1"`. Feedback gives it for free instead. Skip Buffer A so `iChannel0` stays the source. **Buffer C** is a one-line passthrough that stores the current source. **Buffer B** is the accumulator: it reads ITSELF on `iChannel1` (its own previous frame) and reads Buffer C on `iChannel2` - a LATER buffer, so also a previous frame, which is exactly the previous source. That is a true previous-frame motion mask with zero frame requests.

Buffer B, the core of it (`uv` is `fragCoord / iResolution.xy`):

```glsl
vec3 src = texture(iChannel0, uv).rgb;
vec4 history = texture(iChannel1, uv);        // this buffer, one frame ago
vec3 prevSrc = texture(iChannel2, uv).rgb;    // Buffer C, one frame ago
float motion = clamp(dot(abs(src - prevSrc), vec3(1.0)) * 8.0, 0.0, 1.0);
vec3 prevTrail = (abs(history.a - 0.8125) < 0.01) ? history.rgb * 0.9 : vec3(0.0);
fragColor = vec4(max(prevTrail, src * motion), 0.8125);
```

Buffer C:

```glsl
fragColor = texture(iChannel0, fragCoord / iResolution.xy);
```

The Image pass then composites `texture(iChannel1, uv)` (Buffer B) over the source.

The `0.8125` is an **alpha signature**: on the very first frame the history texture holds whatever was in memory, and reading it as a trail flashes garbage. Writing a known constant into alpha and testing for it means the accumulator only trusts history it wrote itself, and starts from black otherwise. Pick a value that survives the round trip exactly.

### `#frames` (reading other frames)

`iChannel0` is the source clip at the current frame, and nothing else. `// #frames` asks Final Cut for the clip at **other** frames too, so a shader can compare, blend or trail across time. It stands alone on its own line and binds no uniform, like `#template` and `#motionblur`.

```glsl
// #frames offsets="-1,-2,-3,-4"
```

**Units.** Each offset is a signed count of **whole frames** relative to the frame being rendered, resolved against the clip's own frame duration. `-1` is the previous frame, `+2` is two frames ahead. There is no seconds form: temporal effects reason in frames, and a fractional offset would land between the frames Final Cut can actually deliver.

**What the shader gets:**

- **`iNeighborAt(i, uv)`** returns the source clip at the `i`-th declared offset, sampled at `uv`. This is the accessor to reach for. A GLSL sampler array cannot be indexed by a loop variable, so an indexed accessor is what lets a trail loop over the frames.
- **`iNeighborCount`** is how many offsets were declared, as a compile-time constant, so `for (int i = 0; i < iNeighborCount; i++)` is a bounded loop.
- **`iNeighborOffset(i)`** gives the `i`-th offset back in whole frames, for a shader whose weighting depends on the distance in time rather than on the slot number.
- **`iNeighbor0`, `iNeighbor1`, ...** are the underlying samplers, if you would rather write `texture(iNeighbor0, uv)` directly. Note that `iFrame` is unrelated: that is still the frame **counter**.

**Binding order is declaration order.** `offsets="-1,+3,-2"` binds `iNeighbor0` to one frame back, `iNeighbor1` to three frames forward and `iNeighbor2` to two frames back. The list is never sorted, so what you write is what you index.

**Rules the editor enforces:**

- **At most 8 offsets.** Each one is a full-resolution texture held for the frame, so this is a memory budget rather than a binding limit.
- **Offset `0` is rejected.** That frame is already `iChannel0`, and accepting it would spend a sampler and an upstream render on a duplicate.
- **A repeated offset is rejected**, not folded. Folding would shift every later slot down, so a shader written against `iNeighbor2` would quietly start reading a different frame.
- **One `#frames` line per Image shader**, and `offsets=` must be a comma-separated list of whole numbers. `#frames` applies to the Image pass; a Buffer pass gets no neighbour samplers.

**Colour.** Every neighbour frame arrives in **exactly the same encoding as `iChannel0`** (gamma-encoded for an ordinary shader, linear for a `color-transform`). That is deliberate: mixing a gamma frame against a linear one shifts the colour of the blend, so a trail would drift away from the footage that cast it. Weight and mix the frames directly, the way you would sample `iChannel0` twice.

**Edge of the clip.** A frame Final Cut cannot deliver, before the clip starts or past where it ends, resolves to the **current frame**. The behaviour is a deterministic clamp, never transparent black, so a trail shortens smoothly into the first frames of a clip instead of blinking against a hole.

**Mini viewer.** The inspector's preview shows the real thing: the render process hands its resolved neighbour frames to the mini viewer alongside the source, so trails, echoes and frame differences appear there as they do in the viewer. The neighbours it holds are the ones from the **last frame Final Cut rendered**. With the playhead parked that set does not change, which is exactly what makes tuning work - drag a decay and the same neighbours re-blend under it. Move the playhead and the next render replaces them. Until the first render of a session lands, and for the moment after a `#frames` edit changes how many offsets there are, the preview clamps every neighbour to the current frame rather than showing a mismatched set.

**Cost.** Each offset is **one frame request**, not a range: four offsets ask Final Cut for four extra frames, no more and no less. What that request costs depends entirely on what the shader sits on.

**On a clip**, an offset is a media decode. A past offset is close to free, because that frame has just played and is still cache-warm. A near-future offset is cheap, because Final Cut renders a little ahead of the playhead anyway. A far-future offset pays a decode-ahead on every displayed frame, and long-GOP media (H.264, HEVC) pays far more for that than ProRes or optimized media, because reaching a future frame means decoding from the last keyframe forward.

**On an adjustment layer, or anywhere above a stack of effects**, an offset is not a decode: it is a full render of _everything below it_ at that time. The cost multiplies rather than adds, so N offsets can mean up to N+1 evaluations of the whole stack per displayed frame. Only the **immediately previous frame (`-1`)** is reliably cache-warm there: measured, `offsets="-1"` is effectively free, `offsets="-1,-2"` already pays a full stack render every frame, and offsets further out degrade from there. That is also why performance on an adjustment layer oscillates between fine and unusable with no change to the shader - Final Cut serves some of those from its cache and re-renders the rest. Baking the stack below (make the clips a compound clip and render it) turns every offset back into a cheap decode.

If all the shader needs above a stack is the previous frame's _result_, feedback gives it for one flat pass instead - see the decision guide above.

**So:** keep offsets few and near for realtime work. A far look-ahead is an export-quality choice, not a playback one. Prefer a short trail with a stronger decay over a long one.

Note also that Final Cut's playback scheduler does not recover mid-playback once it has fallen behind: a pause and a resume resets it instantly, so judge a change from a fresh play rather than from the tail of a struggling one.

```glsl
// #template filter
// #frames offsets="-1,-2"

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec3 c = texture(iChannel0, uv).rgb;
    for (int i = 0; i < iNeighborCount; i++)
        c = max(c, iNeighborAt(i, uv).rgb * (0.6 / float(i + 1)));
    fragColor = vec4(c, 1.0);
}
```

`#frames` and `#motionblur` are independent and compose: a shader may declare both, and the frames each one needs are scheduled together and paired back by their own timing, so neither claims the other's. A trail shader usually wants `// #motionblur off` anyway, since the trail already reads as motion.

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

Add `waveform=<samples>` when the shader needs the actual signed time-domain shape rather than frequency energy. It generates `uAudioWave(i)` and the compile-time constant `uAudioWaveSamples`. `wavewindow=` seeds an animatable **Waveform Window** lane in seconds (default `0.04`, range `0.005...0.25`); Sonar resamples that centred span into the requested number of values. This is the right input for oscilloscopes, waveform ribbons and phase-style displays. It is opt-in because every four samples consume one additional pool `vec4`; the maximum is 128 samples.

```glsl
// #audio label="Audio" waveform=128 wavewindow=0.04
uniform vec4 uAudio[16];

float sample = uAudioWave(i); // signed processed mono
```

Analyses published before waveform support still provide their spectrum, but the waveform reads zero until the source is republished from Sonar.

Nothing picked reads as silence rather than an error, so a shader with an unbound `#audio` still renders.

A binding also survives leaving the Mac it was made on. Published audio doesn't travel inside a project, so one opened elsewhere can't find what it's bound to - the picker keeps naming it, greyed out, under a **Republish required** warning, and the user gets it back by dropping the project on Sonar (the clips are already selected) and pressing Publish. Nothing needs re-pointing. Mirage authors don't have to do anything for this: it's the picker's job, not the shader's, and no directive attribute affects it.

See `audio-shader-directive` for shaping the levels into something that looks good, and `audio-sonar` for how a user publishes the audio in the first place, including the walkthrough for that warning.

## Injected helpers (no directive, no declaration)

Some functions every shader of a kind needs are supplied by the wrapper rather than pasted into each shader. **Call them; do not paste a copy in.** They are injected only when the shader names one, so a shader that needs neither set carries neither.

### Grading

| Function                                              | Does                                                                                                                                                                              |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `vec3 decodeToLinear(vec3 c)`                         | sRGB code values to linear light (the standard piecewise curve, not a `pow(2.2)`)                                                                                                 |
| `vec3 encodeFromLinear(vec3 c)`                       | linear light back to sRGB code values                                                                                                                                             |
| `vec3 linearToOklab(vec3 c)`                          | linear Rec.709 to Oklab, on the constants the Color panel's ring and scopes are built from                                                                                        |
| `vec3 oklabToLinearRaw(vec3 lab)`                     | the plain inverse, which may return a negative channel for a colour Rec.709 cannot show                                                                                           |
| `vec3 oklabToLinear(vec3 lab)`                        | the inverse that fits: out of gamut it pulls the **chroma** in, holding lightness and hue, rather than clipping a channel (clipping blue alone swings the hue by tens of degrees) |
| `vec3 balanceGain(float redCyan, float greenMagenta)` | two-axis print balance as linear channel gains, each axis lifting one primary and sharing the loss across the other two                                                           |

`iChannel0` is gamma-encoded for an ordinary shader, so the usual grading shape is decode, work in linear or Oklab, encode back:

```glsl
vec3 lin = decodeToLinear(texture(iChannel0, uv).rgb);
vec3 lab = linearToOklab(lin);
lab.yz *= saturation;
fragColor = vec4(encodeFromLinear(oklabToLinear(lab)), 1.0);
```

A `// #template color-transform` shader already receives linear values and must not decode. See `#template` above.

### Transitions

Both endpoints of a transition can be transparent, so both of these take and return **straight** alpha and do the arithmetic on premultiplied colour. Blending straight `rgb` lets a transparent endpoint's leftover colour bleed into the result, which is what makes a raw `mix` darken an incoming clip that fades up over nothing.

| Function                                                               | Does                                                                              |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `vec4 mixTransitionColors(vec4 fromColor, vec4 toColor, float amount)` | crossfades the two endpoints, `amount` 0 = from, 1 = to                           |
| `vec4 compositeTransitionLayer(vec4 background, vec4 foreground)`      | source-over of one layer on another, for a wipe edge or glow drawn over the blend |

```glsl
vec4 blended = mixTransitionColors(fromColor, toColor, wipe);
fragColor = compositeTransitionLayer(blended, edgeGlow);
```

### Defining one yourself

The names are reserved in the sense that matters: a shader that **defines** one of them keeps its own version and gets none of that family injected, so an older template carrying its own copy still compiles. Redefining one to mean something else works but reads as a trap; pick another name.

The suppression is per family, and the families are the groups that call each other: the sRGB pair, the Oklab trio, `balanceGain`, `mixTransitionColors`, `compositeTransitionLayer`. Owning one transition helper therefore still leaves the other injected.

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

## The Color surface (`#color-surface`)

`// #color-surface` stands alone like `#template` or `#motionblur` and opts the shader into the inspector's **Color panel**: a circle whose outline is a scope carrying the frame's own distribution, with one or more draggable **pucks** inside it. It is opt-in, so a shader that never asks for it never grows the panel.

```glsl
// #color-surface ring=light xaxis="Cool,Warm" yaxis="Darker,Brighter"
```

The puck writes the shader's **real controls**. There is no hidden grading state: drag toward Brighter and the Threshold and Bloom lanes visibly move in the inspector, so a grading gesture keyframes, undoes and exports exactly like a typed value.

| Attribute | On            | What it does                                                                                                                      |
| --------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `ring=`   | the directive | what the outline paints: `plain` (default), `light`, or `hue`. One `hue` surface and one `light` surface may be declared together |
| `xaxis=`  | the directive | the two ends of the horizontal axis, negative end first: `xaxis="Cool,Warm"`                                                      |
| `yaxis=`  | the directive | the two ends of the vertical axis, negative end first: `yaxis="Darker,Brighter"`                                                  |
| `space=`  | the directive | the colour space the shader's maths works in. Only `linear-rec709` is accepted, and it is the default, so it can be left out      |

`ring=` is the legend AND the scope, so choose the one the axes are about. `light` paints a dark-to-bright ramp with the frame's luminance distribution around it. `hue` paints a hue wheel with the frame's chroma as a polar cloud - a vectorscope you can pull against. `plain` is a bare outline, right for axes that are about neither. An undeclared axis is drawn as an unlabelled direction rather than given an invented name.

`space=` is a declaration, not a conversion request: nothing here transforms the image. Normalise upstream with the Color Transform effect.

**When `plain` is the right declaration.** Reach for it when the two axes are about neither light nor hue, so a painted ring would be a legend for the wrong quantity. A hue wheel under a pair of geometry axes says the drag is a colour move, and a luminance ramp under a warp's amount and direction says it is an exposure one. The plain outline claims nothing, which is exactly right when there is nothing to claim. What it does not do is measure: `light` and `hue` carry the frame's own distribution and `plain` carries none, so it is somewhere to put handles rather than a scope. That is also why it cannot be one of a declared pair, which exists to show two readings of the same frame.

A surface with no `surface=` mapping on any control has nothing for its puck to drive, so declaring one purely to make the panel appear leaves a handle that moves and changes nothing. Declare the surface for the drag, not for the panel.

### Two rings at once

A shader may declare the directive **twice**, once with `ring=hue` and once with `ring=light`. The panel then stacks both circles, in declaration order, and grows downward to fit them. A grade needs both readings of the frame - the cast is a hue problem and the exposure is a light one - and they are two measurements of the same picture rather than one control with a mode, so neither has to be put away to look at the other.

```glsl
// #color-surface ring=hue
// #color-surface ring=light xaxis="Flat,Punchy" yaxis="Darker,Brighter"
```

Each surface carries its **own** `xaxis=`, `yaxis=` and `space=`. Each ring gets its own pucks, its own active puck and its own rows in the readout, and both are fed from the same measured frame: the wheel draws the chroma cloud and the cast cross, the tonal circle draws the luminance distribution. The eyedropper and the memory-colour sampler belong to the **hue** ring, because a cast is a position on it and there is nowhere on a tonal ramp for one to be.

The rules are exact:

- Two is the ceiling, and the pair must be one `ring=hue` and one `ring=light`. Two of the same ring, or a `plain` outline as one of the two, is an error - there is nothing a second copy of a wheel could measure that the first does not, and a plain outline has no keyword a control could aim at.
- A shader declaring **one** surface is completely unaffected. Nothing below is required of it.

### Mapping a control to the puck: `surface=`

`surface=` on any value control binds it to a puck. It is **cartesian** (`x:` / `y:`) for two independent directions, or **polar** (`r:` / `a:`) for a wheel. A surface is one or the other - mixing is rejected, since both describe the same two degrees of freedom.

```glsl
// #percent label="Threshold" min=0 max=100 default=58 surface="y:-14"
uniform float uThreshold;

// #percent label="Saturation" min=0 max=200 default=100 surface="r:+40"
uniform float uSaturation;
```

The number is the move **at full deflection, in the control's own units**: at full upward deflection that Threshold falls 14 percent. `r:` responds to the puck's distance from the centre, so the centre is always the control's declared default and the rim its full response. `a:` responds to the puck's bearing, its magnitude being the value at half a turn, so `a:+180` makes the bearing the angle directly. A `#color` control's response is in **degrees of hue**, which follows from its kind rather than needing its own syntax.

**Cartesian or polar is decided per RING, not per control.** One `r:` or `a:` anywhere on a ring makes that whole ring polar, and every `x:` / `y:` mapping on it is then skipped rather than blended in. So a stray polar term does not add a third direction, it stops the cartesian controls responding to the puck at all. One grammar per ring.

The ring kind has nothing to say about which grammar that is. `ring=` paints the outline and nothing else, so a polar `r:` on a `ring=light` surface is legal and means what it always means, the puck's distance from the centre, with the surface's `xaxis=` and `yaxis=` labels then describing directions no control reads. Pick the grammar from what the controls are: a bearing is worth aiming somewhere on a wheel, and a pair of independent directions reads as a cross.

`default=`, `min=` and `max=` are part of the mapping, not decoration:

- `default=` is the **base** - what a centred puck means. It is read from the directive, not from wherever the control happens to sit, or the puck would always derive back to the centre.
- `min=` / `max=` are the **limits the rim reaches**. The response is a cubic whose slope at the centre is the authored magnitude and whose edge lands exactly on the limit, so small moves stay predictable near the middle while the extremes are still reachable. Without both limits the response stays plain linear rather than inventing a range.

On a **cartesian** surface the rim reaches every mapped control's full range in **every** direction, diagonals included: a pair like `x:-100` and `y:-100` both land at their limits together in the corner. So two perpendicular mappings can be authored as a genuine pair without one direction quietly costing the other most of its travel.

The relationship is bi-directional and deliberately asymmetric: dragging applies the **change** in puck position to the controls, while the puck's drawn position is **derived** from the controls by a least-squares fit. That is what keeps a hand-tuned value from being snapped onto the mapping the instant the puck is nudged, and it means a control pinned at its min or max makes the puck visibly lag the cursor instead of the drag going quietly dead.

#### Saying which ring, when there are two

With **two** surfaces declared, `surface="x:+31 y:+17"` no longer says enough: the same gesture means a cast on one circle and an exposure on the other, and nothing in the shader decides which. So the value starts with the ring's own word:

```glsl
// #color-surface ring=hue
// #color-surface ring=light xaxis="Flat,Punchy" yaxis="Darker,Brighter"

// #float label="Red / Cyan" min=-100 max=100 default=0 surface="hue x:+31 y:+17"
uniform float uRedCyan;

// #float label="Exposure" units="stops" min=-5 max=5 default=0 surface="light y:+1.5"
uniform float uExposure;
```

`hue` or `light`, in front of the terms. It is a **marker**, not a position in the file: binding each control to the nearest `#color-surface` above it would make the order of the directives load-bearing, and directives are reordered all the time to group the inspector. It would also have no failure mode, since every control sits under some surface, so a mis-aimed one would attach silently to the wrong ring instead of saying so.

The marker is optional on a shader with **one** surface, because there is only one thing it could name - which is why no existing shader needs an edit. Naming it there anyway is legal as long as the word matches the ring that is declared. The editor reports the two ways it can be wrong:

- a `surface=` with no ring word while two rings are declared
- a `surface=` naming a ring the shader does not declare

`puck=`, `track=` and `pick=` are unchanged by any of this. Pucks are scoped to their ring, so two rings may each have a handle of the same name without them being the same handle - the readout then heads each block with the ring, and only then.

### Named pucks: `puck=`

`puck={"Name", "sf.symbol"}` says which handle drives the control. Controls **sharing a name share a handle**, so one circle can carry several independent corrections - a three-way's shadows, midtones and highlights - with no mode control to switch between them and nothing to hide while comparing. Omit it and every mapping drives the surface's single unnamed puck.

```glsl
// #float label="Red / Cyan" group={"Shadows", "moon"} puck={"Shadows", "moon"} min=-100 max=100 default=0 surface="x:+40"
uniform float uShadowRC;
```

Pucks are **not** inferred from `group=`: one gesture often spans several inspector groups (a bloom's Threshold, Bloom and Mist), which grouping would split into a puck each. The second slot is what tells one handle from another, so it is optional but effectively required once there is more than one puck.

The second slot is an SF Symbol name **or literal text**. It is looked up as a symbol first; anything macOS does not know as one is drawn as text inside the handle, so `puck={"Shadows", "S"}` gives a handle marked S without hunting for a symbol shaped like the letter. At most **two characters** are drawn, and a longer string keeps its first two: a handle is nine points across and a third character would read as a smudge. A mistyped symbol name is therefore visible as itself rather than silently leaving a blank handle.

```glsl
// #float label="Lift" puck={"Shadows", "S"} min=-100 max=100 default=0 surface="y:+40"
uniform float uLift;
```

Leave the slot out and the handle takes a **default** mark: an instance of a repeatable group shows its own number, and any other puck - including the single unnamed one a shader with `surface=` but no `puck=` gets - shows `G`. Both are defaults only, and an authored symbol or text always wins.

A puck can also be **one per instance** of a repeatable group - a wheel the user adds another handle to - by naming it with the instance placeholder, `puck={"Colour {n}", "{n}.circle"}`. See "Repeatable groups: `#slots`" below.

### Rotation-only pucks: `track=`

`track=<0.1..1>` pins a puck to a circle at that fraction of the radius, so the drag is a **rotation and nothing else**. Declared once per puck, on any of its controls.

```glsl
// #float label="Target Hue" units="°" min=-180 max=180 default=0 surface="a:+180" puck={"Target", "eyedropper"} track=0.78
uniform float uTargetHue;
```

Reach for it when a puck's controls are all angular - a hue selector, say. Distance there is not merely unused, it is meaningless, and a handle that slides in and out while only its bearing does anything invites the reading that the middle means "less".

### A hue control points AT the hue

For a **hue-valued** control - a `#color` swatch driven through an angular `a:` term, or a hue-in-degrees float - the puck's bearing **is the absolute hue**, the hue as the grading wheel measures it, so the bearing and the ring under it name the same colour. Point the handle at green and you get green, whatever the control's `default=` is. It is not an offset from the default, because a handle sitting on a painted hue wheel that reports something other than the hue it is sitting on is unreadable. Ordinary cartesian and `r:` mappings are unaffected: they still move relative to the control's base.

### Sampling from the footage: `pick=`

`pick=hue` | `pick=saturation` | `pick=luma` | `pick=luma-linear` | `pick=color` on a control subscribes it to the panel's **eyedropper**. When the current shader declares at least one `pick=` on a currently-visible control, the Color panel shows an eyedropper, and clicking the footage in the mini-viewer samples a small patch and writes the chosen property of that colour into **every subscribed control at once, in one undo step**.

```glsl
// #percent label="Pivot" min=1 max=99 default=18 pick=luma-linear
uniform float uPivot;
```

Both the eyedropper and Set from clip live on that panel, and the panel exists only for a shader declaring `#color-surface`. So `pick=` in a shader without one does nothing at all: there are no buttons for it to subscribe to. A picker therefore costs a surface, which means having something for the surface's axes to be about.

| `pick=`       | What lands in the control                                                                                                                                                     |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `hue`         | the hue as the grading wheel measures it, in degrees, wrapped to -180..180 when the control's `min=` is negative and 0..360 otherwise. A neutral or grey patch writes nothing |
| `saturation`  | 0..1, the patch's colourfulness as a fraction of the most colourful thing Rec.709 shows, multiplied by 100 for a percent-range control                                        |
| `luma`        | Rec.709 luma of the **display-coded** sample, with the same scaling. The brightness the scope and the light ring show                                                         |
| `luma-linear` | the same weights on the sample **decoded to linear light**, with the same scaling                                                                                             |
| `color`       | the sampled RGB into a `#color` control's swatch                                                                                                                              |

**Which luma:** read the line in your shader that consumes the value. If it is compared against `texture(iChannel0, uv)` or any other still-encoded pixel - a highlight threshold, a key's minimum brightness - use `pick=luma`, because both sides of that comparison are code values. If it is used as light, after a `toLinear()` and before the re-encode - a contrast pivot in `pivot * pow(c / pivot, k)`, an exposure reference, a linear mix weight - use `pick=luma-linear`. The difference is not a rounding: a face sampled at display `0.55` is `0.26` of the light, so a pivot fed the display number sits about a stop above the grey the user clicked and rotates the picture around the wrong tone. Both write the same 0..1 range and take the same percent scaling, so the choice is only ever about which space the number is read in.

Beside the eyedropper, the panel offers **Set from clip**. It arms one click in the preview, and that click aims only the **active puck's** subscribers - the handle you last touched - at the colour under it, all in one undo step. The colour is read from the original clip rather than from the graded result, so re-picking the same pixel does not walk the value as the grade moves it. Escape, clicking the button again, or the click itself disarms.

Scoping is by `puck=`, which a `pick=` control may declare on its own without a `surface=`: `puck=` names the handle a control belongs to, and `surface=` only says how it responds to being dragged. In a shader that names pucks, a `pick=` control naming none is skipped by Set from clip - it has not said which handle it belongs to, and writing it from every handle would fill all of them with the same colour. The eyedropper still writes it, since that gesture is deliberately shader-wide. A shader that names no puck at all has one unnamed handle every control belongs to, so both buttons reach everything.

`pick=` works with or without a `surface=` mapping on the same control, and it never affects the puck layout. Use it where the control's value genuinely **is** a property of a colour in the frame - a hue to key, a mid-grey pivot, a light's tint. It is the wrong tool for a gate or a threshold that the click should fall inside: writing the clicked pixel's own saturation into a minimum-saturation control excludes half of what was just clicked.

### Preview-owned controls: `preview=`

Two markers hand a control to the inspector's preview. A marked control is **session state, not a parameter**: it gets **no inspector row**, it is never keyframed, and nothing about it is written to the project. The shader declares the uniform so the inspector has something to drive; it is driven straight into the mini viewer and nowhere else.

```glsl
// #bool label="Show Selection" group={"Finish", "switch.2"} default=false preview=selection
uniform bool uShowSelection;

// #choice label="Preview Key" group={"Finish", "switch.2"} options="All,1,2,3,4,5,6" default=0 preview=active-key
uniform int uPreviewKey;
```

`preview=selection` names the switch that shows the shader's **selection** - the matte a qualifier keys - instead of the graded result. It appears as a third icon on the preview itself, beside Before and Split, with the shortcut **M**, because tuning a key means flicking it constantly. That row belongs to the mini viewer every template has, so the switch works in a plain filter with no `#color-surface` at all - a denoise, where before/after and the noise view are the whole job.

`preview=active-key` names the control that says **which** key that matte is about: `0` for all of them, `n` for the nth instance of the repeatable group. You never touch it - the Color panel feeds it the handle you last touched, so the matte follows the puck you are holding. Declare it outside the `#slots` block; its `options=` exist to give the numbering meaning, not as a menu anyone sees.

**Why they are not parameters.** Both answer "what am I looking at right now", which is the question Before and Split answer, and those were never parameters either. As rows they cost three things that all read as bugs: a press spent an **undo entry**, so stepping back through a grade walked through every glance at the matte; the value **persisted**, so a project reopened weeks later came up showing a grey diagnostic instead of the shot; and the key one was a slider over a **ceiling** with nothing to do with how many keys were live.

**What the shader sees when nothing is driving it: your declared default** - in the mini preview and in Final Cut's viewer alike, because no lane exists to say otherwise. So author them **off** (`default=false`, option `0`) and the diagnostic never reaches a render. This also means the matte is a thing you see while grading and never a thing you ship.

Guard the key comparison against a **stale value** - the panel can only ever feed a live key, but a project made before this was session state may still carry an old stored one, and an out-of-range key would match nothing and show an empty matte:

```glsl
int previewKey = uPreviewKey > uKeyCount ? 0 : uPreviewKey;
```

Kinds are fixed: `preview=selection` on a `#bool` over a `uniform bool`, `preview=active-key` on a `#choice` over a `uniform int`. The marker anywhere else - a different directive kind, or a uniform that disagrees with it - is ignored the way a mistyped `pick=` is, so a typo costs the feature quietly rather than failing a compile. Declare each once; the first in the source wins.

## Repeatable groups: `#slots`

Some controls come in **an unknown number**. A shader that tints three lights, or keys four hues, or draws N shapes cannot say how many the user wants, and declaring eight of everything up front fills the inspector with seven rows that do nothing. `// #slots` declares the controls for **one** of them, and the user adds and removes copies at runtime:

```glsl
// #slots name="Colour" max=8 default=1 min=0
// #color label="New Colour {n}" puck={"Colour {n}", "{n}.circle"} pick=hue
uniform vec4 uNewColour;

// #percent label="Strength {n}" min=0 max=100 default=50
uniform float uNewStrength;
// #slots-end
```

`#slots` opens the block and `#slots-end` closes it, both standing alone on their own line like `#template` or `#frames`. **Exactly** the controls between them belong to the group, and they repeat **together**: adding an instance adds a swatch, its strength and its own puck, because that trio is what the user thinks of as one colour.

| Attribute  | Required | What it says                                                                                      |
| ---------- | -------- | ------------------------------------------------------------------------------------------------- |
| `name=`    | yes      | what one instance is called. It heads the instance and keys its lanes, so no two groups share one |
| `max=`     | yes      | the hard ceiling, 1 to 16. Every instance is a live lane set and a slice of the render pool       |
| `default=` | no       | instances a fresh apply starts with, 0 to `max` (1 when absent)                                   |
| `min=`     | no       | instances the panel refuses to delete below, 0 to `max` (0 when absent)                           |

`max=` is a budget, not a formality: the pool is finite, so the ceiling is declared rather than discovered by the tenth instance quietly not rendering. Set it to the most the effect is actually worth having.

### `{n}`, the instance number

`{n}` is where the instance's number goes, counting from **1**. It is legal in `label=`, in `group=`, and in both slots of `puck={"Name", "symbol"}` - which is what makes `puck={"Colour {n}", "{n}.circle"}` give instance 3 its own handle, drawn with the `3.circle` symbol. Writing `puck="Colour {n}"` with no symbol at all reaches the same place through the default: an instance with nothing declared is marked with its number.

In `group=` it decides something bigger than a name: whether the instances share one inspector group or get one each. `group={"Colour {n}"}` gives instance 2 its own **Colour 2** header, which collapses, expands and reads on its own. A `group=` with no `{n}` - or none at all - puts every instance under the one header, which is what a block wants when its controls are variations on a single idea rather than separate things. Both are supported and neither is the default in disguise: a block that never writes `{n}` into `group=` groups exactly as it always has. The icon follows the same rule, so `group={"Colour {n}", "{n}.circle"}` heads instance 3 with the `3.circle` symbol, and the editor resolves the numbered name rather than reporting `{n}.circle` as an unknown symbol.

Inside a block it is **required** on every control's `label=`, and on the `puck=` name when there is one. That is not tidiness: two instances whose rows both read "New Colour" are two rows the user cannot tell apart, and two pucks sharing a name are **one** puck being dragged by both instances. Writing `puck=` with no readable name is rejected for the same reason - an unnamed handle is one handle, so the collapse would arrive through the front door. Omit `puck=` entirely if the controls are meant to share the surface's single unnamed puck. Outside a block `{n}` is rejected, since there is no instance number to put there and it would otherwise reach the inspector as literal text.

The editor reports the whole set: an unclosed `#slots`, a `#slots-end` with nothing open, a nested `#slots`, a missing or malformed `name=` / `max=`, a `default=` or `min=` outside `0..max` (or a `default=` below `min=`), two groups sharing a name, a control inside a block with no `{n}`, a `puck=` inside a block with no name, a `#gradient`, an `#audio` or an arrayed `#color` inside a block, and a `{n}` outside every block.

A shader may declare **several** groups - lights and gradients are two different things to have several of - as long as each has its own name. Nesting is not allowed: an instance count that is the product of two counts has no name a row could carry.

### What the shader receives

This is the contract, and it is worth reading before writing the block: inside a block you declare **plain scalar uniforms**, exactly as you would anywhere else, and the compiler turns each one into an **array of `max`** and injects **one count** for the group. The example above reaches the shader as:

```glsl
uniform vec4  uNewColour[8];    // one per instance
uniform float uNewStrength[8];
uniform int   uColourCount;     // injected: how many are live this frame
```

The count is named from `name=` - its letters and digits, each word capitalised, as `u<Name>Count` - and it belongs to the **block**, not to any one uniform: every control in the group appears and disappears together, so one count is the whole answer. Loop over it:

```glsl
vec3 tint = vec3(0.0);
for (int i = 0; i < uColourCount; i++)
    tint += uNewColour[i].rgb * uNewStrength[i];
```

Slots past the count are **zero**, so bound the loop by the count and never by `max` - a deleted instance leaves a black swatch and a zero strength behind it, not the value it had. And declare **single** uniforms inside a block: a control that is already an array (a `#color` palette, an `#audio` binding, a `#gradient` ramp) carries its own count and belongs outside the block rather than being arrayed twice.

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
- **Don't open a prose comment with a directive name.** `// #gradient: nAt() returns the colour at t` reads as a sentence to you and used to read as a real `#gradient` to the parser. A colon straight after the name is now rejected, but the habit to keep is to write `// The #gradient helper...` or `// nAt() returns...` instead of leading with the name.
- Editing a directive live re-derives the control set (and its OSCs) without a clip reselect - add / rename / re-`osc` a uniform and the inspector + viewer update on the next commit.
