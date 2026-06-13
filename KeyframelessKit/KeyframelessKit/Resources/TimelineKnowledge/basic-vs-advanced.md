---
id: basic-vs-advanced
summary: Basic timing vs Advanced timing modes
---

- Every property has two timing modes, switched with the pill at the top of its row:
  - **Basic** - three checkboxed phases (**In**, **Hold**, **Out**) for a simple ease-in, hold, ease-out. Drag the hold boundary to move where In ends and Out begins. Right-click a boundary pill (the In start, either hold edge, or the Out end) for Copy Values / Paste Values: this copies that boundary's pose across every animated property at once, so you can, for example, copy the start pose and paste it onto the end. Paste only fills properties whose type matches the copied data.
  - **Advanced** - the full keyposes + intervals model: any number of keyposes, each interval with its own curve and modulation. Use it for multi-step motion or custom holds.
- Advanced timeline only:
  - The **Dynamic** toolbar toggle widens short transitions so they stay easy to grab on a long clip; each lane then shows its own playback line. It's display-only, off by default, and never changes the animation.
  - The **Maintain Timing** toolbar toggle is a lock that pins the animation to absolute time: trimming, growing, or splitting the clip then retimes the keyposes to hold their position instead of stretching with the clip, and a split stays continuous across the cut. It bakes the retime into the data, so it persists when you turn the lock off.

## Switching between modes

Basic to Advanced is always allowed - your Basic setup converts to the equivalent keyposes and intervals. Advanced back to Basic is only allowed when the Advanced state fits the three-phase model (roughly two keyposes with simple in/out shaping); otherwise the pill offers **Switch Anyway**, which resets the lane to the default two-keypose Basic setup and discards the Advanced configuration.
