---
id: mini-canvas
summary: The mini-canvas preview with OSC, zoom, pan, filmstrip and onion skin
---

The mini-canvas is the live preview inside the value-editor popover. It exists so you can frame and adjust your effect at any zoom level without fighting FCP's viewer constraints. Most parameters that have a spatial component (radius handle, box edges, position, gradient stops) expose draggable on-screen controls directly on the mini-canvas.

Interactions:

- Scroll-wheel/pinch to zoom in and out, anywhere over the canvas.
- Two-finger drag to pan around the zoomed view.
- Double-click the canvas, or click the Reset Zoom button in the inspector header, to snap zoom and pan back to aspect-fit.
- Click and drag any on-screen handle (radius dot, crop edges, stop markers, etc.) to set the value visually instead of typing or sliding.
- Option-click a handle to hide that on-screen control (plugins that support per-control visibility, like Magic Move). Hold Option to reveal hidden controls as dimmed ghosts, and Option-click a ghost to bring it back. The reveal follows mouse movement, so hold Option and nudge the mouse to see the ghosts; holding the key dead-still won't show them until you move.

The canvas also has two additional render modes, toggled from the header pill:

- Filmstrip lays every keypose out side by side so you can see the whole animation in one view. Click an inactive cell to select that keypose and edit it. Linked keyposes show up as a single cell.
- Onion skin overlays the surrounding keypose frames on top of the current one with red and blue tinting (previous in red, next in blue) so you can see how the motion progresses.

The OSC handles also work inside the main FCP viewer, not just the mini-canvas, so once you're comfortable you can drag the same controls on the full-size canvas.

The preview renders in the clip's own image space - it shows the effect applied to the clip's media, but not the clip's own Video-inspector Transform/Crop/Distort or the project-canvas letterbox, since Final Cut applies those after the effect. See the clip-space-and-wrapping topic for why, and when to wrap in a compound or adjustment clip so the preview matches the viewer.
