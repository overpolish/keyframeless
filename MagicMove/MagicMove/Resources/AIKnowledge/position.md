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

## Showing and hiding on-screen controls

You can declutter the canvas by hiding controls you aren't using. There are three ways, and they all stay in sync (viewer, mini-canvas, and the inspector):

- **Master tick** - the inspector has an "On-Screen Controls" tick (near Motion Blur) that turns every control on or off for the clip at once.
- **Per-control pills** - the settings cog beside that tick opens a popover with a pill for each control: Position, and Rotation split into its X / Y / Z rings. Toggle a pill to hide just that one.
- **Option-click to hide** - hold Option and click any control directly (the position handle, or one specific rotation ring) on either the viewer OR the mini-canvas. That control hides and its pill flips off. This is the quick way to dismiss a control without opening the popover.

### Option-hold to reveal hidden controls

Hold **Option** over the viewer or the mini-canvas and any hidden controls reappear as dimmed "ghosts" wherever they would normally sit. Option-click a ghost to bring it back at full strength. Release Option and the ghosts fade away again, leaving the hidden ones hidden.

### Nuance: the reveal follows the pointer

The ghost reveal tracks mouse movement, so there is one quirk worth knowing:

- Hold Option but keep the mouse still - the dimmed control does NOT appear yet.
- Move the mouse a little - the ghost shows up.
- The same applies right after you hide one, and when you release Option: the change lands on the next small mouse movement, not the instant you press or let go of the key.

This is because Final Cut only hands the plugin the pointer's modifier state through hover events, which it sends as the mouse moves - there's no separate "a key was pressed" signal for the on-canvas control. It isn't a bug and there's no way around it; in practice any tiny nudge of the mouse brings the ghosts in or out immediately, so it rarely gets in the way.

## Rotate with motion

When the Position lane has multiple keyposes (so the clip moves along a path), the gap popover for each Position interval exposes a **Rotate with motion** toggle. Enabling it makes the clip's Z rotation track the heading of the motion path automatically during that interval - useful for things flying along an arc that should bank with the curve. The toggle is per-interval, so the user can have some segments banking and others not. At gap boundaries the heading offset fades in and out with a hermite curve so the rotation never snaps.

This is a Magic Move feature, not a general rotation OSC feature - it lives on Position because the heading comes from the Position curve's tangent.

## Wrapping requirement

Magic Move wants a compound or adjustment clip wrapper: without one, Final Cut would crop the translated content at the original clip's bounding box.
