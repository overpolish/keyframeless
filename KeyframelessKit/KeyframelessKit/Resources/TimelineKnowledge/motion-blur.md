---
id: motion-blur
summary: Motion blur shutter, samples, and When trigger
---

Motion blur is available on every animatable property. Three controls:

- **Shutter**: 0° to 360°, default 180°. 0° freezes each frame with no blur, 180° is a half-frame trail (the cinema-standard 180-degree shutter), 360° smears across a full frame interval.
- **Samples**: 2 to 128, default 16. Higher gives smoother blur at the cost of render time; the useful range is roughly 2 to 32.
- **When**: a dropdown that controls when the blur is applied:
  - **Transitions only** (default): blur only when the keypose values differ, i.e. during actual motion.
  - **Value changes**: blur whenever any value moves, including subtle modulation on held intervals.
  - **Always**: blur every frame regardless of motion.

Each control has a reset arrow that appears when the value differs from the default.
