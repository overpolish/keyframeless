---
id: timeline-basics
summary: How animation works (lanes, keyposes, intervals, linked endpoints)
---

Animation in this plugin is built around three concepts: lanes, keyposes, and intervals.

A lane is one animatable property (Radius, Box, Position, Color, etc.). Each lane can be enabled or disabled independently from the lane list on the left; a disabled lane holds its constant value and ignores all keyposes.

A keypose is a single value at a single point in time, shown as a circular pill on the lane's track. Keyposes are not keyframes in the FCP sense; they are the anchor points of the animation and you place them wherever the motion should pass through.

An interval is the segment between two adjacent keyposes. Each interval carries its own easing curve and optional modulation (wiggle, oscillate, handheld). When the two endpoints of an interval have different values, the curve tweens between them. When the endpoints are linked, they share one value and the interval becomes a hold; you can still modulate that hold with wiggle or oscillate. Linked keyposes keep values synced between the two.

To make a property animate from value A to value B: place a keypose at value A, place another at value B, and the interval between them does the work. To keep a value still in the middle of an animation, add two keyposes with linked endpoints across the still region.

The lane list on the left shows every animatable property the plugin exposes. Toggle a lane on to start animating it; toggle off to lock it to a constant value.
