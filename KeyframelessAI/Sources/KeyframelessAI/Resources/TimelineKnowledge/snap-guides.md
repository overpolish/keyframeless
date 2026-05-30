---
id: snap-guides
summary: Magnetic snapping and the yellow / accent guide lines
---

When you drag a positional on-screen control (the viewer OSC or the mini-canvas handle), the plugin runs a snap engine that catches values you probably meant to land on. Coloured guide lines appear while a snap is active so you can see which target you locked onto.

Two kinds of snap:

- **Canvas anchors** - fixed reference values for the clip frame (the centre, the edges, and the thirds). Guides for these are drawn yellow. Use them to centre an effect, align it to a frame edge, or place it on a rule-of-thirds line.
- **Object targets** - values held by other keyposes on the same lane. Guides for these are drawn in the host accent colour (FCP blue or whatever your system accent is). Use them when you want one keypose to share an X or Y with another - handy for a back-and-forth bounce that returns to the same column, or to make a loop's last keypose match the first.

X and Y are tracked independently, so one axis can snap to a canvas anchor while the other snaps to a keypose. The two guide colours can appear together.

Hold Command while dragging to bypass snapping when you need fine pixel control. Releasing the mouse clears all guides.

Snap thresholds are measured in screen pixels from the cursor, so they feel the same whether you're zoomed in or out.

Not every plugin uses snap - it's available on properties where landing on a meaningful value matters (position, anchor, etc.). If you don't see guides while dragging, the property doesn't have snap targets.
