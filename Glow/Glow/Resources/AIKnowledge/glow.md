---
id: glow
summary: What Glow does
---

Glow adds a soft, animatable glow around a clip's content. Drop it on a clip from the Effects browser. It animates with the shared timeline, so see the Timing sections for how Basic, Advanced, easing, and motion blur work.

Parameters are split into two groups (shown as category pills in the inspector): **Core** and **Noise**.

- Core:
  - **Radius** - the size of the glow, in pixels (0 = no glow, up to 500 for a large halo). Has X and Y components, aspect-lockable, so the glow can be a circle or stretched into an oval. The default is 100.
  - **Intensity** - how bright the glow is, 0-300%. 100% is normal; higher pushes the glow brighter. Default 100.
  - **Falloff** - how the glow fades at its edge, 0-200%. 0 is the softest, widest fade; higher tightens the edge. Default 0.
  - **Threshold** - a bloom cutoff, 0-100%. 0 means no bloom; raise it to make the brightest parts of the clip bloom into the glow. Default 0.
  - **Position** - where the glow sits relative to the clip, as an X / Y offset. Centred by default (the glow sits on the clip); drag it to push the glow off to one side. It can be animated so the glow drifts along a path, with a draggable handle and a curved motion path on the canvas.

- Noise - optional grain mixed into the glow for a textured, less perfectly-smooth halo:
  - **Amount** - how much grain is mixed in, 0-100%. 0 is a clean glow; higher breaks the halo up into grain.
  - **Spread** - how far the grain reaches into the glow's falloff, 0-100%. Low keeps grain near the edge; high pushes it through the whole glow.
  - **Grain Size** - the size of each grain speck, 0-100%. Low is fine, tiny grain; high is coarse, chunky grain. Default 50.
  - **Speed** - how fast the grain animates over time, 0-100%. 0 is a static grain; raise it to make the grain shimmer. Default 0.
  - **Seed** - a random value that picks which grain pattern you get; re-roll it for a different look. Not animatable (a fixed pattern for the clip).

Amount, Spread, Grain Size, and Speed animate on the timeline like any other property; Seed is a constant set in the Constants panel / Noise tab.

## Showing and hiding on-screen controls

Glow has two on-screen controls: the **Radius** ring (an ellipse around the clip whose size is the glow radius) and the **Position** handle (a small ring at the glow's centre, with a motion path once Position is animated). The ring follows the Position handle, so moving the glow offset carries the radius ring with it. Either can be hidden to declutter the canvas: the inspector's "On-Screen Controls" tick toggles them all, its settings cog has Radius / Position / Path pills, and you can Option-click a control on the viewer or mini-viewer to hide just that one (Option-hold reveals a hidden control as a dimmed ghost to click back). See the shared on-screen-control visibility docs for the full behaviour, including the mouse-movement nuance of the reveal.
