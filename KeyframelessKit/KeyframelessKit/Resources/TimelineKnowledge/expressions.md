---
id: expressions
summary: Drive a property from a formula (value, t, functions, easing, cross-clip ${refs}, vectors)
---

An expression drives a property from a small formula instead of a plain value or keyframes. It is evaluated every frame, so it can move a property over time, react to another clip, or reshape the property's own animation - the kind of motion that would take dozens of keyframes to build by hand.

- Add one by right-clicking a property's label in the Constants or keypose editor and choosing Add Expression. A small code editor opens under that property; Remove Expression and Format Expression are in the same menu.
- `value` is the property's own value right now - its keyframes or its constant. Build on it: `value + 10` offsets it, `value * 2` doubles it. A bare `value` changes nothing, so keep it in the formula unless you mean to replace the value outright.
- Move something over time with `t`, the time in seconds. `value + sin(t * tau) * 20` wobbles it by 20 either way; `tau` is one full turn, so `sin(t * tau)` repeats once a second - divide `t` to go slower, multiply to go faster.
- Loop smoothly by feeding a 0-to-1 phase into an easing function: `value + easeInOut(pingpong(t, 2)) * 20` eases up and back every 2 seconds. `pingpong` and `repeat` turn time into that phase, and the easings match the ones on the timeline.
- `t` is the whole project's clock, not the clip's. For motion that starts when the clip does, use `progress` (0 to 1 across the clip) or `ct` (seconds since it started) - ease something in over the clip's first second with `easeOut(clamp(ct, 0, 1))`.
- Add randomness with `random(seed)` (a steady 0-to-1 value; the same seed always gives the same number) or `noise(x)` (its smooth, flowing version). They are seeded by what you pass, so they stay put when you scrub - `random(floor(t))` rolls a fresh value each second, `value + (noise(t) * 2 - 1) * 20` drifts organically by 20 either way. Feed a different seed per clip (or `${...}` reference) to desync copies.
- Link one clip to another with the insert button (the + in the editor's gutter): it lists the other clips and their parameters, and choosing one drops in a reference. `${Title.Opacity} * 0.5` makes this property follow the Title clip's opacity at half strength.
- For a property with more than one part - a Size's width and height, a Position's X and Y - `value` is the whole thing. Read one part with `value.x` or `value.y` and rebuild it with `vec2(...)` to drive the parts independently.
- The insert button also lists every function and variable with a short description, so you can discover what is available; and as you type, a live result with a small sparkline under the editor previews the value.

## Turning it on

Right-click a property's label in the Constants or keypose popover and choose **Add Expression**. An inline code editor opens under that property. **Remove Expression** takes it away; **Format Expression** tidies the formula. The editor has an insert button (the `+`) that opens a menu of the other clips you can reference plus every function and variable, and a live result readout with a little sparkline so you can see the value as you type. Syntax is colour-highlighted; a red line marks a mistake.

This is NOT JavaScript. It is a tiny numeric grammar: numbers, arithmetic, comparisons, a ternary, function calls, and clip references. Every value is vector-aware, so the same formula works on a scalar (Opacity), a point (Position), or a colour.

## The core idea: `value`

`value` is the property's OWN value at the current time (its keyframes or its constant). Most expressions build on it:

- `value * 2` - double it.
- `value + 10` - offset it.
- `value + sin(t * tau) * 20` - wobble around its animated value.

An empty expression, or just `value`, is a passthrough (no change).

## Variables

- `value` - this property's own value (keyframes or constant) at this time.
- `t` - ABSOLUTE project time in seconds. Advances continuously; it is NOT reset to zero at the clip's start.
- `progress` - 0 to 1 across THIS clip. Use for a whole-clip ramp.
- `ct` - seconds since THIS clip started (0 at its first frame). Use for one-shots at the start.
- `pi` - 3.14159 (half a turn in radians).
- `tau` - 2*pi, one full turn. `sin(t * tau)` repeats once per second.
- `e` - Euler's number, ~2.718.

Time gotcha: `t` is absolute, so `sin(t)` is a global clock, not "since this clip." For anything that should start when the clip starts, use `progress` or `ct`.

## Operators

`+  -  *  /  %` arithmetic, unary `-` and `!`, comparisons `< <= > >= == !=`, `&&`, `||`, and a ternary `cond ? a : b`. Comparisons return 1 or 0, so `(t > 2) * 100` is a gate.

## Functions

Math: `sin cos tan` (radians), `abs sign floor ceil round sqrt exp log`, `rad(deg)` / `deg(rad)` to convert angles, `min(a,b) max(a,b) mod(a,b) pow(a,b) atan2(y,x) hypot(a,b)`, `step(edge,x)`, `clamp(x,lo,hi)`, `lerp(a,b,t)` (alias `mix`), `smoothstep(lo,hi,x)`.

Easing (identical to the timeline's keypose easing) - each takes a 0 to 1 phase and returns an eased 0 to 1: `easeIn(f, intensity?)`, `easeOut(f, intensity?)`, `easeInOut(f, intensity?)`, `elastic(f, intensity?, freq?)`, `bounce(f, intensity?, freq?)`. They do NOT clamp, so feed them a 0..1 phase, never raw `t`.

Phase (turn absolute time into a 0..1 loop to feed an easing function): `repeat(t, period)` - sawtooth 0 to 1 every `period` seconds; `pingpong(t, period)` - triangle 0 up to 1 and back every `period` seconds.

Vector: `vec2(x,y)`, `vec3(x,y,z)`, `vec4(x,y,z,w)` build multi-component values; a single scalar broadcasts.

## Multi-component properties

For a property with more than one component (a Size's W,H; a Position's X,Y; a colour's R,G,B,A) `value` is the whole vector and operators broadcast. Read one component with a swizzle: `value.x value.y value.z value.w` (or `.r .g .b .a`). Drive axes independently by rebuilding the vector:

- `vec2(value.x, value.y + pingpong(t, 2) * 10)` - hold W, bob H.
- `value * vec4(1, 1, 0.5, 1)` - scale only the third component.

## Referencing another clip: `${Clip.Param}`

`${...}` pulls in a parameter published by another clip on the timeline, sampled at the current timeline moment, so two clips can stay in sync:

- `${Title.Opacity}` - the Title clip's Opacity right now.
- `value * ${Controller.Scale}` - drive this off another clip's Scale.

Pick these from the insert menu (it lists every clip and its referenceable params, with a thumbnail to tell same-named clips apart). The menu shows a friendly `${Clip.Param}` name; it is stored by a stable id so it survives renames. Outside the referenced clip's own span the value holds at its nearest end. References can chain (a referenced param may itself use an expression) and cycles are safe (they resolve to 0, they do not hang).

A layered clip (Canvas) publishes per LAYER: the insert menu nests its layers inside the clip (`Clip > Layer > Param`) and the reference reads `${Clip.Layer.Param}` - e.g. `${Canvas @ 0:04.Ball.Position}`. That works from another clip AND from a different layer of the same Canvas, so one layer can follow another (`${Canvas @ 0:04.Ball.Position} + vec2(0.1, 0)` makes this layer trail the Ball). Layer references store the layer's stable id, so renaming a layer never breaks them.

## Recipes

- Continuous wobble: `value + sin(t * tau * 0.5) * 20` (0.5 Hz, amplitude 20).
- Looping ease (back and forth every 2s): `value + easeInOut(pingpong(t, 2)) * 20`.
- Looping ease (repeat, snap back): `value + easeOut(repeat(t, 1.5)) * 30`.
- One-shot ease over the first second of the clip: `lerp(value, value + 100, easeOut(clamp(ct, 0, 1)))`.
- Whole-clip ramp: `lerp(0, 100, easeInOut(progress))`.
- Gate on after 2 seconds: `value + (t > 2) * 50`.
- Follow another clip at half strength: `${Hero.Rotation} * 0.5`.

## Gotchas

- `value` is the property's value BEFORE the expression - build on it, do not forget it (a bare `sin(t)` throws away the user's keyframes).
- Angles are radians. A property shown in degrees is still radians inside `sin`/`cos`; use `rad()` / `deg()` to convert.
- Easing and `smoothstep` want a 0..1 input. Feed `progress`, `clamp(ct, 0, 1)`, or a `pingpong`/`repeat` phase, not raw `t`.
- `t` is absolute project seconds, so time-based motion is continuous across the whole timeline, not per-clip. Use `ct`/`progress` for clip-local timing.
- The result is the property's driven value each frame; on-screen controls still edit the underlying `value` (the root), not the expression output.
- Not every parameter takes an expression: gradients (a variable-length stop stack, not a numeric value), code editors, and canvas-edited geometry like a path's Points have no "Add Expression" option and cannot be referenced as `${...}` sources either. Position lanes drawn as an on-screen path can be referenced but not driven (an expression would override the drawn path).
