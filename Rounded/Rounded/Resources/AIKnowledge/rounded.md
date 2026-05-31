---
id: rounded
summary: What Rounded does
---

Rounded is a Final Cut Pro plugin that rounds the corners of any clip and crops it with an animatable box. Drop it on a clip from the Effects browser. The plugin exposes two main animatable properties: Radius (corner rounding) and Box (crop region).

Like every Keyframeless plugin, Rounded animates with the shared timeline system. See the timeline docs for how Basic, Advanced, easing, and motion blur work.

## Showing and hiding on-screen controls

Rounded draws two on-screen controls: the **Radius** handle (the accent dot on the corner) and the **Box** crop region (its border plus eight corner handles). You can hide either to declutter the canvas, and the state stays in sync across the viewer, the mini-canvas, and the inspector:

- **Master tick** - the inspector's "On-Screen Controls" tick (near Motion Blur) turns both controls on or off at once.
- **Per-control pills** - the settings cog beside that tick opens a popover with a Radius pill and a Crop pill; toggle one to hide just that control.
- **Option-click to hide** - hold Option and click the radius handle, or the crop border or a crop corner, on either the viewer OR the mini-canvas to dismiss that control without opening the popover.

Hold **Option** over the viewer or mini-canvas to reveal any hidden control as a dimmed "ghost" where it would normally sit; Option-click a ghost to bring it back. Release Option and the ghosts fade away.

One nuance worth knowing: the ghost reveal follows mouse movement. Holding Option with the mouse still won't show the ghost until you nudge the pointer (the same applies right after you hide one or release Option). This is because Final Cut only hands the plugin the pointer's modifier state through hover events as the mouse moves; it isn't a bug, and any tiny movement brings the ghosts in or out. See the Position docs (Magic Move) for the full description of this behaviour, which is shared across plugins.
