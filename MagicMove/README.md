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
  saved value retained. Timing controls disable between keys and at the first.

Linked pairs share movement, deletion, and incoming timing. Values remain
independently editable. Linking adopts the initiating pose's incoming settings.
Unlinking preserves both keys and their settings. New keys are independent until
explicitly linked, even if other pairs exist or keys happen to share a time.
Existing saved pair IDs remain valid; the former global checkbox is retained as
an ignored hidden parameter solely for saved-effect compatibility.

Position 0 is centred; 100 is one image-width right. Scale 100 is original size,
0 is invisible. A zero duration cuts at arrival. Before/after the sequence the
endpoint holds. With no keys, each property uses its static native value.

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
endpoint values at their keys. Custom UI remains a later checkpoint.

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
