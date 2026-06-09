---
id: inspector-controls
summary: Playback, loop, reset-zoom, and pop-out buttons in the inspector header
---

The inspector has a small toolbar of icon buttons above the timeline so you don't have to rely on Spacebar (which often fails to focus FCP) or fight the viewer's zoom.

- Play / Pause: toggles FCP's playhead from inside the inspector. Use this when Spacebar isn't reaching FCP because focus is somewhere else. The icon tints accent while playing.
- Loop: keeps the clip looping while you scrub or play, so you can iterate on an animation without restarting. Tints accent when on.
- Reset Zoom: snaps the mini-viewer back to aspect-fit. Equivalent to double-clicking the canvas, or pressing Cmd-0 while the mini-viewer is open. Tints accent while the canvas is zoomed in, gray when already at fit, so it doubles as a "zoomed?" indicator.
- Pop Out: detaches the inspector into its own floating window so you have more screen space to edit complex animations. The detached window has the same controls as the docked inspector.
- Dynamic (Advanced timeline only): widens short transitions so they stay easy to grab on a long clip, even with long holds between them. Pill positions no longer line up with the linear ruler, so each lane gets its own playback line while the ruler keeps showing real time. Tints accent when on. It's display-only - it never changes the animation, never touches the data, and is off by default. The state is remembered between sessions.
