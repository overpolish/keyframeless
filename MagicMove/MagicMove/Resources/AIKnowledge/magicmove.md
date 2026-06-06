---
id: magicmove
summary: What Magic Move does
---

Magic Move animates a clip's position, scale, rotation, and opacity around an adjustable anchor point. Drop it on a clip from the Effects browser. It works best on a compound or adjustment clip wrapping your footage, so the move can extend past the clip's edges without being cropped.

Parameters:

  - **Position** - where the clip sits. Add keyposes to move it; with two or more, the clip follows a path you can curve and reshape on the canvas. A per-interval Rotate with Motion toggle leans it into the movement.
  - **Scale** - resize by percentage (X and Y, aspect-locked by default).
  - **Rotation** - spin the clip around the anchor point.
    - The on-screen control rotates in **object** space - the clip turns with its own content.
    - The knobs and value fields rotate in **global** space.
  - **Anchor** - the pivot Rotation and Scale swing around (defaults to the clip centre).
  - **Opacity** - fade the clip, from an inspector slider.

Drive each parameter on the canvas with its on-screen control, or type exact values in the inspector. Stack Crop or similar spatial effects below Magic Move so they travel with the moved clip.
