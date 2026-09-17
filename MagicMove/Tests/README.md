# Magic Move regression tests

Run these commands from the repository root after building the Debug plugin:

```sh
xcodebuild -workspace Keyframeless.xcworkspace -scheme MagicMove \
  -configuration Debug -derivedDataPath DerivedData/Keyframeless build
scripts/test-magicmove.sh
```

Requires macOS, Xcode with the Metal compiler, the FxPlug SDK, and a Metal device for GPU tests. For a different build directory, pass its absolute path through `MM_DERIVED_DATA`:

```sh
MM_DERIVED_DATA="$PWD/DerivedData/Verification" scripts/test-magicmove.sh
scripts/test-magicmove.sh --cpu-only
```

The suite compiles current plugin and shared-package sources with AddressSanitizer and UndefinedBehaviorSanitizer. Only Apple's FxPlug runtime is reused: the plugin suites take it from the built app, and the package suites from its installed location, so `PluginHost/Tests/run.sh` and `PoseLanes/Tests/run.sh` need no build at all. Tests do not register an effect, modify a host document, or load archived frameworks. Temporary test artifacts are cleaned up.

## Suites

| Runner | Scope |
| --- | --- |
| `InspectorControls/Tests/run.sh` | AppKit layout, value editing, menus, sliders, and header |
| `MotionTiming/Tests/run.sh` | Timing evaluator |
| `PluginHost/Tests/run.sh` | Refresh clock, hidden settings, shortcut routing, and the playhead nudge |
| `PoseLanes/Tests/run.sh` | Pose model, lane behaviour, native edits, links, match, defaults, rows, and the timing editor |
| `RenderSupport/Tests/run.sh` | Subframe timing, real Metal resource handling, accumulation, and failure recovery |
| `MagicMove/Tests/run.sh` | Plugin wiring with `PluginHost/Tests/MockHost.m` and other simulated host APIs |
| `MagicMove/Tests/run-shader.sh` | Freshly compiled transform shader and pixel comparisons |
| `MagicMove/Tests/run-blur.sh` | Production render adapter, motion/spatial blur, anchor, and preview scaling |

Select plugin suites with `MM_TEST_SUITES`, and package suites with `KF_TEST_SUITES`:

```sh
MM_TEST_SUITES="LaneIntegrationTests ModelTests" MagicMove/Tests/run.sh
KF_TEST_SUITES="LaneTests NativeLinksTests" PoseLanes/Tests/run.sh
```

Standalone package runners do not require a built plugin. RenderSupport accepts `--cpu-only` to omit GPU checks. The plugin blur test uses the built app's metallib, so rebuild after changing shaders. A skipped GPU stage is not a successful GPU verification.

## Coverage

| Area | Checks |
| --- | --- |
| Pose model | Component validation, secure coding, equality, and interpolation metadata |
| Lane behaviour | The same sampling, bounds, write, cache, failure, timing and reset checks run for every lane shape; rotation turns and proportional scale have their own cases |
| Plugin wiring | Registered parameters and flags in lane order, the render state derived from the lanes, the rows built for them, and the identifiers the packages read back |
| Host machinery | One action per clock tick, one tick per effect, settings toggles with their undo groups and preference recording, shortcut routing across effects, and the playhead nudge |
| Timing | Incoming duration and easing, holds, zero duration, available time, gap limits, endpoint values, and sampling in any order |
| Native keyframe tracking | Linked moves, insertion, deletion, multi-selection, and retained settings |
| Property editing | Static values, single and multiple keyframes, component preservation, explicit editing, and reset |
| Links and endpoint matching | Partner creation, independent values, shared timing, moves, deletion, unlinking, and failed-write rollback |
| Match In/Out | Endpoint pairing with two and three or more keys, created partner and no-room failure, value mirroring both ways, paired transitions, Added Motion staying put, linked partners not inheriting the setting, and re-pairing after key structure changes |
| Inspector and graph | Gap selection, cached curve samples, enablement, property switching, units, and one undo group per drag |
| Saved data | Secure coding, full-width IDs, duplicate effects, corrupt data, and restoration without extra writes |
| Callbacks | Reentrant and delayed notifications, undo restoration, drag completion, stale reads, and missing host APIs |
| Rendering | Captured state, source tile bounds, shader pixels, premultiplied alpha, blur, anchor, and preview scaling |

