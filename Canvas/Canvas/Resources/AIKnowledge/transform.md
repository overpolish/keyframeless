---
id: transform
summary: Move, scale, rotate, pivot and fade a layer
---

- Every layer (shape, image, SVG, or group) shares the same Transform properties. Each can be a constant value or animated on the timeline.
  - **Position** - where the layer sits in the frame. Add two or more keyposes to move it along a path you can curve and reshape on the canvas. Normalised space: 0.5, 0.5 is the centre; Y points up.
  - **Scale** - resize by percentage (X and Y). 100% is the layer's natural size; aspect is locked by default.
  - **Rotation** - spin around the anchor. Z is the usual in-plane spin (clockwise positive); X and Y tilt the layer in 3D.
  - **Anchor** - the pivot that Rotation and Scale swing around. Defaults to the layer centre; a group keeps a stored anchor so moving a member never drags the pivot.
  - **Opacity** - fade the layer from 0 (invisible) to 100 (opaque).

Drive Position, Scale and Rotation on the canvas with their on-screen controls (the handle and motion path, the scale box, the rotation rings), or type exact values in the inspector.
