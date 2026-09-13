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
| Shared timing panel | Secure per-pose timing payloads, incoming/outgoing ownership, duration evaluation, metadata preservation, cached graph agreement without native reads, property switching, empty state/layout, numeric drag undo |
| Combined custom poses | Secure coding, vector timing, insertion/movement/deletion, rendering, callback cache refresh, UI reads without key enumeration, delayed partner edits, undo/redo-style restores, instance isolation, read failure |
| Explicit creation | Default-off routing; next/exact/endpoint targeting; partner and easing preservation; empty-lane behavior; native insertion callback enables editing |
| Easing | Four curve types; incoming-only selectors; next-arrival timing edits between keys; scalar and combined rendering; secure coding; moved-key persistence; linked/matched propagation; delayed editor echoes |
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

AddedMotionTests covers outgoing ownership, scalar rendering, motion choices
remaining independent across linked properties, persistence after key movement,
cached enable/disable updates while scrubbing, and delayed display echoes.
CombinedPoseTests also covers outgoing motion targeting, secure coding, and
preservation during value edits. Shared C tests cover deterministic motion and
join smoothing. Motion/FCP visual feel still needs manual host testing.

MotionBlurTests covers fixed defaults, scalar shutter snapshots, frame timing,
coarse host clocks, bounded native reads, invalid frame duration, and disabling.
CombinedPoseTests compares combined blur samples to engine evaluation.
`run-blur.sh` uses the built plugin metallib to exercise the production render
path on Metal, including the shared sample pool and accumulator. The normal
`scripts/test-magicmove.sh` run includes it; `--cpu-only` skips GPU tests.

`ShortcutTests` exercises the independent shortcut router and real Motion Blur
write function with a mock host, including matching, repeats, instance ownership,
read failures, and balanced host actions. Event-tap delivery, inspector visibility,
and actual host undo/redo require the Motion/FCP checkpoint in the plugin README.

`CustomRowTests` creates the production AppKit row in an offscreen window. It
covers blank/disabled initial fields, delayed cache loading, immediate attachment
refresh, valid zero values, preserved-but-disabled values after snapshot failure,
and no native keyframe enumeration during UI refresh. Filter switching still
needs a host check because FCP controls inspector recreation and callback timing.

`ResetParameterTests` exercises each native property label menu, removal of all
keys, default values and pose metadata, immediate constant-cache publication,
property isolation, repeated resets, zero native key-info reads with a populated
cache, balanced undo/action scopes, and recovery
when the host rejects a value write. Read, deletion, and undo-start failures
leave the original curve intact in the mock. The reset mock exposes keyframe,
value, and undo APIs only inside an open custom action, matching the observed
Motion host restriction. Cache publication follows the same action scope.
The menu regression also verifies that reset waits for the default run-loop
mode, performs no host work during menu tracking, and runs without a mouse event.
The shared controls tests keep the
menu scoped to the title label. In Motion/FCP, verify right-click and Control-click
on each property label, reset from a gap, and a single Undo restoring its values,
keyframes, timing, and added motion; other properties should remain unchanged.
Actual host undo restoration and remote menu delivery are not established by mocks.

The same-position synthetic mouse-event experiment did not resolve the host
repaint issue and was removed; reset does not post input events.

Reset now writes a fresh UUID to `MMHostRefreshToken` (2200) after restoring the
property default, before closing the existing undo group. This adapts the legacy
hidden scratch-parameter invalidation approach without linking legacy helpers.
Tests verify hidden/non-animatable/saved flags, allowed payload class, unique
values on successive resets, same-group writes, and no refresh write for failed
resets. Actual Motion/FCP repainting and single-step Undo remain host checks.

Host checkpoint: the user confirmed Reset Parameter and Undo work in Motion,
and confirmed the hidden refresh-token write resolves the stale display without
mouse movement. Temporary reset tracing was removed after that confirmation.

`NativeLinksTests` covers keypose-level groups on Position, Scale, Rotation, and
Opacity: reciprocal context menus, two-/three-property groups, sampled silent
partners, unlinking, secure-coded group IDs, shared incoming duration/available
time/easing and outgoing added motion, and independent values. It also exercises
release-only partner moves, multiple selected groups, copied-key cleanup,
undo-like snapshot restoration, failed-write rollback, and metadata writes with
no native key enumeration. The gutter indicator is presentation-only in
InspectorControls; group membership and FxPlug operations stay in MagicMove.

Native linking host checkpoint (pending): link from an exact key and from a gap;
check all participating menus/icons; add a third member; change duration/easing;
drag one linked key and release; move multiple groups; undo/redo; unlink one
member; reset one property; save/reopen. Verify the native drag keeps capture,
partner values remain independent, no unrelated keys move, and undo grouping
matches the earlier primitive behavior. Mocks do not establish host gesture or
undo behavior.

Unkeyed-row linking resolves the chosen property's destination at the current
playhead, then creates the missing source key there using its sampled value.
The menu test invokes Scale → Position from inside Position's gap and verifies
creation at the destination (not at the playhead), unchanged Scale values,
reciprocal group state and one undo group. When neither side has a destination,
the linked pair is created at the playhead. The gutter now uses proportionally fitted `link.circle.fill`.

