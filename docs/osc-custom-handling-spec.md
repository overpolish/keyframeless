# Custom OSC handling - mini spec

A shader template can build its own on-screen controls (OSCs) out of a small set
of **primitives** plus **template-supplied handling**, with no bespoke Obj-C
control class per template. A crop box is the `box` primitive plus a value-to-rect
mapping. A radius handle is the `point` primitive plus a value-to-position mapping.
The engine owns the primitives (draw, hit-test, parts, drag mechanics). The
template owns the meaning (how its lane value maps to the primitive's geometry).

The goal is to stop writing one-off OSC classes for flagship templates and instead
express their controls declaratively over reusable primitives.

## Principles

- **Primitives, not classes.** There is a fixed, small set of OSC primitives.
  Everything a template needs (crop, radius, custom handles) is a primitive plus a
  mapping. No template ever ships a new control class.
- **CPU-side, never GPU.** OSC interaction is hit-test, drag math, and lane writes
  in an FxPlug action scope, all Obj-C on the main thread. The GLSL fragment shader
  never touches it. "Custom code" here means a CPU-evaluated expression layer, not
  shader execution.
- **The primitive owns interaction, the template owns meaning.** A `point` follows
  the pointer, a `box` does anchored resize plus body-move, a `ring` sizes. The
  template supplies the bijection between its lane value and that geometry.
- **Opt-in, simple stays simple.** `osc=point` / `osc=ring` with no OSC tab keep
  today's default behaviour (handle at the value, ring sized by the value). Custom
  handling is only reached for when a template needs it.
- **Built on what exists.** Expressions are the existing `KKLinkExpr` engine plus
  OSC variables. Write-back is the existing `ShaderOSC` action-scope path.

## Primitives

Each primitive is a reusable kit control used as a scaffold (draw + hit-test +
named parts). Its default drag mechanic is fixed.

| Primitive | Backed by                                                    | Parts                                          | Default drag                    |
| --------- | ------------------------------------------------------------ | ---------------------------------------------- | ------------------------------- |
| `point`   | `KKPointOSC` / `KKSquarePointOSC` / `KKArcOSC` (by `style=`) | `handle`                                       | handle follows the pointer      |
| `box`     | `KKBoxOSC`                                                   | `body`, corners `tl tr bl br`, edges `t b l r` | **anchored resize + body-move** |
| `ring`    | `KKRingOSC`                                                  | `edge`                                         | edge sizes the radius/extent    |
| `rotate`  | `KKRotationOSC`                                              | per-axis rings `x y z`                         | ring turns the axis angle       |

`box`'s default drag is anchored resize (the dragged handle moves, the opposite
corner/edge stays fixed) plus body-move. The old centered/radial box is just a
different bijection, not a different primitive.

## The OSC tab

Custom OSCs live in a dedicated, opt-in **OSC tab** in the same code editor as the
Image and Buffer A-D passes. It is not GLSL, it is the OSC-handling language below.

Each `osc` block binds a lane and supplies a **forward** map (value -> geometry,
for drawing) and an **inverse** map (geometry -> value, on drag). Optional per-part
`drag[...]` rules override the primitive's default drag for a single part.

### `point`

```
osc Radius {
  primitive = point
  binds     = uRadius
  style     = square              // dot | square | hollow

  toPos     = tr - vec2(uRadius)  // value -> handle position (draw)
  fromPos   = length(tr - pos)    // dragged position -> value (write)
}
```

### `box`

```
osc Crop {
  primitive = box
  binds     = uCrop               // vec4 W,H,X,Y (top-left, 0..1)

  toRect    = rect(vec2(uCrop.z, 1.0 - uCrop.w - uCrop.y),
                   vec2(uCrop.z + uCrop.x, 1.0 - uCrop.w))       // value -> rect
  fromRect  = vec4(rect.w, rect.h, rect.min.x, 1.0 - rect.max.y) // rect -> value
}
```

The `box` handles the anchored resize and the body-move internally. The template
never writes per-handle math for crop - `toRect`/`fromRect` is the whole contract.

