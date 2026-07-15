---
id: magicmove
summary: What Magic Move does
---

- Magic Move animates a clip's position, scale, rotation, and opacity around an anchor point you can move. Drop it on a clip from the Effects browser. It works best on a compound or adjustment clip wrapping your footage, so the move can reach past the clip's edges without being cropped.
  - **Position** - where the clip sits in the frame. Add keyposes to move it. With two or more, the clip follows a path you can bend and reshape right on the preview. A Rotate with Motion switch leans the clip into its turns.
  - **Scale** - the size, as a percentage. Width and height stay in step unless you unlock them.
  - **Rotation** - spins the clip around the anchor point.
    - The on-screen control turns it in **object** space, so the clip spins with its own content.
    - The knobs and value fields turn it in **global** space.
  - **Anchor** - the point the clip turns and grows around. It starts at the clip's centre.
  - **Opacity** - fades the clip in or out, from a slider in the inspector.
  - **Blur** - softens the clip with a Gaussian blur, from a slider in the inspector. Animate it from or to 0 for a blur-in or blur-out reveal.

Drag each control right on the preview, or type exact numbers in the inspector. Put Crop or similar effects below Magic Move so they travel with the moved clip.
