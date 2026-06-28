---
id: sketch
summary: Give a layer a hand-drawn, rough look
---

- The Sketch group roughens a layer so it looks hand-drawn (the rough.js style). Turn it on with **Sketch Enabled**; it applies to a vector path or an image, never a group.
  - **Sketch Roughness** - how much the outline wobbles off the true path. 0 is clean; higher is scratchier.
  - **Sketch Bowing** - how much straight segments bow out into curves.
  - **Sketch Strokes** - single or double, for one pass or a sketchier double-drawn line.
  - **Sketch Seed** - the random seed. Change it to get a different-but-equivalent rough variation; keep it fixed so the roughness doesn't reshuffle every frame.

Sketch affects the stroke and the fill (the hachure picks up the same jitter), so the whole layer reads as hand-drawn.
