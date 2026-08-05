---
id: easing
summary: Easing curves on intervals (Linear, Ease, Elastic, Bounce)
---

- Easing sets how a move speeds up and slows down. Each Advanced interval has one. Click the interval to pick it (Shift-click to choose several first):
  - **Linear** - steady speed the whole way.
  - **Ease In** - starts slow, then speeds up.
  - **Ease Out** - starts fast, then slows down.
  - **Ease In/Out** - eases at both ends (the default until you save your own).
  - **Elastic** - overshoots and wobbles before settling.
  - **Bounce** - lands with a few smaller and smaller bounces.

Each pill draws the curve it applies and is named underneath, so a shape you can barely see at low intensity is still identifiable.

Elastic and Bounce add Intensity and Frequency rows to dial in the wobble - each a slider with a number field beside it, so you can drag for feel or type an exact value. Frequency only appears on the curves that use it.

## Your own default

The curve popover's title bar carries **Make Default**. It saves the curve, intensity and frequency you are looking at, and every transition you create from then on starts there instead of at Ease In/Out. Existing animations are untouched.

**Reset** sits beside it and puts the segment back to the saved default in one undo step. Both buttons disappear while the segment already is the default, since there is nothing to save and nothing to go back to.

Defaults are per plugin, so Canvas and Mirage keep their own, and in Mirage they are per shader template as well. The modulate popover has the same pair, saving its own modulation, intensity and frequency.

## In Basic mode

Each of the In and Out phases has its own curve picker; the Hold phase has no curve (it is a flat value, optionally modulated).
