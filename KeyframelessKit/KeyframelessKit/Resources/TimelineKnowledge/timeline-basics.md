---
id: timeline-basics
summary: How animation works (lanes, keyposes, intervals, linked endpoints)
---

- Animation is built from three things:
  - **Lanes** - one row per property you can animate (Position, Radius, Color, and so on). Turn a lane on to animate that property, off to keep it fixed. The lane list is on the left.
  - **Keyposes** - a value set at a moment in time, shown as a pill on the lane. Drop one wherever you want the motion to hit a certain look.
  - **Intervals** - the stretch between two keyposes. Each interval has its own easing (how it speeds up and slows down) and can add extra motion on top. Link the two ends to turn the interval into a still hold.

To move from one look to another, drop a keypose where it starts and another where it ends. The interval fills in the motion between them. To pause the motion in the middle, add two keyposes with linked ends across the part you want to hold still.

## How it differs from keyframes

A keypose is not an FCP keyframe - it is an anchor point of the animation, and the interval between adjacent keyposes owns the interpolation. When two endpoints differ, the curve tweens between them; when they are linked, they share one value and the interval becomes a hold you can still modulate with wiggle, oscillate, or handheld. Linked keyposes keep their values synced.

A disabled lane holds its constant value and ignores all keyposes. The lane list on the left shows every animatable property the plugin exposes.