Property-menu close handling now refreshes the hidden scratch parameter after
cancellation as well as selection. Successful actions retain their existing
in-group refresh; the close delegate suppresses a duplicate write. Failed menu
actions receive a fallback refresh after their host action closes. Tests cover
both close/action callback orders, default-mode deferral, balanced action scopes,
and unchanged pose data on dismissal. The link badge uses the monochrome symbol
variant with a shared tint for each linked group; its membership behavior remains unchanged.

Persistent property link menu tests assert that button callbacks queue their
host work on the main dispatch queue, with no host calls before returning.
Multiple toggles update the same menu, retain other memberships, and create one
undo group and host refresh per operation. Unkeyed pairs are created at the
playhead with their original values; linking to an existing destination retains
its time. Actual menu persistence and padding still require Motion/FCP testing.

Open-menu history tests exercise FxCommandAPI_v2 undo/redo inside a host action,
then refresh cached keyposes and menu checkmarks. They verify no additional
scratch edit or undo group is introduced by history commands. Missing command
API returns unhandled. Event delivery while a real host menu tracks remains a
manual check. The user confirmed working apply, undo and redo after the cached
link path and callback-driven menu refresh; temporary diagnostics were removed.

Open-menu undo/redo also uses the existing shortcut capture, scoped to a weak
menu owner. Router tests verify deferred execution outside the input callback,
modifier/repeat handling, cancellation on close or replacement, and weak-owner
expiry. The user confirmed event-tap undo/redo delivery in the host.

Menu history regression: the host may return NO from `performCommand:` while
applying undo asynchronously. Tests reproduce that result and a later parameter
callback, then verify the checkmark follows published caches without new edits.
The menu subscribes only while open; queued notifications after closing are
ignored. Native parameter callbacks enqueue UI updates without blocking their
callback thread.

Apply dispatch regression tests also cover two rapid clicks, a menu closing
before an accepted click runs, and the inspector control being destroyed before
dispatch. Each accepted live-control click retains native keyframe validation,
one undo group, and one scratch write. Host testing showed that dispatch alone did not release the keyframe-count
query; the dedicated cached link path below resolved the delay.

Link transaction regressions verify that successful linking/unlinking and silent
partner creation use cached keyposes without keyframe-count or enumeration
calls. Moves retain their host preflight. A failure test inserts an unrelated
native key between link writes, then rejects the second write: recovery resolves
current indices, removes only the transaction's additions, preserves the unrelated
key, and refreshes the resulting cache. Link recovery never clears/rebuilds a
whole lane. Failure recovery may query the host; the successful path does not.

Group-colour tests verify that linked properties share one gutter tint, separate
groups get distinct available palette slots, and moving or undo-restoring a
group preserves its tint without native key queries. Assignment uses persisted
group identity with collision resolution retained for the effect instance. The
finite palette repeats when all slots are allocated. Colours are presentation
state, not additional keypose data.

Linked graph preview tests cover a Position gap from 0–4s and Scale from 2–4s,
including selection before Scale's first key. Both share the same x-axis; rendered
paths begin at their own source fractions and end together. Each property uses
its existing evaluator (including Added Motion) and component colours, with
vertical fitting per property when units differ. Unlinking removes the peer.
Tests verify no native key reads and preserve existing playhead/path caching.
Properties without an incoming gap have no transition curve to draw.

The timing graph publishes its displayed parameter set via the inspector
presentation notification. Row tests verify coloured axes on both Position and
Scale while only Scale's label is selected, neutral suffixes, and clearing a
peer's tint when it leaves the graph. Editor tests verify the published set after
unlinking and clear it when the graph detaches. This uses the actual displayed
curves, not a separate interpretation of group membership in each row.

### Added Motion handoff

Added Motion is evaluated over the source hold, with the legacy Hermite blend
bridging into the incoming transition. After that handoff, samples match plain
easing. Available-time transitions have no hold and therefore no added motion.
Engine tests cover all three motion types and easing types, zero values, continuity,
plain-transition equivalence, and exact endpoints. Shared popup tests cover
exclusive checkmarks after stale marks and cell-level selection changes.

### Added Motion component controls

The Added Motion label menu offers Independent Motion (checked means separate
component patterns) and an inline PARAMETERS group for axis masks. These options are separate from keypose
timing links. The dice chooses a saved seed; Amount / Speed Reset Parameter
restores just those two values. Menu actions use the shared host-refresh lifecycle
and one undo group. New timings default to linked components; older archives
without the options retain independent components.

Coverage includes secure metadata roundtrips and older archives, deterministic
seeds, linked/unlinked phases, masks, Position's internal component ordering,
amount-zero evaluation, rejected writes, reset scope, and menu/dice undo grouping.

`BlurAnchorTests` covers the new lanes' secure persistence, interpolation,
incoming/outgoing timing ownership, scalar bounds, unbounded anchor values,
explicit edits, failed writes, linked combined graphs and release-only linked
moves. It checks reset rollback, defaults, balanced undo groups, row order,
animation flags, pixel suffix/precision, render state and read failures.
The shared InspectorControls tests cover a slider row with a non-percent suffix.
These checks do not establish host gesture delivery or save/reopen behavior;
see the Blur/Anchor host checkpoint in the plugin README.
