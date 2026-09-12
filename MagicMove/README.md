# Magic Move — native keyposes

Position X and Scale use native host keyframes for pose values and arrival times.
The standalone MotionTiming engine supplies incoming timing and smoothstep easing.
Each pose controls only its own incoming transition; the first pose has none.

Each property has flat inspector controls:

- **Position X / Scale** — author native keyframes and their values.
- **Link this pose** — available only at a key, including the first. Links that
  pose to the other property's key at the same time. If missing, creates the
  partner using that property's current native value. Other poses stay independent.
- **Match In/Out** — one shared toggle, available at either endpoint. With a
  single pose it creates a matching pose on the effect's last frame, or at the
  effect start if the sole pose is already on the last frame. Existing endpoints
  are reused. The former separate Out rows remain hidden for compatibility.
- **Use available time** — fills the gap from the previous pose with our easing.
- **Duration** — holds the preceding value, then transitions for the requested
  duration, capped to the gap. Disabled while using available time, with its
  saved value retained. Between keys, timing controls edit the next arrival. At a key they edit
  that key’s incoming transition; at/before the first and after the last they disable.

Linked pairs share movement, deletion, and incoming timing. Values remain
independently editable. Linking adopts the initiating pose's incoming settings.
Unlinking preserves both keys and their settings. New keys are independent until
explicitly linked, even if other pairs exist or keys happen to share a time.
Existing saved pair IDs remain valid; the former global checkbox is retained as
an ignored hidden parameter solely for saved-effect compatibility.

Position 0 is centred; 100 is one image-width right. Scale 100 is original size,
0 is invisible. A zero duration cuts at arrival. Before/after the sequence the
endpoint holds. With no keys, each property uses its static native value.

## Custom-row capability checkpoint

The Combined Pose custom row stores Position X and Scale in one immutable,
secure-coded MMCombinedPose object. Its native host keyframe captures both
components. Editing either field preserves the other component and writes the
whole object at the playhead time. Moving or deleting a combined key therefore
moves or deletes both values together without partner-key synchronization.

Once the combined row is edited or has keys, it drives the rendered transform.
An untouched, unkeyed combined row leaves the existing scalar model active.
The original scalar rows remain for comparison; their duration, link and match
controls do not currently apply to combined poses.

This checkpoint uses the MotionTiming vector sampler with a fixed 1.2-second
incoming duration per combined pose, capped to the previous gap. The first pose
holds before its key and the last holds after its key. The custom fields display
the same sampled values as rendering. FxCustomParameterInterpolation_v2 also
provides host-weighted interpolation for host requests, but rendering samples
native key times directly and does not depend on host curve weights.

The custom view samples an in-memory snapshot populated by native parameter
callbacks and rendering. A hidden, non-saved string token connects each open
view to its cache across FxPlug plugin instances. The view timer never enumerates
keys and continues refreshing during playhead scrubbing. Native timing selectors
also refresh from caches while the mouse is held, including enable/disable state.
A missing scalar cache disables stale controls until it can be refreshed safely.
Pending linked-key drags still defer their host writes until mouse-up. Failed refreshes invalidate the snapshot, and generation checks prevent
older in-flight reads from replacing a newer callback result. At an existing key,
a commit reads the current custom object directly to preserve the latest partner
component; between keys it preserves the timing engine's sampled value.

The row uses CUSTOM_UI | USE_FULL_VIEW_WIDTH. Motion has confirmed that this
separate animatable custom parameter displays a custom view and host keyframe
controls. The earlier scalar-row experiment did not display a custom view:
CUSTOM_UI was absent after attachment, and explicitly setting it returned NO.

Test on a fresh effect: create combined keys with different Position X and Scale
values, scrub, move a key, and save/reopen. Verify that each key retains both
values and that both properties animate together. Published FCP behavior still
needs host verification. Editable combined duration, per-property linking/matching,
and the rotation layout decision follow this storage/keyframe checkpoint.

## Explicit creation checkpoint

Explicit Keypose Creation defaults to off and is saved per effect. It currently
applies to the combined custom fields only; native comparison sliders retain host
behavior. Off preserves writes at the playhead. On routes edits directly to the
next combined key between poses, to the exact key when on one, and to the nearest
endpoint outside the sequence. Fields display that target pose in explicit mode.
No temporary playhead key is created or deleted to redirect an edit.

With explicit creation enabled and no combined keys, value fields are disabled
until the native keyframe button creates the first key. User testing in Motion
confirmed that the native keyframe button works with the custom row, including
explicit creation mode. Use it to create combined keyposes at the playhead;
no separate Add Keypose button is needed.
The primitive native toggle can move into the planned settings menu later.

