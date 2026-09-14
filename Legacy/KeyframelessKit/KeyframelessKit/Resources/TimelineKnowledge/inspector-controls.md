---
id: inspector-controls
summary: Playback, loop, reset-zoom, and pop-out buttons in the inspector header
---

The inspector has a small toolbar of icon buttons above the timeline so you don't have to rely on Spacebar (which often fails to focus FCP) or fight the viewer's zoom.

- Play / Pause: toggles FCP's playhead from inside the inspector. Use this when Spacebar isn't reaching FCP because focus is somewhere else. The icon tints accent while playing.
- Loop: keeps the clip looping while you scrub or play, so you can iterate on an animation without restarting. Tints accent when on.
- Reset Zoom: snaps the mini-viewer back to aspect-fit. Equivalent to double-clicking the canvas, or pressing Cmd-0 while the mini-viewer is open. Tints accent while the canvas is zoomed in, gray when already at fit, so it doubles as a "zoomed?" indicator.
- Pop Out: detaches the inspector into its own floating window so you have more screen space to edit complex animations. The detached window has the same controls as the docked inspector.

The timeline has a ruler along its top that you can scrub: click or drag anywhere on it to move Final Cut's playhead, so you can jog through the clip without leaving the inspector. The ruler is always there - even before you've animated anything, or while a filter hides every lane - so scrubbing is always available. Combined with the live preview, you can open a keypose or Constants editor, scrub the ruler, and watch the result update in place without closing the editor.

- Advanced timeline only:
  - Dynamic: widens short transitions so they stay easy to grab on a long clip, even with long holds between them. Pill positions no longer line up with the linear ruler, so each lane gets its own playback line while the ruler keeps showing real time. Tints accent when on. It's display-only - it never changes the animation, never touches the data, and is off by default. The state is remembered between sessions.
  - Maintain Timing: a lock that pins the animation to absolute time. With it on, trimming, growing, or splitting the clip retimes the keyposes so each one holds its position instead of stretching with the clip - and a split keeps both halves continuous across the cut. Unlike Dynamic, this does change the data: the retime is baked in, so it stays when you turn the lock off, and undoing a trim takes a second undo to also undo the retime. Tints accent when on; off by default; remembered between sessions.
