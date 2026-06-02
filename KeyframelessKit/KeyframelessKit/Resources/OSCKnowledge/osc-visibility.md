---
id: visibility
summary: Showing and hiding on-screen controls - master tick, per-control pills, opt-click-hide, and opt-hold ghost reveal
---

# Showing and hiding on-screen controls

Every plugin that draws on-screen controls lets you hide the ones you aren't using, to declutter the canvas. The state stays in sync across three places: the FCP viewer, the inspector mini-canvas preview, and the inspector itself. Which controls a given plugin exposes varies (for example Magic Move has Position and Rotation X / Y / Z rings; Rounded has Radius and a Crop box), but the behaviour below is identical everywhere.

## Three ways to hide a control

- **Master tick** - the inspector has an "On-Screen Controls" tick (sitting near Motion Blur) that turns every control on or off for the clip at once.
- **Per-control pills** - the settings cog beside that tick opens a popover with a pill for each control (compound controls like a rotation gizmo split into one pill per ring). Toggle a pill to hide just that one.
- **Option-click to hide** - hold Option and click a control directly (a handle, a rotation ring, a crop border or corner) on either the viewer OR the mini-canvas. That control hides and its pill flips off. This is the quick way to dismiss a control without opening the popover.

## Option-hold to reveal hidden controls

Hold **Option** over the viewer or the mini-canvas and any hidden controls reappear as dimmed "ghosts" wherever they would normally sit. Option-click a ghost to bring it back at full strength. Release Option and the ghosts fade away again, leaving the hidden ones hidden.

## Nuance: the reveal follows the pointer

The ghost reveal tracks mouse movement, so there is one quirk worth knowing:

- Hold Option but keep the mouse still - the dimmed control does NOT appear yet.
- Move the mouse a little - the ghost shows up.
- The same applies right after you hide one, and when you release Option: the change lands on the next small mouse movement, not the instant you press or let go of the key.

This is because Final Cut only hands the plugin the pointer's modifier state through hover events, which it sends as the mouse moves - there's no separate "a key was pressed" signal for the on-canvas control. It isn't a bug and there's no way around it; in practice any tiny nudge of the mouse brings the ghosts in or out immediately, so it rarely gets in the way.
