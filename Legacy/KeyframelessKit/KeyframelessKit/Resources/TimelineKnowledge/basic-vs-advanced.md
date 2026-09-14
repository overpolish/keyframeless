---
id: basic-vs-advanced
summary: Basic timing vs Advanced timing modes
---

- Every property has two timing modes, switched with the pill at the top of its row:
  - **Basic** - three simple stages you tick on or off: **In**, **Hold**, **Out**. This gives you an ease in, a hold, then an ease out. Drag the hold boundary to change where In ends and Out begins. Right-click a boundary pill (the In start, either edge of the hold, or the Out end) for Copy Values / Paste Values. This copies that moment's look across every animated property at once, so you can, for example, copy the start and paste it onto the end. Paste only fills properties that match the kind of value you copied.
  - **Advanced** - the full keyposes and intervals setup: as many keyposes as you like, each interval with its own easing and extra motion. Use it for motion with several steps or custom holds.
- Advanced timeline only:
  - The **Dynamic** toolbar toggle stretches out short moves so they stay easy to grab on a long clip, and each lane gets its own playback line. It only changes how the timeline looks, is off to start, and never changes the animation.
  - The **Maintain Timing** toolbar toggle is a lock that pins the animation to real clip time. With it on, trimming, lengthening, or splitting the clip keeps each keypose at its moment instead of stretching everything, and a split stays smooth across the cut. It writes the new timing into the clip, so it sticks even after you turn the lock off.

## Switching between modes

Basic to Advanced is always allowed - your Basic setup converts to the equivalent keyposes and intervals. Advanced back to Basic is only allowed when the Advanced state fits the three-phase model (roughly two keyposes with simple in/out shaping); otherwise the pill offers **Switch Anyway**, which resets the lane to the default two-keypose Basic setup and discards the Advanced configuration.