## Easing checkpoint

Each incoming destination has a native Easing selector: Smooth (the existing
smoothstep), Linear, Ease In (quadratic), or Ease Out (quadratic). Selectors are
disabled at/before the first key and after the last; between keys they target
the next arrival. Scalar choices live with each pose's
duration records, follow moved keys, and propagate through linked/matched timing.
Combined Easing is stored in the combined native key object and affects both
components. Editing either combined value preserves its easing. Older saved
poses without an easing field retain Smooth.

Combined incoming duration remains fixed at 1.2 seconds for this checkpoint.
Motion blur is the next checkpoint; no blur is applied yet.

## Build and tests

From the repository root:

```sh
xcodebuild -workspace Keyframeless.xcworkspace -scheme MagicMove \
  -configuration Debug -derivedDataPath DerivedData/Keyframeless build
scripts/test-magicmove.sh
```

See [Tests/README.md](Tests/README.md) for coverage, prerequisites, and the real-host acceptance checklist.

Wrapper: `DerivedData/Keyframeless/Build/Products/Debug/MagicMove.app`.
The separate `com.keyframeless.MagicMoveNext` identity leaves legacy MagicMove
and Mirage intact. No release installer or update feed is changed.

## Test this checkpoint

Restart Motion and add a fresh **Magic Move · KF (Preview)** effect for the new
Match In/Out row. Publish those rows when testing an FCP template.

1. Create one Position X key, set its offscreen value, and enable Match In/Out.
   A matching endpoint should appear on the last frame of the effect.
2. Insert a middle pose and move it onscreen. Endpoint values stay matched;
   the middle pose is independent. The entrance inherits the existing exit timing.
3. Edit either endpoint value. The opposite endpoint follows on mouse release.
   Edit Duration or Use available time at the entrance destination or final pose;
   the other incoming transition follows.
4. Enable matching on an existing sequence from either end. The selected end's
   value wins. Enabling from the first pose uses KP2's incoming timing; enabling
   from the last uses the final pose's timing. Middle values remain unchanged.
5. Disable matching from either end. Both endpoints and current settings remain.
6. Test existing cross-property pose links alongside matching, then undo/redo
   and save/reopen. Matched Position X values never become Scale values.

Matching always addresses the current first/last poses. With two keys, the
endpoints have equal values and the sole incoming duration is preserved. With
three or more, the incoming settings at KP2 and the final pose match. Each
transition still independently caps its duration to its available gap.
The setting is repeated in saved records so it survives insertion/reordering;
legacy records default to unmatched. Removing all poses removes that setting.

## Implementation

`MotionTiming/` is an independent C/SwiftPM static library. Its association
helper matches existing times, then unique values, then remaining chronological
pairs. Native keys have no stable host IDs; saved pair IDs travel through this
association. Ambiguous replacements or occupied-time crossings remain a host
constraint.

MagicMove's host adapter reads endpoint values at native key times. Native
interpolated slider values can differ from rendered intermediate values; edit
endpoint values at their keys. The Combined Pose custom row uses the separate
vector sampling path described above.

The contextual checkboxes and duration rows are transient, non-animatable,
non-saved editors. Separate hidden secure-coded blobs persist each property's
records, pair IDs, and endpoint matching. Edits happen inside host callbacks with a reentrancy guard;
render evaluation never writes keys. Failed native edits/saves attempt to restore
both affected lanes and report an error to the host.

The refresh timer starts only after `pluginInstanceAddedToDocument`, never during
parameter creation for detached library/drag instances. The 30Hz timer uses host action scopes and actual playhead time to
refresh controls, reusing cached snapshots and writing only changed flags/values.
Edits invalidate snapshots with generation guards against stale render results.
Last-published transient values survive invalidation so delayed display-write
notifications are ignored rather than treated as timing or unlink commands.
Key matching uses one microsecond tolerance, not neighbouring frames.

The mock-host tests exercise real callbacks, per-pose link state, independent
keys, silent partner sampling, moves, deletion, unlinking, persisted pair IDs,
reentrant and delayed callbacks, drag bursts, and native/save failure rollback. They do not emulate
Motion/FCP's native drag or undo implementation.

MagicMove still subclasses KeyframelessKit's KKPlugin and uses its Metal helpers,
shader types, KKDataBlob, logging and inherited lifecycle behaviour. It does not
use Mirage's timeline, popovers, mini viewer, or constants UI.
