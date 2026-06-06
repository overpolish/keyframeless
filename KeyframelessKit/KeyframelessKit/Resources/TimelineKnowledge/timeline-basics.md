---
id: timeline-basics
summary: How animation works (lanes, keyposes, intervals, linked endpoints)
---

- Animation is built from three things:
  - **Lanes** - one per animatable property (Position, Radius, Color...). Toggle a lane on to animate it, off to hold a constant. The lane list is on the left.
  - **Keyposes** - a value at a point in time, shown as a pill on the lane. Place them wherever the motion should pass through.
  - **Intervals** - the gap between two keyposes. Each carries its own easing curve and optional modulation. Link the endpoints to make the interval a flat hold.

To animate from A to B, drop a keypose at A and another at B; the interval does the rest. To hold still mid-animation, add two keyposes with linked endpoints across the still region.

## How it differs from keyframes

A keypose is not an FCP keyframe - it is an anchor point of the animation, and the interval between adjacent keyposes owns the interpolation. When two endpoints differ, the curve tweens between them; when they are linked, they share one value and the interval becomes a hold you can still modulate with wiggle, oscillate, or handheld. Linked keyposes keep their values synced.

A disabled lane holds its constant value and ignores all keyposes. The lane list on the left shows every animatable property the plugin exposes.
