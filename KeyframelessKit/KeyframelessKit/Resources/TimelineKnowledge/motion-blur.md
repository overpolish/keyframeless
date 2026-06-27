---
id: motion-blur
summary: Motion blur quality (Fast/Accurate), shutter, and samples
---

Motion blur is available on every animatable property. Controls:

- **Quality** (Fast / Accurate): how the blur is computed. Only shown in plugins that support Fast.
  - **Fast** (default where available): per-object velocity-buffer reconstruction. A fixed, low cost that does not grow with the length of the blur, so it stays real-time even on heavy content. Blurs the effect's own animated motion (position, scale, rotation, etc.). The trail length follows the motion - faster motion or a wider shutter gives a longer trail.
  - **Accurate**: sample-and-accumulate (the effect is re-rendered several times across the shutter and averaged). Slower, cost grows with the sample count, but it also smears moving source footage, not just the animated parameters. Use it when you need footage motion blur or maximum fidelity on extreme in-frame rotation.
- **Shutter**: 0° to 360°, default 180°. 0° freezes each frame with no blur, 180° is a half-frame trail (the cinema-standard 180-degree shutter), 360° smears across a full frame interval.
- **Samples**: 2 to 128. Only shown on the Accurate quality (Fast has no sample count - its cost is fixed). Higher gives smoother blur at the cost of render time; the useful range is roughly 2 to 32. The default sample count is plugin-specific.

A still frame (nothing moving across the shutter) is skipped automatically, so motion blur only costs render time on frames that actually move.

Each control has a reset arrow that appears when the value differs from the default.
