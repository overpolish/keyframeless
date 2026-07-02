---
id: glow
summary: What Glow does
---

Glow wraps a clip's content in a soft, glowing halo you can animate. Drag it onto a clip from the Effects browser. It animates with the timeline, so the Timing sections cover how Basic, Advanced, easing, and motion blur work.

The controls sit in three groups you switch between with the pills at the top of the inspector: **Core**, **Color**, and **Noise**.

- Core:
  - **Radius** - how big the glow is, in pixels, from 0 (no glow) up to 500 (a large halo). It starts at 100. You can lock width and height together for a round glow, or unlock them to stretch it into an oval.
  - **Intensity** - how bright the glow is, from 0 to 300%. 100% is normal and higher makes the glow brighter. Starts at 100.
  - **Falloff** - how the glow fades out at its edge, from 0 to 200%. 0 is the softest, widest fade and higher tightens the edge. Starts at 0.
  - **Threshold** - how much the clip's own bright areas add to the glow, from 0 to 100%. 0 adds nothing. Raise it and the brightest parts of the clip bleed into the glow. Starts at 0.
  - **Position** - where the glow sits relative to the clip. It is centred on the clip to start. Drag it to push the glow off to one side. Animate it and the glow drifts along a path you can shape right on the preview.

- Color - how the glow is tinted:
  - **Mode** - **Dynamic** (the default) borrows colour from the clip so the glow matches whatever is under it. **Solid** is one colour you pick. **Gradient** blends between colours, spreading out from the centre or across at an angle. Solid and Gradient can be animated.

- Noise - optional grain mixed into the glow for a textured halo instead of a perfectly smooth one:
  - **Amount** - how much grain is mixed in, from 0 to 100%. 0 is a clean glow and higher breaks the halo up into grain.
  - **Spread** - how far the grain reaches into the glow, from 0 to 100%. Low keeps grain near the edge and high pushes it through the whole glow.
  - **Grain Size** - how big each speck of grain is, from 0 to 100%. Low is fine, tiny grain and high is coarse, chunky grain. Starts at 50.
  - **Speed** - how fast the grain shimmers over time, from 0 to 100%. 0 holds it still and higher makes it flicker. Starts at 0.
  - **Seed** - the random value that decides which grain pattern you get. Re-roll it for a different look. It cannot be animated, so it stays one fixed pattern for the clip.

Amount, Spread, Grain Size, and Speed can all be animated on the timeline like any other control. Seed stays a fixed value you set in the Constants panel or the Noise tab.

## Showing and hiding on-screen controls

Glow has two on-screen controls: the **Radius** ring (an ellipse around the clip whose size is the glow radius) and the **Position** handle (a small ring at the glow's centre, with a motion path once Position is animated). The ring follows the Position handle, so moving the glow offset carries the radius ring with it. Either can be hidden to declutter the canvas: the inspector's "On-Screen Controls" tick toggles them all, its settings cog has Radius / Position / Path pills, and you can Option-click a control on the viewer or mini-viewer to hide just that one (Option-hold reveals a hidden control as a dimmed ghost to click back). See the shared on-screen-control visibility docs for the full behaviour, including the mouse-movement nuance of the reveal.
