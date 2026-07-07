---
id: constants-panel
summary: The Constants panel for values that don't animate
---

The Constants panel is where you edit values that aren't animated. Every plugin exposes one for the property values that should stay fixed for the whole clip - the value that the lane would hold if it were locked off.

The Constants panel uses the same value-editor popover as keyposes. The only difference is that the value applies to the whole clip.

Use Constants when you want to set a static look (a fixed radius, a fixed crop) without engaging the animation system at all. If you later decide to animate that property, enable the lane and add keyposes; the constant becomes the starting point.

The Constants popover's mini preview shows the frame at the current playhead, not the first frame of the clip. This matters when another property is animated to start off-screen (for example a position that flies in): at the first frame the object can sit outside the visible area, making it harder to get to the on-screen controls. Previewing at the playhead keeps the object where you can see it. Park the playhead on the frame you want to judge before opening the panel. The constant values you set still apply to the whole clip regardless of which frame is previewed.
