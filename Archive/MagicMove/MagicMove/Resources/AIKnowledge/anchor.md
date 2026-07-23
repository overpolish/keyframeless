---
id: anchor
summary: The Anchor Point property in Magic Move and its on-screen square control
---

The Anchor Point is the pivot that Rotation and Scale swing around. It has two components, X and Y, in the same space as Position (the clip's own frame, where the centre is the default). On its own it does nothing visible - it only changes where rotation spins and where scaling grows from.

By default the anchor sits at the clip's centre, so rotation spins around the middle and scale grows out from the middle. Move it elsewhere and both pivot there instead:

- Put it on a **corner** and the clip rotates around that corner and scales out from it - like a sheet of paper pinned by one corner.
- Put it on an **edge midpoint** and the clip hinges along that edge.
- Off the clip entirely and the clip orbits a point in empty space.

The anchor is a point on the content, so it **travels with the clip**: as Position moves the clip across the frame, the pivot moves with it. The anchor only matters when there is rotation or scale to pivot - with neither, moving it has no effect.

## Animating the anchor

Anchor Point is an animatable lane like the others. Leave it as a single constant for a fixed pivot, or give it keyposes to move the pivot over time - useful when a clip should rotate around one point early in a move and a different point later.

## On-screen control

The anchor's on-screen control is a small **square** at the pivot, shared between the FCP viewer and the inspector mini-viewer with full editing parity. It is the topmost control, drawn over the rotation rings, scale box, and Position handle. Because the square is small, the larger Position arc ring around it stays clickable - so the move handle and the pivot can sit on the same spot (the default centre) and both remain grabbable.

The square appears where the Anchor lane is visible: at the keypose times when the anchor is animated, or always when it is a single constant - the same rule the Position and Scale controls follow.

Three ways to set the anchor:

- Drag the square on the viewer OSC.
- Drag the square on the inspector mini-viewer, which previews the keypose you're editing.
- Type X and Y directly in the keypose value popover. Off-clip values are allowed.

## Modifier keys while dragging

- **Cmd** - engage snapping. The pivot snaps to the clip's own centre, corners, edge midpoints, and thirds, with guide lines showing what you've caught. This is the quick way to drop the anchor exactly on a corner or the centre.

Default is free drag with no snap, so you can place the pivot pixel-precisely; hold Cmd when you want it to land on a clip feature. This matches the Position and Rotation controls, where snap is also Cmd-only.

## Showing and hiding the square

The anchor square is part of Magic Move's shared on-screen-control visibility: the inspector's "On-Screen Controls" tick toggles all controls, the settings cog has an "Anchor" pill, and you can Option-click the square on the viewer or mini-viewer to hide it (Option-hold reveals hidden controls as dimmed ghosts to click back). See the shared on-screen-control visibility docs for the full behaviour.

## Wrapping requirement

Like the rest of Magic Move's transforms, the anchor's effect on rotation and scale is best seen on a compound or adjustment clip wrapping the footage - without one, Final Cut crops the transformed content at the original clip's bounding box.
