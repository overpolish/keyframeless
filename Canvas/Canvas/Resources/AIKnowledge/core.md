---
id: core
summary: A layer's shape and points
---

- The Core group is the layer's geometry - the path itself.
  - **Points** - the path's anchor points and their bezier handles. Edit them with the pen tool: drag a point to move it, drag a handle to curve the segment, double-click a point to toggle it between a corner and a smooth point. Animating Points morphs the shape over time (the point count is carried across keyposes so the shape interpolates cleanly).
  - **Corners** - a path can carry a corner radius that rounds its hard corners; the rounding follows the contour and rebuilds when you edit points.
  - **Multi-contour paths** - a boolean result, an imported SVG, or a centerline trace can hold several disconnected subpaths in one layer. They render, round, and reveal (draw-on) independently.

Create geometry by drawing with the pen tool, dragging out a rectangle or ellipse, importing an SVG, or tracing an image's centerline. Images and groups have no editable Points - they show the transform gizmo instead.
