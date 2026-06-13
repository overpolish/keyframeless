---
id: shortcuts
summary: Mouse and keyboard shortcuts for the Advanced timeline
---

These mouse and keyboard shortcuts apply on the Advanced timeline canvas.

### Keyposes

- Click a keypose to select it and open its value editor popover.
- Shift-click adds or removes a keypose from the multi-selection.
- Option-click on a keypose deletes it (eraser).
- Option-drag a keypose to duplicate it; the duplicate snaps to other keyposes on release.
- Drag a keypose (or a multi-selection) to move it; it snaps to nearby keyposes on the same lane and across lanes.
- Cmd-click an empty spot on the lane to add a new keypose at that time.

### Intervals (the gap between two keyposes)

- Click a gap to select it and open the interval editor (curve + modulation).
- Shift-click adds or removes a gap from the multi-selection.
- Right-click a gap for Link Endpoints / Unlink Endpoints. Linked endpoints share one value so the interval becomes a hold; unlinked endpoints animate via the curve.

### Lane filter bar (above the timeline)

- Click a property pill to hide or show its lane in the timeline.
- Click a category's leading pill to toggle that whole group on or off; it stays highlighted while any lane in the group is still visible.
- Click and drag across pills to set several at once (show or hide), carrying across capsules. The category master pills are skipped by the drag.
- Option-click a property to solo it - everything else hides and the soloed pill turns the warning colour. Option-click a category to solo the whole group; Option-click the active solo again to clear it.

### Marquee selection

- Click and drag on empty timeline space to marquee-select keyposes. Shift-drag adds to the existing selection instead of replacing it.

### Multi-selection actions (right-click the selection)

- Reverse: mirror the times of the selected keyposes around their midpoint.
- Distribute Evenly: space the selected keyposes equally.
- Delete: remove them all. The Delete key does the same.

### Copy and paste keypose values

- Right-click a keypose and choose Copy Values to put its value (plus any spatial-curve smoothing) on the clipboard. Copy is only offered for a single keypose, not a multi-selection.
- Right-click a keypose, or a multi-selection, and choose Paste Values to stamp the copied value onto it. With several keyposes selected, paste lands on each one whose lane matches the copied value and skips the rest.
- Paste stays greyed out unless the clipboard holds a value for a matching lane: the property type and component count have to line up, so you cannot paste a Rotation value onto a Scale keypose. Because the clipboard is shared, you can also copy from one clip and paste into another.

Snapping: a small guide line appears when a dragged keypose comes within a few pixels of another keypose, so getting motion aligned across lanes is straightforward.

### Playback while editing

- Spacebar plays or pauses FCP's playhead so you can scrub through your animation without leaving the inspector.
- Cmd-Option-click anywhere on a lane (even on a pill) jumps the playhead to that moment for a quick preview, and Cmd-Option-drag scrubs continuously. It works the same in the linear and Dynamic views; in Dynamic the time lands where the cursor sits in that lane's warped layout.
- Cmd-Z and Cmd-Shift-Z undo and redo any edit, including ones made inside popovers.

### Inside popovers

- Return commits the number field you're typing in.
- Tab moves to the next number field (Shift-Tab to the previous one), like a web form.
- Esc cancels the in-progress edit and closes the popover.
- Left and Right arrows step to the previous/next keypose when a keypose popover is open, so you can walk the animation without reaching for the mouse. This only applies when you're not editing a number field - inside a field the arrows move the text cursor as usual.
- Double-click the mini-viewer, or press Cmd-0 while the mini-viewer is open, to reset its zoom and pan back to aspect-fit (same as the Reset Zoom button in the inspector header). Scroll-wheel or pinch zooms in and out; two-finger drag pans.
- Note on Cmd-0: because the inspector runs as a Final Cut Pro extension, the Cmd-0 key press also reaches Final Cut Pro itself. If you have assigned Cmd-0 to a command in Final Cut's keyboard customization (Final Cut Pro > Commands), that command will fire too. Final Cut has no default Cmd-0 shortcut, so by default there is nothing to clash with, but if you hit unexpected behaviour, check your custom command set or just use the Reset Zoom button or a double-click instead.
