---
id: radius
summary: The Radius property in Shader
---

**Radius** rounds the corners of the clip. It animates from 0% (square corners) up to 100% (fully circular if the clip is square; pill-shaped on rectangular clips). The default value is 20%.

Radius has X and Y components. In a keypose's value editor, the **Linked** toggle keeps them in proportion when you drag one; turn it off to round only horizontally or vertically.

To animate the corners rounding in or out, drop a keypose at the starting radius, another at the ending radius, and the interval between them tweens with whatever curve is picked. For one-shot reveals, **Basic** mode handles this with a single In or Out checkbox; for multi-stage animations (round in, hold, round out, round back to a different value, etc.), switch to **Advanced** and add as many keyposes as you need.

You can also drag the on-screen handle on the canvas to set the radius visually instead of typing a number. Option-click the handle on the viewer or mini-viewer to hide it (or use its Radius pill in the on-screen-controls settings).
