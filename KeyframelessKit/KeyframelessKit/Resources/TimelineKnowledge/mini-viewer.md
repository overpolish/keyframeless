---
id: mini-viewer
summary: The mini-viewer preview with OSC, zoom, pan, filmstrip and onion skin
---

The mini-viewer is the live preview inside the constants and keypose editor panel. It exists so you can frame and adjust your effect at any zoom level without fighting FCP's viewer constraints. Most parameters that have a spatial component (radius handle, box edges, position, gradient stops) expose draggable on-screen controls directly on the mini-viewer.

Interactions:

- Scroll-wheel/pinch to zoom in and out, anywhere over the canvas.
- Two-finger drag to pan around the zoomed view.
- Double-click the canvas, press Cmd-0 while the mini-viewer is open, or click the Reset Zoom button in the inspector header, to snap zoom and pan back to aspect-fit. (Cmd-0 also passes through to Final Cut Pro, so if you have assigned Cmd-0 to a custom command in Final Cut it will trigger that too; there is no default Final Cut Cmd-0, so normally nothing clashes.)
- Click and drag any on-screen handle (radius dot, crop edges, stop markers, etc.) to set the value visually instead of typing or sliding.
- Option-click a handle to hide that on-screen control (plugins that support per-control visibility). Hold Option to reveal hidden controls as dimmed ghosts, and Option-click a ghost to bring it back. If the master On-Screen Controls tick is off (everything hidden), Option-hold instead "peeks": the controls you left enabled reappear at full strength and are draggable so you can tweak them, then hide again when you release Option (nothing is turned back on permanently). The reveal follows mouse movement, so hold Option and nudge the mouse to see the controls; holding the key dead-still won't show them until you move. See the on-screen-control visibility docs for the full behaviour.

The canvas also has two additional render modes, toggled from the header pill:

- Filmstrip lays every keypose out side by side so you can see the whole animation in one view. Click an inactive cell to select that keypose and edit it. Linked keyposes show up as a single cell.
- Onion skin overlays the surrounding keypose frames on top of the current one with red and blue tinting (previous in red, next in blue) so you can see how the motion progresses.

While an editor is open, the preview also follows playback. Play back or scrub the timeline and the preview tracks the playhead - the footage and the effect move together - while its on-screen controls hide so you get a clean moving frame. When you stop it snaps back to the frame you're editing, controls and all. So you can watch the animation run without closing the editor to get back to Final Cut's viewer. (The footage only keeps advancing while Final Cut is actually rendering the clip; once it has cached the playback it may hold the last frame, the same as any effect preview.)

The mini-viewer only receives the current clip. To check the whole composition, hold the layered-rectangles button beside Close, or hold P. The editor panel disappears while held so Final Cut's own viewer is visible, then returns to the same keypose, constant, curve, or modulation when released. Editor panels stay open while you work elsewhere in Final Cut; close them with their Close button or Esc.

For longer edits against the full composition, press V or use the compact-editor button. Constants and Keypose stay open with their parameters available, but the mini-viewer is removed so the panel can sit under Final Cut's main viewer. Parameter drags update Final Cut's composition viewer live in both full and compact modes. Press V again to restore the mini-viewer and its previous expanded size.

Mirage mirrors its small Before, Split and Show Selection toolbar in the top-left of Final Cut's main viewer. The buttons and B/S/M shortcuts share state with the mini-viewer, so compact mode does not remove the comparison tools.

Drag empty space or the decorative title in an editor's title bar to put it where you want. Curve and modulation remember one position, while Constants and keypose remember another. The Constants/keypose panel can be resized from any edge or corner. The viewer fills its whole canvas and takes priority over parameter rows, which scroll when they need more room. A code editor grows alongside the viewer up to 250pt, then further growth belongs to the viewer. Its size and both panel positions are remembered.

The sidebar button beside composition peek, or the L key, hides and shows the plugin's main companion browser: templates in Mirage and layers in Canvas. It is shown by default. Compact mode and both sidebar visibility choices are remembered after Final Cut restarts.

Mirage has a second, right-sidebar button for the grading panel. Use it or press G to hide and restore grading without closing the editor. This button is plugin opt-in, so Canvas does not show it.

The OSC handles also work inside the main FCP viewer, not just the mini-viewer, so once you're comfortable you can drag the same controls on the full-size canvas.

The preview renders in the clip's own image space - it shows the effect applied to the clip's media, but not the clip's own Video-inspector Transform/Crop/Distort or the project-canvas letterbox, since Final Cut applies those after the effect. See the clip-space-and-wrapping topic for why, and when to wrap in a compound or adjustment clip so the preview matches the viewer.
