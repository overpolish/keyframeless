---
id: glow
summary: What Glow does
---

Glow adds a soft, animatable glow around a clip's content. Drop it on a clip from the Effects browser. It animates with the shared timeline, so see the Timing sections for how Basic, Advanced, easing, and motion blur work.

Parameters are split into two groups (shown as category pills in the inspector): **Core** and **Noise**.

- Core:
  - **Radius** - the size of the glow, in pixels (0 = no glow, up to 500 for a large halo). Has X and Y components, aspect-lockable, so the glow can be a circle or stretched into an oval. The default is 100.

- Noise - optional grain mixed into the glow for a textured, less perfectly-smooth halo:
  - **Amount** - how much grain is mixed in, 0-100%. 0 is a clean glow; higher breaks the halo up into grain.
  - **Spread** - how far the grain reaches into the glow's falloff, 0-100%. Low keeps grain near the edge; high pushes it through the whole glow.
  - **Speed** - how fast the grain animates over time, 0-100%. 0 is a static grain; raise it to make the grain shimmer. Default 0.
  - **Seed** - a random value that picks which grain pattern you get; re-roll it for a different look. Not animatable (a fixed pattern for the clip).

Amount, Spread, and Speed animate on the timeline like any other property; Seed is a constant set in the Constants panel / Noise tab.

## Showing and hiding on-screen controls

Glow's on-screen control - the **Radius** ring (an ellipse around the clip whose size is the glow radius) - can be hidden to declutter the canvas: the inspector's "On-Screen Controls" tick toggles it, its settings cog has a Radius pill, and you can Option-click the ring on the viewer or mini-viewer to hide it (Option-hold reveals a hidden ring as a dimmed ghost to click back). See the shared on-screen-control visibility docs for the full behaviour, including the mouse-movement nuance of the reveal.
