---
id: shortcuts
summary: Mouse and keyboard shortcuts for the Advanced timeline
---

Advanced mode shortcuts on the timeline canvas:

Keyposes:

- Click a keypose to select it and open its value editor popover.
- Shift-click adds or removes a keypose from the multi-selection.
- Option-click on a keypose deletes it (eraser).
- Option-drag a keypose to duplicate it; the duplicate snaps to other keyposes on release.
- Drag a keypose (or a multi-selection) to move it; it snaps to nearby keyposes on the same lane and across lanes.
- Cmd-click an empty spot on the lane to add a new keypose at that time.

Intervals (the gap between two keyposes):

- Click a gap to select it and open the interval editor (curve + modulation).
- Shift-click adds or removes a gap from the multi-selection.
- Right-click a gap for Link Endpoints / Unlink Endpoints. Linked endpoints share one value so the interval becomes a hold; unlinked endpoints animate via the curve.

Marquee selection:

- Click and drag on empty timeline space to marquee-select keyposes. Shift-drag adds to the existing selection instead of replacing it.

Multi-selection actions (right-click on the selection):

- Reverse: mirror the times of the selected keyposes around their midpoint.
- Distribute Evenly: space the selected keyposes equally.
- Delete: remove them all. The Delete key does the same.

Snapping: a small guide line appears when a dragged keypose comes within a few pixels of another keypose, so getting motion aligned across lanes is straightforward.

Playback while editing:

- Spacebar plays or pauses FCP's playhead so you can scrub through your animation without leaving the inspector.
- Cmd-Z and Cmd-Shift-Z undo and redo any edit, including ones made inside popovers.

Inside popovers:

- Return commits the number field you're typing in.
- Esc cancels the in-progress edit and closes the popover.
- Double-click the mini-canvas to reset zoom and pan.
