---
id: rounded
summary: What Rounded does
---

- Rounded rounds off the corners of any clip and crops it with a box you can animate. Drop it on a clip from the Effects browser. It animates with the timeline, so the Timing sections cover how Basic, Advanced, easing, and motion blur work.
  - **Radius** - rounds the corners, from 0% (square) to 100% (fully round, a pill shape on a rectangular clip). Has separate width and height, which you can lock together.
  - **Crop** - trims the clip down to a rectangle with four edges you can animate. Animate it to reveal or hide parts of the clip over time. Combine it with Radius for a rounded crop.

## Showing and hiding on-screen controls

Rounded's two on-screen controls - the **Radius** handle (the white ring on the corner) and the **Box** crop region (its border plus eight corner handles) - can each be hidden to declutter the canvas: the inspector's "On-Screen Controls" tick toggles both, its settings cog has a Radius pill and a Crop pill, and you can Option-click a control on the viewer or mini-viewer to hide it (Option-hold reveals hidden ones as dimmed ghosts to click back). See the shared on-screen-control visibility docs for the full behaviour, including the mouse-movement nuance of the reveal.
