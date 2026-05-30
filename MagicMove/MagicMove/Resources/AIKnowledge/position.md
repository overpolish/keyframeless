---
id: position
summary: The Position property in Magic Move
---

Position translates the clip across the frame. It has two components, X and Y, expressed in pixels (the clip's own resolution). The default is the centre of the frame; positive X moves right, positive Y moves up.

There are three ways to set a Position value:

- Drag the arc handle on the viewer's on-screen control. Snaps to the centre, edges, thirds, and any other keypose's position on the same lane. Hold Command to bypass snapping.
- Drag the arc handle on the inspector's mini-canvas. The mini-canvas previews the boundary frame for the keypose you're editing, so you can see how the clip lands. Same snap targets as the viewer.
- Type X and Y directly in the keypose value popover. Off-canvas values are allowed - the clip can fully exit the frame and slide back in.

This is why Magic Move wants a compound or adjustment clip wrapper: without one, Final Cut would crop the translated content at the original clip's bounding box.
