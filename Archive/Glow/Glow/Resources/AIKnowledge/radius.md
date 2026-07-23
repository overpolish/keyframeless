---
id: radius
summary: The Radius property in Glow
---

**Radius** controls the size of the glow - how far the soft halo spreads out from the clip's content. It is measured in pixels, from 0 (no glow) up to 500 (a large, wide halo). The default value is 100.

Radius has X and Y components. In a keypose's value editor, the **Linked** toggle keeps them in proportion when you drag one, so the glow stays a circle; turn it off to spread the glow more horizontally or vertically (an oval). Holding Shift while dragging the ring temporarily inverts the link.

To animate the glow growing or fading, drop a keypose at the starting radius, another at the ending radius, and the interval between them tweens with whatever curve is picked. For one-shot reveals (a glow pulsing on or fading out), **Basic** mode handles this with a single In or Out checkbox; for multi-stage animations (glow in, hold, pulse, fade back to a different size, etc.), switch to **Advanced** and add as many keyposes as you need.

You can also drag the on-screen radius ring on the canvas to set the glow size visually instead of typing a number: the ring's edge follows the cursor. Option-click the ring on the viewer or mini-viewer to hide it (or use its Radius pill in the on-screen-controls settings).
