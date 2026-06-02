---
id: position
summary: The Position property in Magic Move and its on-screen controls
---

Position translates the clip across the frame. It has two components, X and Y, expressed in pixels (the clip's own resolution). The default is the centre of the frame; positive X moves right, positive Y moves up.

## On-screen controls

Magic Move shares one on-screen control system between the FCP viewer and the per-keypose mini-canvas previews inside the inspector. The position handle is the arc/point that follows the clip's centre; if the keypose also has any rotation, three coloured rings appear around the same point (see the rotation OSC docs).

Three ways to set Position:

- Drag the position handle on the viewer OSC. Free drag by default - no snap, you place pixel-precisely. Hold modifiers (below) for snap or axis-lock.
- Drag the position handle on the inspector mini-canvas. The mini-canvas previews the boundary frame for the keypose you're editing, so you can see exactly where the clip lands. Same modifiers work there.
- Type X and Y directly in the keypose value popover. Off-canvas values are allowed - the clip can fully exit the frame and slide back in.

## Modifier keys while dragging

- **Cmd** - engage snapping. Coloured guides show what you've snapped to (yellow = canvas anchor like centre/edge/thirds; accent = another keypose on this lane). See the snap guides doc for the full snap target list.
- **Shift** - lock to dominant axis. Whichever direction you've travelled further from the press point becomes the live axis; the other axis stays pinned. Useful for nudging horizontally or vertically only.
- Cmd and Shift combine, so you can axis-lock and snap at the same time.

Default is free drag with no snap, because snap tends to fight precise positioning. Hold Cmd when you want it.

## Curved motion paths

When Position has two or more keyposes the clip moves along a path between them. By default that path is straight lines from keypose to keypose. You can make it curve:

- **Smooth toggle.** The keypose value popover has a curve glyph next to the X / Y fields. Turning it on makes that keypose a smooth bezier anchor, so the path bends through it instead of cornering. Each keypose is independently smooth or linear, so you can mix sharp corners and flowing curves on one path.
- **The path overlay.** While editing keyposes, the motion path is drawn as a red curve with a dot at each keypose, in both the viewer and the inspector mini-canvas. It is its own on-screen control called "Path", separate from the Position handle, so you can hide or show it on its own (Option-click, same as the other controls). It only appears while editing keyposes, not when Position is a plain constant.
- **Tangent handles.** Each smooth keypose has an in and an out handle that shape how the curve enters and leaves it. They start auto-derived (a Catmull-Rom tangent) and become editable once you drag one. By default the two sides stay symmetric (a smooth curve); hold **Shift** while dragging to break them and angle each side independently (a cusp).
- **Convert by double-click.** Double-click an anchor dot to toggle that keypose between smooth (curved) and linear (corner).
- **Drag anchors on the path.** Any keypose's anchor dot is grabbable directly on the path, so you can reposition it without first scrubbing the playhead onto it. The active keypose (under the playhead) is shown as the Position handle itself, which takes priority when they overlap.
- **Even pacing.** The clip travels at a constant speed along the curve regardless of how tight or gentle each bend is, so a sharp corner does not whip past while a lazy arc crawls. The easing curve still shapes the speed of the move; it just shapes distance travelled rather than the raw bezier parameter.

Viewer and mini-canvas have full editing parity - anchors, handles, smooth toggling, and Path show/hide all work in both.

## Showing and hiding on-screen controls

Magic Move's controls - the Position handle and the Rotation X / Y / Z rings - can each be hidden to declutter the canvas: the inspector's "On-Screen Controls" tick toggles all of them, its settings cog has a pill per control, and you can Option-click a control on the viewer or mini-canvas to hide it (Option-hold reveals hidden ones as dimmed ghosts to click back). See the shared on-screen-control visibility docs for the full behaviour, including the mouse-movement nuance of the reveal.

## Rotate with motion

When the Position lane moves the clip, the gap popover for each Position interval exposes a **Rotate with motion** toggle. Enabling it gives the clip a momentum lean: it tips as though it had mass and inertia, adding a Z rotation on top of whatever rotation you set.

The lean is driven by the clip's **acceleration**, not its heading - it models the physical equilibrium tilt of an object being pushed (the angle where inertia and gravity balance). So:

- As the clip **speeds up** it tips into the motion; at **constant speed** it sits upright; as it **slows down** it rocks back, settling with a small natural overshoot. That accelerate-then-decelerate feel is the whole point.
- A **quick, snappy** move leans noticeably; a **slow drift** barely leans. Because it keys off acceleration rather than distance or speed, this stays true regardless of how far the clip travels or how long the clip is.
- It is the horizontal motion that produces the Z tilt; a purely vertical move reads naturally upright.

It works for any moving Position interval, including **hold-modulation** gaps (wiggle / oscillate / handheld) - the wobble has acceleration too, so it drives the lean. Only a genuinely static gap (no movement and no modulation) disables the toggle.

The toggle is per-interval, so some segments can lean and others stay flat. The lean smooths across keypose joins so it does not visibly shift when one interval hands off to the next.

This is a Magic Move feature, not a general rotation control - it lives on Position because the momentum comes from the Position motion. (Under the hood it is the reusable `KKMotionLean` evaluator in KeyframelessKit, so other plugins with a 2D position lane could adopt the same lean.)

## Wrapping requirement

Magic Move wants a compound or adjustment clip wrapper: without one, Final Cut would crop the translated content at the original clip's bounding box.
