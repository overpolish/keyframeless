# PoseLanes

The keyframed-property model shared by plugins whose values are custom parameters rather than host-interpolated numbers: one pose class, one lane adapter per property, the caches the inspector reads, native keyframe editing, links between properties, Match In/Out, creation defaults, the timing editor and the inspector rows. It depends on `PluginHost` for host actions and settings, `MotionTiming` for evaluation and `InspectorControls` for the views.

- `KFPose.m` is the value: N components, an authored flag, easing, Added Motion and a `KFPoseTiming`. Component count is fixed by its lane, so the same class serves a scalar, a vector and a rotation.
- `KFPoseTiming.m` carries the incoming transition of a keypose: requested duration, whether it fills the gap, Added Motion amount, speed, seed, per-component mask and the link identifier.
- `KFPropertyLane.m` is the host adapter: reads and writes one custom parameter, samples a snapshot through `MotionTiming`, clamps where the property is bounded, and publishes into the disposable cache the inspector holds. `KFPropertyPoseCache` is that snapshot, identified by a token the plugin publishes into a transient parameter, so a rebuilt row costs no host traffic.
- `KFViewCaches.m` gives an effect one cache per lane and the deferred commit tick a native drag needs, using associated storage so `PluginHost` keeps no notion of keyframed properties.
- `KFNativeEdits.m` and `KFNativeLinks.m` own native keyframe editing: reading and writing whole keys, moving them, and the links that carry a partner property's key when one member moves. A native drag ends without a host callback, so observed moves are applied from the effect's tick once the mouse is up.
- `KFMatchEndpoints.m` implements Match In/Out: a lane-wide toggle that mirrors the first and last keypose values, without putting the setting in any pose payload.
- `KFCreationDefaults.m` applies creation preferences to genuinely new keys only, tracking observed snapshots so an undo or a restored key never receives today's defaults. The plugin owns the store, its factory values and its validation, and registers an adapter.
- `KFTimingEditorModel.m` reads the gap around the playhead, samples its curve for the graph, and writes one timing setting at a time, including across linked properties.
- `KFTimingEditor.m` is the inspector panel: the curve graph, the duration, easing and Added Motion controls, their context menus and the default and reset actions.
- `KFPropertyRow.m` is the inspector row: a slider for a single component, one field per axis otherwise, both built from the lane's labels, unit and precision. It shows a percent-of-image lane in pixels using the dimensions the effect publishes, couples axes where the lane says so, and refreshes from the shared clock.
- `KFResetParameter.m` restores a lane's default and drops its keyposes in one undo group, restoring the whole curve if the host rejects the write.

A plugin registers its lane table once with `KFRegisterLanes`, along with the parameter identifiers the package reads back: the explicit-creation toggle, the row shortcut action and the defaults adapter. Everything else resolves a lane from a parameter identifier, so nothing here carries a plugin's identifiers or display choices.

The package imports the FxPlug SDK headers from `/Library/Developer/SDKs/FxPlug.sdk` and links AppKit and CoreMedia, but never links FxPlug itself; the plugin target carries the framework.

## Tests

```sh
PoseLanes/Tests/run.sh
```

`Tests/TestLanes.m` registers a representative table (a percent-of-image vector lane, a proportional vector lane, a three-component lane, two scalars and a pixel vector lane) and a stand-in effect, so the suites exercise shapes rather than one plugin's properties. They run against `PluginHost/Tests/MockHost.m`.

The suites cover the pose class (validation, secure coding, interpolation metadata), lane behaviour per lane (sampling, bounds, kept rotation turns, cached writes without key enumeration, rejected writes, races with a refresh), the timing model, links and reset, Match In/Out, creation defaults, the reset paths and their menus, the inspector rows and the timing editor. Tests link against the SDK's FxPlug stub and run with `DYLD_FRAMEWORK_PATH=/Library/Developer/Frameworks`, so they need no built plugin.
