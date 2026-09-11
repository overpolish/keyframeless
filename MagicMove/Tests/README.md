# Magic Move regression suite

From the repository root:

```sh
scripts/test-magicmove.sh
```

This runs the independent timing tests, real MagicMove callback/render-state code
against a deterministic host double, and offscreen Metal shader tests. Nothing
is registered, published, or changed in Motion/FCP. All test build artifacts are
temporary and cleaned up. To run without the GPU stage:

```sh
scripts/test-magicmove.sh --cpu-only
```

## Prerequisites

macOS, Xcode command-line tools, the installed FxPlug SDK, and a previously built
MagicMove Debug runtime in `DerivedData/Keyframeless` are required for the host
adapter tests. If that shared runtime is absent, build it once:

```sh
xcodebuild -workspace Keyframeless.xcworkspace -scheme MagicMove \
  -configuration Debug -derivedDataPath DerivedData/Keyframeless build
```

The test runner recompiles **current** MagicMove and MotionTiming source files.
It does not link a stale MotionTiming object from the last plugin build. Only
KeyframelessKit/FxPlug framework binaries are reused; rebuild that runtime if
those dependencies change. CPU tests run with AddressSanitizer and
UndefinedBehaviorSanitizer. Assertions remain enabled.

## Behaviour covered

| Layer | Automated coverage |
| --- | --- |
| Timing evaluator | IN ownership, holds, smoothstep samples away from midpoint, exact arrivals, endpoint holds, zero duration, gap caps, multiple components, random-access sampling, deterministic generated invariants, invalid arguments without altering output |
| Pose association | Exact-time priority, unique-value moves, same-value multi-selection ordering, insert/delete/defaults, duration and available-time retention, link IDs, previous-index correspondence, invalid input |
| Parameter creation | Native animatable values, defaults, valid unique IDs, flat inspector rows, hidden saved blobs, transient disabled timing/link editors, legacy global control hidden |
| Render state | Static and single-key values, independent clocks including negative host times, Position X/Scale conversions, native interpolation bypass, fixed and available-time mixing, insertion caps without changing saved intent, no host writes from rendering |
| Contextual controls | First pose, destination pose, between-key disablement, per-property enablement, available-time toggle retains duration, repeated refresh is a no-op, rational-time tolerance, stale non-key edits |
| Per-pose links | Silent partner creation and current-value sampling, existing partner value preservation, unrelated keys stay independent, IN settings sync, moves from either property, crossing/multi-select, deletion, unlinking, initial-pose links |
| Endpoint matching | Enable from either endpoint; create a missing boundary pose; two-to-three insertion; bidirectional value and timing edits; disable; invalid boundaries and rollback; timing propagation through property links; native-read-free release |
| Combined custom poses | Secure coding, vector timing, insertion/movement/deletion, rendering, callback cache refresh, UI reads without key enumeration, delayed partner edits, undo/redo-style restores, instance isolation, read failure |
| Persistence | Legacy records without new fields, JSON round trip, full-width 64-bit IDs, secure coding, duplicate effects remain independent, transient fields excluded, idempotent writes, corrupted data rejected |
| Restored state | Simulated host restoration of saved metadata refreshes editors without writing it back; stale render generations cannot overwrite newer snapshots |
| Callback regressions | Synchronous reentrancy, delayed callbacks, callback queue drains, drag bursts, scrub away before an echo, real edits still work, detached creation does not start the host-action timer, remote move API dropping the requested index, mouse-held drag burst with no partner/blob/inspector writes and one grouped replacement on release, no native keyframe reads on release, no inspector writes from delayed commit echoes |
| Failure paths | Missing host APIs/values, invalid render input, full source tile requested for transforms, collision rejection, failed replacement-key creation or metadata save restores partner |
| Metal pixels | Real shader compiled fresh; see ShaderTests.m and run-shader.sh for supported hardware and pixel cases |

## Test layout

- `MotionTiming/Tests/`: standalone C tests; no FxPlug or Kit dependency.
- `MockHost.h/.m`: shared host double, explicit user-edit helpers, deferred
  notifications, native key metadata/value storage, write counters, and failure
  injection. It has no animation/timing engine of its own; its native value
  interpolation is deliberately linear to verify that the plugin bypasses it.
- `LinkedPosesTests.m`: editing workflows and regressions from real user reports.
- `ModelTests.m`: named, isolated contracts for parameter creation, render state,
  persistence, controls, linked multi-selection, collision handling, and copies.
- `ShaderTests.m`: offscreen pixel checks using the actual Metal shader.

Tests should describe observable behaviour. Add a minimal failing regression
before fixing a bug, and keep it after the fix. Do not replace engine evaluation
with a mock implementation or make the host double silently emulate a fix.

## What still requires Motion/FCP

These tests do **not** certify host internals:

1. Drag the effect from the library, apply it, then save/reopen the document.
2. Drag linked and unlinked keys, including multi-selection and crossing.
3. Undo/redo linking, silent partner creation, movement, timing, and deletion.
   Verify the host groups the initiating action and partner change as one edit.
4. Publish the eight visible controls in Motion and exercise them in FCP.
5. Check inspector responsiveness and the viewer at different project frame
   rates, clip trims/retimes, resolutions, and colour-management settings.

The mock's saved-state restoration tests are not a claim about real host undo
ordering. Pixel tests isolate the shader; they do not replace host rendering,
colour management, or tiled-image integration tests. A GPU-stage skip must be
reported as a skip, not as a pass.

Native value edits stay in memory while the left mouse button is held. The
30 Hz inspector timer reads Quartz session button state before opening any host
action. Once released, pending writes and inspector refresh share an FxUndoAPI
group. Workflow helpers supply a release explicitly; the drag regression tests
held/released states and balanced grouping. Native drag undo membership and
button-state visibility from the plugin process still require Motion testing.

Linked edits are prepared from native callback snapshots; release applies the
latest prepared pair and publishes both cached records. Saved-data notifications
invalidate model snapshots without forgetting successfully displayed values.