## Resource checks

`HostLifecycleTests` verifies detached instances, document attachment, that a second attachment cannot duplicate the tick, that the tick stops when the effect is released, weak API-manager ownership, and unknown parameter handling.

RenderSupport's standalone GPU tests cover device selection, bounded queue exhaustion and recovery, pipeline caching, texture reuse, averaging, one-buffer submission, and cleanup after failed or throwing sample callbacks. Plugin GPU tests exercise the same production adapter used by the effect, including premultiplied alpha, sharp rendering, spatial blur, anchor pivots, and reduced-resolution input transforms.

## Manual Motion/FCP checks

For changes involving host integration, also check these in Motion/FCP:

1. Add a fresh effect, open an existing saved effect, and save/reopen the document.
2. Create, move, delete, and cross native keyframes; include multi-selection and linked/unlinked properties.
3. Undo and redo edits, linking, partner creation, movement, reset, and timing changes. Check that related writes form the intended undo action.
4. Scrub and play through gaps and exact keyframes. Check graph/value updates and control enablement without extra mouse movement.
5. Test numeric click/edit/scrub, dropdown selection, context-menu state, and the motion-blur shortcut with the effect selected.
6. Verify native keyframe buttons remain clickable at different inspector widths, especially for percentage and three-axis fields.
7. Compare motion blur, spatial blur, scale/rotation, and anchor behavior during playback and export, including reduced-resolution previews.
8. Exercise the published effect in FCP as well as Motion when changing parameter registration or custom views.
9. Check the on-screen controls while the playhead moves: they hide during playback and while scrubbing, and come back on their own shortly after the playhead stops, with no mouse movement and no key press. Also check the immediate paths: pointer movement inside the viewer, entering the viewer, a key release, and a drag. A stopped viewer must never be left without controls. Confirm one undo entry named "Show On-Screen Controls" per stop, and none while the playhead sits still or when every control is switched off.
10. The control's pointer and drag paths can log to the unified log when `/tmp/keyframeless-osc-log` exists; it is re-checked every couple of seconds, so a running host picks it up. An environment variable cannot arm it: the host spawns the control as a launchd XPC service that inherits nothing from the shell or the application. Measured in Motion, a nudge reaches the redraw in 15 to 31ms, so any perceptible wait is the settle window rather than the repaint.

Include the application versions, checks you ran, and results in the pull request.

`PoseLanes/Tests/DefaultsTests.m` covers creation defaults, native insertion tracking, undo restoration, stale queued edits, per-type Added Motion settings, secure archive round trips, and context-menu actions. `MagicMove/Tests/PreferenceTests.m` covers the plugin's own factory values, validation and on-screen control visibility defaults. Test runs use an isolated preferences suite through `MM_PREFERENCES_SUITE`, or `KF_PREFERENCES_SUITE` for the package, and remove it on exit.

For host verification, set duration and easing defaults, add keys with the native keyframe button and automatic value editing, then undo/redo and move existing keys. Check that existing keys retain their settings. Save Wave and Wiggle defaults, switch types after editing them, and reopen the document to verify that each type retains its edits.

`PoseLanes/Tests/PropertyMatchTests.m` covers Match In/Out on the custom pose properties. For host verification, turn matching on from a property label menu with one, two, and three keys, check the created endpoint and the undo of turning it on, edit an endpoint value and an endpoint transition from both ends, insert and delete keys at both ends, and save and reopen the document. With a matched property linked to an unmatched one, check that the partner follows the timing but keeps its own Match In/Out state.

Reset-menu tests verify saved-default and factory fallback, incoming versus outgoing ownership, one undo group per reset, and preservation of Use Available Time. `InspectorControls/Tests/ValueFocusTests.m` exercises text entry and focus dismissal in an AppKit window.
