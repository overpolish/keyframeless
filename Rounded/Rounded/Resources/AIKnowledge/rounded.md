---
id: rounded
summary: What Rounded does
---

Rounded is a Final Cut Pro plugin that rounds the corners of any clip and crops it with an animatable box. Drop it on a clip from the Effects browser. The plugin exposes two main animatable properties: Radius (corner rounding) and Box (crop region).

Like every Keyframeless plugin, Rounded animates with the shared timeline system. See the timeline docs for how Basic, Advanced, easing, and motion blur work.

## Showing and hiding on-screen controls

Rounded's two on-screen controls - the **Radius** handle (the accent dot on the corner) and the **Box** crop region (its border plus eight corner handles) - can each be hidden to declutter the canvas: the inspector's "On-Screen Controls" tick toggles both, its settings cog has a Radius pill and a Crop pill, and you can Option-click a control on the viewer or mini-canvas to hide it (Option-hold reveals hidden ones as dimmed ghosts to click back). See the shared on-screen-control visibility docs for the full behaviour, including the mouse-movement nuance of the reveal.
