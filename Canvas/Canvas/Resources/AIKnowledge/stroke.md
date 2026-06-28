---
id: stroke
summary: Outline a path - width, caps, dashes, markers, draw-on, colour
---

- The Stroke group draws an outline along a vector path. Turn it on with **Enabled**.
  - **Stroke Width** - the line thickness, in points.
  - **Line Cap** - how an open end finishes: butt, round, or square (only on a path with an open end).
  - **Line Join** - how corners turn: miter, round, or bevel.
  - **Stroke Style** - solid, dashed, or dotted. Dashed exposes **Dash Length** and **Dash Gap**; dotted exposes **Dot Gap**. Both expose **Marching Ants Speed** to scroll the pattern along the line (cycles per second).
  - **Start Marker / End Marker** - an endpoint decoration (for example an arrowhead) with its own width, shown when the path has an open end.
  - **Draw On** - reveal the stroke over time. **Draw On Start** and **Draw On End** are the visible fraction of the line (0..1); animate End from 0 to 1 to draw the line on. **Draw On Offset** slides the revealed window. On a multi-contour path each contour reveals in turn.
  - **Colour** - a solid colour or a gradient (with an angle), shared with the kit colour control.

Tip: a line "drawing on" is Draw On End animating from 0 to 1; add an End Marker arrow for an arrow that appears at the tip.
