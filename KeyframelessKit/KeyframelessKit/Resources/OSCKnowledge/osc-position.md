---
id: position
summary: Position on-screen control - the draggable handle and curved motion path
---

# Position handle and motion path

The Position OSC is a shared on-screen control that any plugin with a Position lane gets for free. It is one draggable handle plus, once Position is animated, a curved motion path. What the position _means_ depends on the plugin: in Magic Move it translates the clip; in Glow it offsets the glow. The control, its editing, and its keyboard modifiers are identical everywhere because they are the same shared code (the FCP viewer and the keypose mini-viewer share it too).

## What the user sees

- **The handle** - a small ring (arc) sitting at the current Position. With Position held constant it sits wherever the value points; while animated it sits at the value for the frame under the playhead.
- **The motion path** (only when Position has two or more keyposes) - a line tracing the route the object takes between keyposes, with:
  - **Anchor dots** at each keypose (the keypose under the playhead is hidden beneath the handle), and
  - **Tangent handles** sticking out of any keypose that has been made _smooth_, which bend the curve.

## Moving the position

Grab the handle and drag. The drag is by delta (the value follows the cursor's offset from where you grabbed, so grabbing off-centre doesn't jump):

- **Shift** - axis-lock: constrains the drag to purely horizontal or purely vertical, whichever way you started moving.
- **Cmd** - snap: snaps to the canvas centre / edges / quarters and to the other keyposes' positions, drawing guide lines as it lands. Release Cmd for free movement.

## Editing the path

When Position is animated you can shape the route directly:

- **Drag an anchor dot** to move that keypose's position (Shift axis-lock, Cmd snap, same as the handle).
- **Double-click a keypose** (its anchor dot, or the handle on the active keypose) to toggle it between a **corner** (straight) and **smooth** (curved). Smooth keyposes grow tangent handles.
- **Drag a tangent handle** to set the curve:
  - **Shift** - lock the handle to horizontal / vertical.
  - **Cmd** - snap its angle to 45° steps.
  - **Ctrl** - break the tangent into a _cusp_ (the two sides move independently); without Ctrl the opposite side mirrors so the curve stays smooth through the keypose.

## Holds

A _hold_ is two linked keyposes at the same position - the object parks there for a stretch of time. Making a hold smooth curves the _approach into_ and _departure out of_ the hold while the object stays put during the hold itself. Each side of the hold shows a single tangent handle (like the end of a path), not two: the incoming twin's handle shapes the arrival, the outgoing twin's handle shapes the exit. The object does not drift during the hold.

## Visibility

Position and its motion Path are two separately hideable elements:

- Toggle their pills in the on-screen-controls settings popover, or
- Hold **Option** and click the handle (hides Position) or a path anchor / tangent (hides Path).
- Holding Option re-shows a hidden element as a dimmed "ghost" you can click to bring back (the reveal follows mouse movement - see the on-screen-control visibility docs).

## Mini-viewer

The same handle and motion path appear inside the keypose preview popovers (the "constants" / "boundary" popovers above each keypose pill). Dragging, snapping, the modifier keys, and the double-click corner/smooth toggle all work identically there - it is the same shared control, scaled to the popover.
