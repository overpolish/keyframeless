---
id: modulation
summary: Wiggle, Oscillate, and Handheld modulation on intervals
---

Beyond easing, intervals can have modulation that adds movement on top of the underlying curve. The modulation types are:

- None: no modulation, the curve runs straight.
- Wiggle: small random jitter.
- Oscillate: clean sine-wave back-and-forth.
- Handheld: low-frequency, organic shake that mimics handheld camera movement.

Modulation is most useful on intervals with linked endpoints (a held value) where it provides the only motion, but it works on transitioning intervals too and gets layered on top of the curve.

Each modulation type has Intensity and Frequency knobs in the interval editor popover. Intensity controls how far the value moves; Frequency controls how often. Both start at 0.5.

**Make Default** in the popover's title bar saves the modulation, intensity and frequency you are looking at, so every new segment starts there; **Reset** beside it puts the segment back to that saved shape. See the easing page for how the defaults are scoped.

For multi-component properties (X/Y, box edges, etc.), modulation has a Linked toggle: on by default so all components wiggle together, or turn it off and pick specific components to modulate independently.
