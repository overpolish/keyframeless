---
id: rounded
summary: What Rounded does
---

Rounded rounds the corners of any clip and crops it with an animatable box. Drop it on a clip from the Effects browser. It animates with the shared timeline, so see the Timing sections for how Basic, Advanced, easing, and motion blur work.

Parameters:

- **Radius** - rounds the corners, from 0% (square) to 100% (fully round; pill-shaped on a rectangular clip). Has X and Y components, aspect-lockable.
- **Crop** - crops the clip to a rectangle with four animatable edges. Animate it to reveal or hide content over time; combine with Radius for a rounded crop region.

## Showing and hiding on-screen controls

Rounded's two on-screen controls - the **Radius** handle (the accent dot on the corner) and the **Box** crop region (its border plus eight corner handles) - can each be hidden to declutter the canvas: the inspector's "On-Screen Controls" tick toggles both, its settings cog has a Radius pill and a Crop pill, and you can Option-click a control on the viewer or mini-viewer to hide it (Option-hold reveals hidden ones as dimmed ghosts to click back). See the shared on-screen-control visibility docs for the full behaviour, including the mouse-movement nuance of the reveal.
