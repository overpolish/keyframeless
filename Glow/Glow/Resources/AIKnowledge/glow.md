---
id: glow
summary: What Glow does
---

Glow adds a soft, animatable glow around a clip's content. Drop it on a clip from the Effects browser. It animates with the shared timeline, so see the Timing sections for how Basic, Advanced, easing, and motion blur work.

Parameters:

- **Radius** - the size of the glow, in pixels (0 = no glow, up to 500 for a large halo). Has X and Y components, aspect-lockable, so the glow can be a circle or stretched into an oval. The default is 100.

## Showing and hiding on-screen controls

Glow's on-screen control - the **Radius** ring (an ellipse around the clip whose size is the glow radius) - can be hidden to declutter the canvas: the inspector's "On-Screen Controls" tick toggles it, its settings cog has a Radius pill, and you can Option-click the ring on the viewer or mini-viewer to hide it (Option-hold reveals a hidden ring as a dimmed ghost to click back). See the shared on-screen-control visibility docs for the full behaviour, including the mouse-movement nuance of the reveal.
