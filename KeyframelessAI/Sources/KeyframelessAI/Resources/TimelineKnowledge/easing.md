---
id: easing
summary: Easing curves on intervals (Linear, Ease, Elastic, Bounce)
---

Each interval in Advanced mode has its own easing curve. The available curves are:

- Linear: uniform motion across the interval.
- Ease In: starts slow, accelerates into the next keypose.
- Ease Out: starts fast, decelerates into the next keypose.
- Ease In/Out: slow on both ends, faster in the middle. This is the default.
- Elastic: overshoots and oscillates before settling. Has Intensity and Frequency knobs.
- Bounce: settles with a few decreasing bounces. Has Intensity and Frequency knobs.

Click an interval (the gap between two keyposes) in the timeline to open its editor and pick the curve. Multi-select intervals first with Shift-click to apply a curve to several at once.

In Basic mode, each of the In and Out phases has a single curve picker; the Hold phase has no curve (it's a flat value, optionally modulated).
