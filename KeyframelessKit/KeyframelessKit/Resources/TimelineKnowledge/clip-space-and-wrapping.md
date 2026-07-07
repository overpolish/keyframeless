---
id: clip-space-and-wrapping
summary: Why effects and the mini-viewer work in the clip's own space, not the canvas, and when to wrap in a compound or adjustment clip
---

A Keyframeless effect runs inside Final Cut's clip render pipeline, which is ordered like this:

leading filters -> THIS EFFECT -> trailing filters -> the clip's spatial conform (Transform, Crop, Distort) -> composite onto the project canvas

The effect only ever sees what is upstream of it. That has a few consequences worth knowing.

## The effect works in the clip's own image space

The image the effect receives is the clip's media in its own frame, before the clip's Video-inspector Transform, Crop, and Distort are applied (those are the very last spatial stage, after every effect), and before the project-canvas conform (the letterbox/pillarbox you get when a clip's aspect differs from the timeline). The mini-viewer preview shows exactly this: the effect applied in clip space.

So:

- A Transform, Crop, or Distort set on the SAME clip in the Video inspector is applied AFTER the effect. It will not appear in the mini-viewer preview, and the effect cannot read those values - Final Cut does not expose a clip's own spatial adjustments to a plugin, only the plugin's own parameters.
- The project canvas is downstream too. A move/scale effect previews in the clip's space, not "the clip with black bars on the canvas". If the clip's aspect matches the timeline there's nothing to reconcile; if it doesn't, the bars are added after the effect.

## What the effect (and preview) DOES see

- Other effect filters stacked ABOVE this effect in the inspector's effect list are baked into the image it receives, so they show in the preview. Filters stacked BELOW it have not been applied yet, so they don't. (The effect still only gets the pre-composited image, not the other filters' parameter values.)

## When to wrap in a compound or adjustment clip

Because the clip's Transform/Crop and the canvas are downstream of the effect, the way to bring them upstream - so they bake into the image the effect receives and the preview matches the viewer - is to wrap:

- Put the transformed/cropped clip INSIDE a compound clip and apply the effect to the compound. Now the inner Transform/Crop is part of the compound's content, upstream of the effect.
- Or apply the effect on an adjustment clip / compound sized to the project canvas, so the effect's clip space equals canvas space. This also lets a move or scale extend past the original clip's edges instead of being cropped to its bounding box.

Applying the effect and the Transform on the same clip always renders the effect first, so the Transform won't be reflected in the effect or its preview - that's expected, not a bug.
