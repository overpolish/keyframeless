---
id: scale
summary: The Scale property in Magic Move and its on-screen transform box
---

Scale resizes the clip. It has two components, X and Y, each a percentage of the clip's own size. The default is 100% x 100% (untouched).

Scale values are whole percentages - there is no half a percent, so every field and drag snaps to an integer. They are floored at 0% and have no upper limit: you can scale a clip up as far as you like, but it never goes negative, so Scale never flips or mirrors the clip. (Use Rotation for flipping.) 0% collapses the clip to nothing; it stays a valid, recoverable value rather than something the controls can get stuck at.

## Linking X and Y (aspect lock)

A link glyph sits next to the X / Y fields in the keypose value popover. It locks the aspect ratio:

- **Linked (the default).** Editing X scales Y to match, and vice versa, so the clip keeps its proportions. Dragging a corner of the on-screen box scales both axes together.
- **Unlinked.** X and Y move independently, so you can stretch or squash the clip.

The link is one global toggle for the whole Scale lane, not per-keypose - flip it once and every keypose on the lane respects it. Magic Move ships with it on, because proportional scaling is what you want most of the time.

## On-screen control

Scale's on-screen control is a **transform bounding box** - a box reads honestly when X and Y differ. It is screen-aligned (it does not rotate with the clip) and has eight handles: four corners and four edge midpoints.

The box **tracks the clip**: it is sized relative to the clip's on-screen frame, so it grows and shrinks with the clip as you zoom the viewer or the inspector mini-canvas, staying glued to the content rather than floating at a fixed screen size.

Because Scale has no real upper bound, the box can't map size to percent one-to-one or it would shoot off-screen. Instead:

- At **0%** the box is at a minimum grabbable size, a touch larger than the rotation gizmo, so it is always clickable even when the clip is scaled to nothing.
- From **0% to 100%** the box grows roughly linearly.
- **Above 100%** the box keeps growing but on a square-root curve, so very large scales stay on-screen and draggable. The curve is slope-matched at 100% so there is no kink as you cross it.

A readout under the box's lower-right corner shows the live value as "X% x Y%". The whole control - box, handles, readout - is identical in the FCP viewer and the inspector mini-canvas, with full editing parity.

## Dragging the box

The handles use an **absolute** drag model so the box stays locked to the cursor:

- Grab a handle and it stays under the pointer - no jump on press. As you move, the value follows your cursor's distance from the box centre through the same size curve described above.
- **Corner handles** scale both axes. When linked they scale by a single geometric-mean factor so the drag is smooth and continuous with no axis snapping; when unlinked each axis follows its own corner offset.
- **Edge handles** drive one axis. If linked, the other axis follows by ratio so proportions hold; if unlinked, the partner axis stays put.
- **Cmd** engages fine mode: cursor movement is scaled down (to 20%) for precise adjustment, while the box stays in sync with the pointer.
- **Shift** inverts the link for that drag only - a quick way to break aspect for one stretch without flipping the lane's global toggle, or to force proportional scaling when the toggle is off.

Every drag snaps to whole percentages and is floored at 0%.

## Setting Scale three ways

- Drag a handle on the viewer transform box.
- Drag a handle on the inspector mini-canvas box - it previews the keypose you're editing, same handles and modifiers.
- Type X and Y directly in the keypose value popover (whole percentages; the link glyph mirrors the other field when on).

## Showing and hiding the box

Scale is part of Magic Move's shared on-screen-control visibility: the inspector's "On-Screen Controls" tick toggles all controls, the settings cog has a "Scale" pill, and you can Option-click the box on the viewer or mini-canvas to hide it (Option-hold reveals hidden controls as dimmed ghosts to click back). See the shared on-screen-control visibility docs for the full behaviour.

## Wrapping requirement

Like the rest of Magic Move's transforms, Scale works best on a compound or adjustment clip wrapping the footage - without one, Final Cut crops the scaled content at the original clip's bounding box.
