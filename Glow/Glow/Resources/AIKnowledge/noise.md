---
id: noise
summary: The Noise group in Glow (Amount, Spread, Speed, Seed)
---

Noise mixes grain into the glow so the halo looks textured and organic instead of a perfectly smooth gradient. It is off by default (Amount 0). The four controls live in the **Noise** category (a pill next to **Core** in the inspector).

- **Amount** (0-100%) is the master switch for the effect: 0 is a clean glow, and higher values break the halo up into more grain. Nothing else in the group does anything while Amount is 0.
- **Spread** (0-100%) controls how far the grain reaches into the glow. Low values keep the grain out near the soft edge of the halo; high values push it through the whole glow toward the centre.
- **Speed** (0-100%) animates the grain over time. 0 leaves it static; raising it makes the grain shimmer/move while the clip plays. It defaults to 0, so the noise is still unless you ask for movement.
- **Seed** is a random number that selects which grain pattern you get. Re-roll it (the shuffle button on its field) to try a different pattern, or type a value to pin one. Because the grain is decorative rather than positional, Seed is not animatable - it is a single constant for the whole clip, set in the Constants panel or the Noise tab of a keypose editor.

Amount, Spread, and Speed are normal animatable lanes: drop keyposes to fade the grain in, ramp the spread, or change the shimmer speed across the clip, the same way you animate Radius. Seed is the one exception - it stays a fixed value.

The grain is resolution-independent: it looks the same in the inspector mini-viewer and the final render, and an export at a different resolution keeps the same grain size.
