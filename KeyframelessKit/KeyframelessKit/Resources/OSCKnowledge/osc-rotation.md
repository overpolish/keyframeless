---
id: rotation
summary: Rotation on-screen control - the three-ring sphere gizmo
---

# Rotation gizmo

The Rotation OSC is a three-ring sphere that lets the user rotate the clip around all three axes (X, Y, Z) directly on canvas, without typing into number fields. It appears as part of any plugin that exposes a Rotation lane (e.g. Magic Move).

## What the user sees

A sphere built from three coloured rings:

- **Red ring** - rotates around the X axis (tilts the image toward / away from the viewer).
- **Green ring** - rotates around the Y axis (yaws the image left / right).
- **Blue ring** - rotates around the Z axis (rolls the image in-plane). The Z ring is the largest and always faces the viewer because it lies in the screen plane.

All three rings are visible whenever a Rotation lane exists. There's no modifier to show or hide them - the gizmo is always the full sphere so X / Y rotations are reachable with a single click.

## How dragging works

Grab any ring with the mouse and drag. The plugin rotates the clip around that ring's axis in the object's local space - so if the image has already been pitched 30° around X, dragging the Y ring after that yaws it relative to the already-tilted image, not the world. This matches how editors expect transform gizmos to behave in 3D apps.

## Snap key

Hold **Cmd** while dragging a ring to snap rotation to 15° increments. Releasing Cmd returns to free rotation.

## Mini-canvas

In keypose preview popovers (the "constants" or "boundary" popovers above each keypose pill), the same rotation rings appear inside the mini-canvas. Drag behaviour and Cmd snap work identically there - the gizmo is shared code between the FCP viewer and the mini-canvas. The ring sizes scale to fit whatever the popover height is.