### Per-part override (the escape hatch)

When the primitive's default drag is not enough, scope a rule to a part:

```
  drag[body] = <expr using mouse, value, part>
  drag[tr]   = <expr ...>
```

`part` is a constant naming the grabbed part (`body`, `tl`, `tr`, `bl`, `br`,
`t`, `b`, `l`, `r`, `handle`, `edge`, an axis). The bijection covers crop and
radius; `drag[part]` is only for genuinely exotic handles.

## Coordinate model

Expressions run in **object space**: normalized `0..1` on each axis, origin
bottom-left, **Y-up** (the same space as directive `center=`, point lanes, and the
shader's `fragCoord`). It is per-axis normalized, so it is aspect-distorted. The
engine converts object <-> canvas <-> screen via the existing
`KKOnScreenControl+CoordinateSpace` helpers.

Builtins available to expressions:

- `value` - the bound lane value (scalar or vector).
- `mouse` - the pointer in object space, valid during a drag.
- `pos` / `rect` - the primitive's live geometry (`pos` for `point`, `rect` with
  `.min`/`.max`/`.w`/`.h` for `box`).
- `size` - the frame in pixels (media px), for pixel-exact math.
- `aspect` - `size.x / size.y`, so radial insets can correct for a non-square
  frame (e.g. `tr - vec2(uRadius) * vec2(1.0, aspect)`).
- `tl` `tr` `bl` `br` `center` - frame corners and centre in object space.
- `part` - the grabbed part constant (in `drag[...]` rules).

Decision: object space plus these builtins, NOT a magic uniform-min-edge space -
the author corrects aspect explicitly with `aspect` when a handle is radial.

## Grammar

The OSC-handling expression language is the existing `KKLinkExpr` grammar (numbers,
vectors, `+ - * / %`, comparisons, `&&`/`||`, ternary, the function set:
`sin cos ... clamp lerp smoothstep vec2/3/4 ...`, swizzles) extended with:

- the OSC variables above (`value mouse pos rect size aspect tl tr bl br center part`),
- `rect(min, max)` constructor and `.min .max .w .h` accessors,
- the `part` constants.

## Write-back

A drag evaluates `fromPos` / `fromRect` / `drag[part]` to new component values,
then writes them through `ShaderOSC`'s existing path: open the
`FxCustomParameterActionAPI_v4` scope, set the keypose nearest the playhead via
`KKTimelineSettingValuesNearestFraction`, persist the timeline JSON to
`kKKParamTimelineData`. No new persistence path.

## Implementation

New `_exprControllers` path in `ShaderOSC` (and the mini-viewer `...Set`
counterpart) that:

1. Parses the OSC tab into per-`osc` specs (primitive, binds, forward, inverse,
   per-part rules, style).
2. Instantiates the chosen primitive (by `style=` for `point`).
3. Each draw tick: evaluates the forward map from the current lane value, positions
   the primitive, draws it.
4. Hit-tests the primitive's parts.
5. On drag: runs the primitive's default drag mechanic (or the `drag[part]`
   override), then the inverse map, then writes back.

### Build order

1. The OSC-expression engine: extend `KKLinkExpr` with the OSC vars / `part` /
   `rect`, parse the OSC tab, add the `_exprControllers` draw / hit / drag / write
   path in `ShaderOSC` + mini.
2. First clients: Crop (`box`) and Radius (`point`), proving the two shapes.
3. Everything else: any template builds custom OSCs with zero new Obj-C.

## Decided

- No `crop` / `scale` OSC _kinds_. Crop is `box` + handling. (Primitives, not classes.)
- `box` default drag = anchored resize + body-move (radial is a bijection, not a kind).
- Object space + `aspect`/`size` builtins, not a remapped uniform space.
- Per-part `drag[...]` is a first-class escape hatch, not the common path.
- Inverse map is always authored (no auto-inference in v1).
- OSC block lives in an opt-in editor tab, peer to Image / Buffer A-D.
