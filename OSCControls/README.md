# OSCControls

Pure C geometry for viewer on-screen controls: the transformed image's footprint, its scale handles, the rotation gizmo and the anchor square. It has no FxPlug, Foundation or Metal dependency, so the math is testable standalone.

- `OSCBoxGeometry` turns a pose (position, scale, Euler rotation, anchor) into object-space corners and handle points, and converts between object, pixel and canvas spaces. It also applies move and scale drags to a press pose.
- `OSCRotationGeometry` builds the render's `Rz * Ry * Rx` pose matrix, samples the three great-circle rings, and turns a screen drag into an object-axis rotation with Cmd snapping and continuous unwrapping.
- `OSCAnchorGeometry` is the anchor-square part: its part number, glyph metrics and the pixel-delta that moves the pivot.

Part numbers are one contiguous range across the three headers (`OSCBoxPartNone`, position, handles, rings, anchor), so one hit test covers the whole control, and `OSCBoxPartKind` classifies a number into its behaviour. `OSCViewer` consumes this package for the FxPlug layer and `RenderSupport` for drawing.

## Tests

```sh
OSCControls/Tests/run.sh
```

Compiles the geometry directly with the sanitizers and checks corners, handles, hit testing, moves, handle scaling, rotation projection and round trips, continuous sweeps, snapping and front-only ring hits.
