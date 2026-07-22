---
id: osc-blocks
summary: Authoring fully custom on-screen controls in a Custom shader with // @osc blocks - primitives, forward/inverse expressions, builtins
---

# Custom on-screen controls: `// @osc` blocks

The `osc=` attribute on a directive (see the directives doc) is the **easy path**: `osc=point`, `osc=ring`, `osc=box`, `osc={z}` each drop a standard control on the value with no math to write. Those attributes are **sugar** - under the hood each one is expanded into a standard `// @osc` block. This doc is the **full path**: when a control needs a bespoke shape or mapping (a radius handle that sits at a corner, a crop box, a ring whose value isn't its radius), you author the block yourself.

A block builds a control out of a fixed **primitive** (the engine owns its drawing, hit-testing, and drag feel) plus **expressions** that map the lane value to the primitive's geometry and back. There is no per-shader Obj-C: a crop box is the `box` primitive plus a value-to-rectangle mapping, a radius handle is the `point` primitive plus a value-to-position mapping.

```glsl
// #float label="Radius" min=0 max=1 default=0.3
uniform float uRadius;

// @osc Radius
//   primitive = point
//   binds     = uRadius
//   style     = square
//   toPos     = tr - vec2(uRadius) * vec2(aspect, 1.0)   // value -> handle position
//   fromPos   = length((tr - pos) / vec2(aspect, 1.0))   // dragged position -> value
```

That places a square handle inset from the top-right corner by `uRadius`, and dragging it writes the distance back to the lane. The `#float` still gives the inspector its slider; the block only adds the on-screen handle.

## How blocks relate to the `osc=` sugar

- Every `osc=` attribute is synthesized into a standard block, so authored blocks and sugar run through **one** code path and sit / drag identically.
- An authored `// @osc` block **that binds a uniform suppresses that uniform's sugar** - the author wins. So to customise `osc=ring`, drop `osc=ring` from the directive (or keep it and let the block override) and write the block.
- Reach for a block only when the sugar's default shape or mapping isn't what you want. A plain position, a radius-is-the-value ring, or a Z-rotation dial need no block at all.

## Block syntax

A block lives in `//` comments (so the GLSL stays valid) and looks like directive comments:

```glsl
// @osc <Name>
//   key = value
//   key = value
```

- It **starts** at a `// @osc <Name>` line. `<Name>` is the control's display name and its hideable-element key in the viewer's On-Screen Controls settings. A trailing `{` on the header is allowed and ignored.
- It **continues** through following `//   key = value` comment lines.
- It **ends** at the first non-comment line, a blank comment line, a `//   }` line, or the next `// @osc`. (So separate each block from the next with a blank line or a `}`.)
- Up to **8** blocks per shader, up to **12** locals per block.

Put the block anywhere in the source; it doesn't have to sit next to the uniform it binds (though next to it reads best).

## Fields

| Field          | Applies to           | Meaning                                                                                    |
| -------------- | -------------------- | ------------------------------------------------------------------------------------------ |
| `primitive`    | all                  | `point` / `position` / `ring` / `box` / `rotate`. Required.                                |
| `binds`        | all                  | The uniform (lane) the control edits. Required.                                            |
| `style`        | point                | Glyph look: `dot` / `square` / `hollow` / `arc`. Default `dot`.                            |
| `cursor`       | all                  | Hover cursor: `move` / `crosshair` / `pointing` / `resize-h` / `resize-v` / `resize-diag`. |
| `skipsnapping` | point                | Bare flag (or `= true`) opting the handle out of the default Cmd-held snap (see below).    |
| `toPos`        | point                | Forward: value -> handle position (object space).                                          |
| `fromPos`      | point                | Inverse: dragged position (`pos`) -> value. Optional (see below).                          |
| `toR`          | ring                 | Forward: value -> radius/radii, in min-side fractions.                                     |
| `fromR`        | ring                 | Inverse: dragged radius (`r`) -> value. Required for a ring.                               |
| `toRect`       | box                  | Forward: value -> rectangle (`rect(min, max)`).                                            |
| `fromRect`     | box                  | Inverse: dragged rectangle (`rect`) -> value. Required for a box.                          |
| `center`       | ring / rotate        | Object-space placement. A bare point-uniform name follows it live. Default = frame centre. |
| `axes`         | rotate               | Enabled axis subset, e.g. `z` / `y x` / `z x y`. Default `z`.                              |
| `linked`       | ring / box (2-field) | `true` aspect-links the two components (Shift inverts during a drag).                      |
| `body`         | box                  | `none` disables the interior body-move (a centred box has no position to write).           |
| any other      | all                  | A **local variable** (see Locals).                                                         |

Forward and inverse names are per-primitive but interchangeable in the parser - `toPos`/`toR`/`toRect` all set the forward; `fromPos`/`fromR`/`fromRect` all set the inverse. Use the one that reads right for the primitive.

## Coordinate model

Expressions run in **object space**: normalized `0..1` on each axis, origin **bottom-left, Y-up** - the same space as directive `center=`, `#point` lanes, and the shader's `fragCoord / iResolution`. It is per-axis normalized, so it is **aspect-distorted**: a circle of equal radius in x and y is an ellipse on a non-square frame. Correct for that explicitly with `aspect` when a handle is radial:

```
toPos = tr - vec2(uRadius) * vec2(aspect, 1.0)   // equal pixel inset in x and y
```

The engine converts object -> canvas -> screen for you; you only ever work in object space.

## Builtins

**Variables:**

- `mouse` / `pos` - the drag position in object space (the two names are equal; `pos` reads naturally in `fromPos`).
- `tl` `tr` `bl` `br` - frame corners (`bl` = `(0,0)`, `tr` = `(1,1)`).
- `center` - frame centre `(0.5, 0.5)`.
- `size` - frame size in media pixels; `aspect` - `size.x / size.y`.
- `r` - the dragged radius (min-side fractions) inside `fromR`.
- `rect` - the dragged rectangle inside `fromRect`; read `rect.min`, `rect.max`, `rect.width`, `rect.height` (and `.min`/`.max` are points, so `rect.min.x` etc).
- `part` - the sub-part being dragged (a corner / edge / handle name), for expressions that branch on it.
- `pi` - 3.14159.

**Functions:** `vec2(x,y)`, `rect(min,max)`, `ringExtent(norm)`, `ringNorm(r)`, `length`, `normalize`, `distance`, `dot`, `mix`, `clamp`, `min`, `max`, `pow`, `sqrt`, `sin`, `cos`, plus the standard KKLinkExpr operators (`+ - * / %`, comparisons, `&&` `||`, ternary, swizzles).

`ringExtent(norm)` / `ringNorm(r)` expose the **shared radius-ring curve** in min-side fractions, so an authored ring sits exactly where a built-in `osc=ring` does. Use them when you want the standard feel with a non-standard value mapping.

## Locals

Any `key = value` line whose key isn't a reserved field is a **local variable**. Locals are evaluated in declaration order and a later one may reference earlier ones (plus the bound value and the builtins), so a dense forward reads as a few named steps:

```glsl
// @osc Radius
//   primitive = point
//   binds     = uRadius
//   inset     = vec2(uRadius) * vec2(aspect, 1.0)
//   toPos     = tr - inset
//   fromPos   = length((tr - pos) / vec2(aspect, 1.0))
```

## The primitives

### `point` - a draggable handle

`toPos` places the handle; `fromPos` reads a drag back to the value. `binds` may be a scalar (a radius, an offset magnitude) or a `vec2` (a position). `style` picks the glyph; `cursor` the hover cursor.

`fromPos` is **optional for a scalar** value: with it omitted, a drag **numerically inverts** `toPos` (it searches the value whose handle-position is nearest the cursor), so a non-linear forward needs no hand-written inverse. A `vec2` point should author `fromPos`.

**Snapping.** Every point handle snaps by default, exactly like `osc=position`: hold **Cmd** while dragging and the handle snaps to the canvas centre / edges / quarters and onto the other point and position handles, with guides. (Position handles likewise snap onto point handles.) Add `skipsnapping` to a block to opt its handle out.

```glsl
// #point label="Corner" osc=... default="0.5,0.5"
uniform vec2 uCorner;

// @osc Corner
//   primitive = point
//   binds     = uCorner
//   style     = dot
//   toPos     = uCorner            // point value IS its position
//   fromPos   = pos
```

### `position` - the full motion path

`primitive = position` backs a point with the complete position control: the playhead handle, an **editable motion path** through the keyposes, tangents, and anchors. It is **declaration-only** - `binds` must be a `#point` lane, and there are no `toPos`/`fromPos` (the control _is_ the lane, you can't remap it).

```glsl
// #point label="Position" osc=position default="0.5,0.5"
uniform vec2 uPosition;

// @osc Position
//   primitive = position
//   binds     = uPosition
```

This is what a bare `osc` / `osc=position` on a `#point` synthesizes. Use a `point` block instead when you want just a dot (a centre, an offset) rather than a keyframable path.

### `ring` - a radius ellipse

`toR` gives the radius (scalar `binds` -> a **circle**) or radii (`vec2` `binds` -> an **ellipse**), in **min-side fractions** (multiply by the frame's shorter side for pixels). `fromR` reads the dragged radius `r` back to the value and is **required**. `center` places it; `linked` aspect-locks an ellipse.

```glsl
// #percent label="Spread" min=0 max=100 default=40
uniform float uSpread;

// @osc Spread
//   primitive = ring
//   binds     = uSpread
//   center    = uPivot              // follow a #point uniform live
//   toR       = ringExtent(uSpread) // uSpread is 0..1 here; standard curve
//   fromR     = ringNorm(r)
```

### `box` - a rectangle with handles

`toRect` builds the rectangle with `rect(min, max)` (two object-space corner points); `fromRect` reads the dragged `rect` back to the value and is **required**. The primitive owns the 8-handle **anchored resize** (the grabbed handle moves, the opposite one stays fixed) plus interior **body-move** - `toRect`/`fromRect` is the whole contract, you never write per-handle math. `linked` holds the aspect ratio; `body = none` makes the interior inert (for a centred box that has no position to store).

```glsl
// #multi label="Crop" fields={W,H,X,Y} units={px,px,px,px} default="1,1,0,0"
uniform vec4 uCrop;                   // W,H,X,Y as top-left 0..1

// @osc Crop
//   primitive = box
//   binds     = uCrop
//   toRect    = rect(vec2(uCrop.z, 1.0 - uCrop.w - uCrop.y),
//                    vec2(uCrop.z + uCrop.x, 1.0 - uCrop.w))
//   fromRect  = vec4(rect.width, rect.height, rect.min.x, 1.0 - rect.max.y)
```

A **centred** box (size only, no position) uses `body = none` and maps both extents from the centre:

```glsl
// @osc Size
//   primitive = box
//   binds     = uSize
//   body      = none
//   toRect    = rect(center - uSize * 0.5, center + uSize * 0.5)
//   fromRect  = rect.max - rect.min
```

### `rotate` - rotation rings

`primitive = rotate` draws one ring per enabled axis. It is **placement-only** - `binds` + `axes` + optional `center`; the gizmo owns its drag math and persistence (there is no `to`/`from`). The **Nth listed axis drives value component N**, tinted X=red, Y=green, Z=blue. Each axis reaches the shader as **radians, negated**.

```glsl
// #multi fields={Yaw,Pitch,Roll} default="0,0,0"
uniform vec3 uOrient;

// @osc Orient
//   primitive = rotate
//   binds     = uOrient
//   axes      = z x y             // value.x=Z, value.y=X, value.z=Y
//   center    = uPivot
```

This is what `osc={z,x,y}` synthesizes.

## What's not (yet) here

- **Per-part `drag[...]` overrides** (a rule scoped to one handle) are described in the design spec but **not implemented** - don't emit them.
- A `ring` or `box` **must** author its inverse (`fromR` / `fromRect`); only a scalar `point` has the numeric-inversion fallback.

## Worked example: pivot + ring + rotation, all custom

```glsl
// A pivot the ring and the rotation both follow.
// #point label="Pivot" osc default="0.5,0.5"
uniform vec2 uPivot;

// A radius ring centred on the pivot, value 0..1.
// #float label="Radius" min=0 max=1 default=0.3
uniform float uRadius;

// @osc Radius
//   primitive = ring
//   binds     = uRadius
//   center    = uPivot
//   toR       = ringExtent(uRadius)
//   fromR     = ringNorm(r)

// Three rotation rings on the pivot.
// #multi fields={Yaw,Pitch,Roll} default="0,0,0"
uniform vec3 uOrient;

// @osc Orient
//   primitive = rotate
//   binds     = uOrient
//   axes      = z x y
//   center    = uPivot
```

Editing any block live re-derives its control without a clip reselect - add, rename, or re-map a block and the viewer updates on the next commit.
