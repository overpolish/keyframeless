---
id: visibility
summary: Showing and hiding on-screen controls - master tick, per-control pills, opt-click-hide, and opt-hold ghost reveal
---

# Showing and hiding on-screen controls

Every plugin that draws on-screen controls lets you hide the ones you aren't using, to declutter the canvas. The state stays in sync across three places: the FCP viewer, the inspector mini-viewer preview, and the inspector itself. Which controls a given plugin exposes varies (one plugin might have Position and Rotation X / Y / Z rings; another a Radius and a Crop box), but the behaviour below is identical everywhere.

## Three ways to hide a control

- **Master tick** - the inspector has an "On-Screen Controls" tick (sitting near Motion Blur) that turns every control on or off for the clip at once.
- **Per-control pills** - the settings cog beside that tick opens a popover with a pill for each control (compound controls like a rotation gizmo split into one pill per ring). Toggle a pill to hide just that one.
- **Option-click to hide** - hold Option and click a control directly (a handle, a rotation ring, a crop border or corner) on either the viewer OR the mini-viewer. That control hides and its pill flips off. This is the quick way to dismiss a control without opening the popover.

## Saving the set you like

The settings popover has **Make Default** under its search field. It saves which controls are hidden right now, and every new clip starts with that same set instead of showing everything. **Reset** beside it puts the current clip back to the saved set; both buttons disappear while the clip already matches it.

Defaults are per plugin, so Canvas and Mirage keep their own, and Mirage keeps one per shader template. Canvas goes one step further and keeps a set per layer kind - a vector path and an image expose different controls, so a default learned from a path can never leave an image layer with nothing to grab. Controls the saved set has never seen (a shader that gained one, a new release) start visible.

## Option-hold to reveal hidden controls

Hold **Option** over the viewer or the mini-viewer and any hidden controls reappear as dimmed "ghosts" wherever they would normally sit. Option-click a ghost to bring it back at full strength. Release Option and the ghosts fade away again, leaving the hidden ones hidden.

## Option-hold to "peek and use" when everything is off

When the **master tick is off** (all controls hidden for the clip), Option-hold behaves differently: it is a transient "peek and use" mode rather than the dim-ghost reveal above.

- Hold Option and the controls reappear at **full strength** (not dimmed) and are **fully interactive** - you can grab and drag a handle, a rotation ring, a crop or scale box, exactly as if the controls were on.
- It **respects your per-control choices**: only the controls left enabled by their pills come back. Any control you individually turned off (or a rotation ring whose ring/group pill is off) stays hidden even while peeking. Peeking is like flipping the master tick back on for a moment, so it shows the same set you would see then.
- **Release Option and everything hides again.** The master tick stays off - it is a non-destructive "mute" that remembers your per-control setup. Any edit you made while peeking is kept; only the visibility returns to off.

So with everything hidden you can still reach in and tweak a control for a second without permanently turning the controls back on. To bring controls back for good, use the master tick or the per-control pills (Option-click toggling is the master-on behaviour and does not apply while the master is off).

## Nuance: the reveal follows the pointer

The ghost reveal tracks mouse movement, so there is one quirk worth knowing:

- Hold Option but keep the mouse still - the dimmed control does NOT appear yet.
- Move the mouse a little - the ghost shows up.
- The same applies right after you hide one, and when you release Option: the change lands on the next small mouse movement, not the instant you press or let go of the key.

This is because Final Cut only hands the plugin the pointer's modifier state through hover events, which it sends as the mouse moves - there's no separate "a key was pressed" signal for the on-canvas control. It isn't a bug and there's no way around it; in practice any tiny nudge of the mouse brings the ghosts in or out immediately, so it rarely gets in the way.
