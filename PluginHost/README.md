# PluginHost

The FxPlug side of an effect that has nothing to do with what the effect animates: the instance lifecycle, host actions, the inspector's refresh clock, hidden settings, menus, keyboard shortcuts and the render-host adapter. It knows nothing about keyframed properties, which is `PoseLanes`' job, and nothing about any plugin's parameter identifiers, which each plugin registers.

- `KFEffect.m` is the base class: the API manager, document attachment, the inspector state the views read (image dimensions, selection, graphed properties), one refresh clock per instance and one main-run-loop tick. It declares no FxPlug protocols, so a plugin subclass states its own conformance and supplies rendering, parameter registration and view construction.
- `KFInspectorClock.m` refreshes every registered view from a single host action per tick, because the host has no callback for playhead movement. Registrations are weak and the timer only runs while views are registered.
- `KFHostSettings.m` is the one host path for hidden bool settings: read and toggle inside an action, the write in a named undo group followed by the refresh-token write that makes the host repaint at a stationary playhead. A plugin registers the token parameter and, for settings that double as creation preferences, the writer that records them.
- `KFPropertyMenu.m` owns the menu lifecycle a host action cannot survive: leaving tracking before writing, the undo and redo route while a menu is open, and the refresh after a cancelled or failed action.
- `KFShortcut.m` routes one keyboard shortcut to the effect the user is working on, from a process-wide event tap, without stealing keys from the host's own text editing. The plugin registers which key combination it answers to and what it does.
- `KFOSCPlayheadNudge.m` writes the refresh nonce once the playhead settles, so viewer controls that hid themselves during playback come back with no input from the user.
- `KFRenderHost.m` adapts `RenderSupport` to FxPlug image tiles: the pipeline for a tile's pixel format and the render pass that draws into it.
- `KFParameters.m` holds the registration shapes every plugin repeats: a hidden saved toggle, the saved scratch value that asks for a repaint, a transient cache token and a full-width custom view.

Everything a shared package needs to read back from its plugin is registered, not assumed: the host-refresh parameter, the shortcut binding, and the preference writer for settings that are also creation defaults. That keeps the package free of plugin identifiers and lets two plugins with different parameter tables share it.

The package imports the FxPlug SDK headers from `/Library/Developer/SDKs/FxPlug.sdk` and links AppKit, Metal and CoreMedia, but never links FxPlug itself; the plugin target carries the framework.

## Tests

```sh
PluginHost/Tests/run.sh
```

Drives the package against `Tests/MockHost.m`, a host double that records actions, undo groups and parameter writes. The suites cover the refresh clock (one action per tick, stops when idle, weak views), hidden settings (action and undo balance, preference recording, menu item state, every failure path), shortcut routing (menu history lifetime, effect selection without inspector interaction, repeats, weak owners) and the playhead nudge (one write per stop, silence while parked, gated on a visible control).

The mock host is also the double the plugin suites use, so a behaviour change here surfaces in both places. `KFRenderHost` is exercised through a plugin's GPU suites instead, because a render pass needs the plugin's own compiled shader library. Tests link against the SDK's FxPlug stub and run with `DYLD_FRAMEWORK_PATH=/Library/Developer/Frameworks`, so they need no built plugin.
