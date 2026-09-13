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
Motion blur is available through the primitive toggle described below.

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

## Added Motion checkpoint

Each scalar property and the combined pose have an Added Motion dropdown:
None (default), Wave, Wiggle, and Handheld. Amount, speed, and component selection
remain fixed for this checkpoint; there are no extra shape controls yet.

Added Motion belongs to the outgoing keypose: between K2 and K3 it edits K2,
while incoming duration and easing edit K3. At a key it edits that key's OUT.
The dropdown disables before the first key and at/after the last key, where no
outgoing interval exists. Its value and availability refresh during scrubbing.

Motion covers the entire interval, including the hold and transition and gaps
filled by Use available time. The shared C evaluator ports the existing wave,
wiggle, handheld, and two-half Hermite join smoothing. Keypose values remain
exact, and None preserves the existing timing behavior. The combined dropdown
applies the selected motion type to both Position X and Scale, with the existing
deterministic component variation; scalar properties retain
independent motion choices even when their keyframe times are linked.

The choice is saved with its owner and follows native keyframe moves. Legacy
poses default to None. Native keyframe controls continue to create keyposes;
explicit value editing and incoming easing preserve the outgoing motion choice.

## Motion Blur checkpoint

Motion Blur is a saved, non-animated native toggle, off by default. It restores
Magic Move's pre-archive sample-and-accumulate path through the current shared
`KKMotionBlur` implementation: 180-degree shutter, 16 full-resolution samples,
and the existing backward shutter sampling on a high-resolution clock.

The port retains pooled textures, bounded concurrent blur renders, and a single
command buffer/GPU wait for all sample draws and accumulation. This is the old
Magic Move path; Canvas's velocity reconstruction is a separate implementation.
Each output frame reads one native keypose snapshot and evaluates its shutter
samples in memory. Both scalar and combined poses include incoming timing,
easing, and outgoing Added Motion. Blur averages the transformed current source
frame; this checkpoint does not request extra footage frames from the host.

Disabled blur retains the one-transform render payload. Enabled blur contains
16 transforms (current time first), then `KKMotionBlurState`. Render callbacks
need no parameter access. If the shared blur render cannot prepare its resources,
the existing unblurred fallback is retained. Shutter and sample controls remain
fixed until the custom UI checkpoint.

CPU tests compare all shutter samples against ordinary engine evaluation. The
Metal integration test runs the production renderer and shared accumulation,
checking a moving premultiplied image, alpha conservation, a shared command
buffer, and the sharp disabled path. Live playback performance still requires
manual host testing.

### Clean keypose editing preview: host limitation

Desired behavior: hide blur when paused exactly on a keypose, with no indicator,
while retaining blur during playback and export. This is not implemented.
The installed FxPlug SDK's `pluginState:atTime:quality:error:` supplies render
quality, not a preview/playback/export purpose. Neither its timing API nor image
tile exposes a reliable paused-preview flag. `KKPlayheadPoller` estimates playback
from recent playhead movement; its comments document stalls during playback.
That estimate must not control the effect's rendered pixels: the host can retain
render state/output, and an editing-only sharp frame must not enter playback or
export. Implement this only with a verified preview-only host mechanism or a
separate viewer overlay; render quality and idle-time heuristics are insufficient.

Document-membership diagnostic (Motion, 2026-09-12): the editing instance and
both export instances received `pluginInstanceAddedToDocument` before rendering.
The second export had motion blur enabled and rendered 300 frames; every draw
reported one document callback. This public callback therefore did not distinguish
editing from export in this test. Temporary lifecycle/render probes were removed
after capture; the diagnostic did not change rendered pixels.

### Motion Blur shortcut

Control–Option–M toggles the normal saved Motion Blur setting. The binding uses
physical M (keycode 46); customization belongs in the future settings popover.
The shortcut uses MagicMove's own event adapter and router, with no legacy
shortcut dependency. Event capture remains in the plugin, outside MotionTiming.

The visible combined inspector row makes an instance eligible. With several
eligible rows, click the intended row first; the last interacted-with eligible
row owns the shortcut. With one eligible row it is selected automatically.
Repeats do not toggle again. Text editing and mouse gestures suppress the action.
Host-focused capture is limited to Motion/FCP and requires macOS to permit the
consuming keyboard event tap and focused-element query. Plugin-local events use
AppKit. This is a saved toggle, not a preview-only bypass: turn blur back on when
wanted for export.

Automated shortcut tests cover matching, routing, weak owners, repeat handling,
and parameter writes/action cleanup. Host checkpoint: toggle from the timeline,
verify the inspector and image update once per press, undo/redo once, switch clips,
and verify another effect is not changed. Also check typing and held keys.

### Position inspector UI checkpoint

Position and Scale are visible. Each row’s X/Y pair shares one native keyframe
control; the two rows have independent keyframe lanes. All other parameters remain registered and saved but hidden, including
when their enabled state refreshes. Existing combined poses retain their stored
scale and metadata; older poses decode Y as zero. New Y values participate in
sampling, edits, and motion blur. Saved positions retain the normalized engine
convention; the inspector converts each axis to pixels using the host object's
dimensions published by the plugin’s image callbacks. The calculation ports
`KKMiniViewerPixelReferenceSize` and applies `inversePixelTransform` to full image
bounds, removing preview scaling and accounting for pixel aspect ratio. No OSC
API or viewer feed is required. Geometry stays on the plugin instance so recreated
rows can use it immediately; until the first valid image callback the row waits
for dimensions rather than displaying false pixel values.

The row adapts the existing `KKParameterRowView`, `KKLabelView`, and
`KKValueTextField` implementations without linking those classes. These
presentation components now live in `InspectorControls`. The requested
refinement uses an 11 pt label, values, and X/Y and px decorations
in #B3B3B3. The legacy responsive column calculation leaves the numeric fields
free to expand as the inspector widens (with narrow-width safeguards). Native
keyframe controls remain host supplied.

`ICValueTextField` ports click-to-edit, continuous cursor scrubbing (1 px per
4 points of travel), Shift coarse / Option fine adjustment, Return, Tab and
Shift-Tab, clipboard shortcuts, and click-away commit. Refresh skips the entire
edit or scrub session. A scrub brackets all value writes in one host undo group;
a typed commit uses one group. Cursor and grouping cleanup runs on exceptional
exits as well. These interactions still require host testing for event routing
and FCP's undo behavior.

Host check: add a fresh effect, verify Position and Scale appear, key two different
X/Y values, scrub between them, edit each axis independently, and resize the
inspector. Verify one native keyframe control owns the pair and that switching
filters does not display placeholder numeric defaults.

Position row spacing follows the existing `KKParameterRowView` / `KKLabelView`
implementation: register an empty custom parameter name (avoiding a separate
host label line), draw the label with a 21 pt inset, and reserve 75 pt at the
trailing edge for host controls. The adapted layout relaxes column minima when
space is narrow instead of overflowing. It does not link the legacy row classes.

Field host check: click/type X and Y, Tab between them, Return and click away;
drag each value continuously and with Shift/Option, then undo once. Check px
values against a known frame size and confirm scrubbing does not select text.

Geometry regression checks exercise the production image callback and row with
OSC access absent, half-resolution preview dimensions, a partial requested tile,
recreated rows, pixel edits, and independent plugin instances. Host testing still
needs to confirm event routing for click/type and drag/undo.

Numeric Position readouts sit 2 pt below the label/decorations and always show
whole pixels without decimals. Formatting does not round stored
values; scrub updates also pass their full value through the formatter.

The X/Y groups include 12 pt of extra separation, increasing the host-measured
visible gap from 6 px to 18 px while retaining expanding value fields.


### Scale inspector checkpoint

Scale and Position consume `ICInspectorRow` and `ICValueTextField` from the
independent local `InspectorControls` package. MagicMove retains host integration.
Scale displays X/Y percentages with one decimal place and has a chain toggle in
the label column. The saved, nonanimated proportional toggle defaults on. Linking
preserves the existing ratio; it does not immediately change values. Unlinking
allows independent axes. If the edited axis starts at zero, the partner follows
the same delta; proportional values are bounded together at 400%.

`MMScalePose` stores both percentages in a separate native custom parameter.
Position keys and saved combined/scalar scale data remain intact; legacy scale
rendering remains active until the new Scale lane is authored or keyed. Scale
uses per-pose incoming timing (default 1.2 seconds) and supports explicit
creation against its own next key. Each row owns a separate disposable cache.
Scale requires no image geometry. Unequal axes are evaluated at each motion-blur
sample and rendered independently.

Host check: key Scale at two times independently of Position; drag each row’s
native keys. Test linked edits from 100/100, unlink and make 150/75, then relink
and change X to 200 (Y should become 100). Toggle linking without changing values,
undo a field drag once, reopen the inspector, and verify saved linking state.
Confirm nonuniform scaling and motion blur in the viewer and after export.


`InspectorControls/Sources/InspectorControls/InspectorTokens.m` centralizes the validated inspector typography, colors,
row spacing, and numeric baseline offset. It is AppKit-only and has no FxPlug or
legacy-library dependency, shared by the controls in InspectorControls.
The host accent ports the legacy #5B5CE9 value for FCP/Motion and is shared by the
active chain icon, caret, and selection highlight. The chain icon is centered on
the Scale label's capital-letter metrics, independent of the numeric offset.

The XPC service links the local static InspectorControls package.
`Plugin+CustomRow.m` is the MagicMove adapter: it configures components, binds
callbacks, and owns host reads/writes, unit conversion, undo, shortcut routing,
and snapshot refresh. Package usage and standalone checks are documented in
[InspectorControls](../InspectorControls/README.md).


### Shared timing editor — first UI iteration

Position and Scale now share a single inspector panel. Click either property row
to select it; a translucent host-accent overlay marks the active row. Native keyframe controls still create and move
poses; the graph is read-only and has no curve handles.

The graph shows the current gap's evaluated components, including added motion,
and a live playhead. Curves are solid and use stable component colors matching
the selected row's axis decorations. Components share a value range: Position
uses image pixels, Scale/Opacity percentages, and Rotation degrees. Each gap is
fitted independently.
The graph header shows the source and destination keyframe times in seconds.
At an exact arrival, the panel shows the gap that just completed; the first pose
shows the first gap. Outside the keyed sequence, or with fewer than two poses,
there is no editable gap.

Duration, Use available time, and easing edit the displayed gap's destination.
Added motion type, amount, and speed edit its source. The source/destination
labels make ownership explicit. Available time retains the requested duration;
longer durations are capped by the engine without rewriting the saved setting.
The amount is a multiplier displayed as a percentage; speed is relative to the
existing motion algorithm's frequency over that gap.

`MMPoseTiming` stores these settings in each native custom pose with secure coding.
Older poses without this payload default to 1.2 seconds, available time off, and
100% amount / 1× speed. `MMTimingEditorModel` owns gap selection and host writes;
`MMTimingEditor` owns presentation and undo. Cached snapshots feed both rendering
and the preview. UI refresh does not enumerate native keys; the graph is sampled
again only when pose contents, gap, property, or image dimensions change. Fresh
render snapshots with identical contents reuse the samples and curve paths;
playhead updates do not rebuild either. Control updates and graph work run after
the read-only host action has ended.

Automated checks cover persistence, correct endpoint writes, duration evaluation,
metadata preservation during value edits, lane independence, graph sampling,
read counts, empty state/layout, and one undo group per numeric drag. Real host
check still required: select Position/Scale, scrub across gaps and exact keys,
change duration/easing/added motion, undo a drag, move native keys, save/reopen,
and compare the graph's motion with the viewer. Native popup styling and host
layout/event delivery require Motion/FCP confirmation.

Timing panel writes publish the successfully written pose directly into the
inspector cache. They must not call native-key enumeration while the custom
parameter action is open: host diagnostics measured 1.78–4.24 second stalls in
that post-write refresh. Host callbacks and rendering remain responsible for
reading authoritative key snapshots. Local publication advances the cache
generation so an older in-flight read cannot overwrite the new pose.

Callback refreshes retain the last complete inspector snapshot while reading
native keys, then atomically publish the completed result. A completed failed
read publishes an unavailable snapshot; an in-progress read does not briefly
clear the graph or disable controls. Tests observe the panel during both
Position and Scale reads and verify failure and recovery separately.

The active-row highlight stops before the 75-point native-controls gutter,
matching legacy `KKParameterRowView` background bounds. The MagicMove row also
returns no hit in that gutter so native keyframe controls remain reachable.
Regression checks cover gutter passthrough and numeric-field hits across widths.

### Opacity inspector

Opacity is an independent native custom-keyframe lane (2000), defaulting to
100%. Its slider and one-decimal field use the shared `InspectorControls`
slider port and painted percentage suffix. Clicking the row selects its single
curve in the shared timing panel; incoming duration/easing and outgoing added
motion use the same ownership rules as Position and Scale. Explicit creation
redirects value edits to the destination keypose.

`MMScalarPose` and the immutable `MMPropertyLane` adapter provide scalar payloads,
secure coding, disposable per-inspector caches, and MotionTiming sampling
without coupling the controls library to FxPlug. Opacity multiplies premultiplied
RGB and alpha in every render sample, including motion blur. Slider drags group
writes into one undo operation. Host interaction still needs manual validation.

### Rotation inspector

Rotation is one native custom lane (2100) containing X/Y/Z degree values,
all defaulting to zero. A single keypose carries all three axes and incoming
metadata. Values stay unwrapped for multi-turn animations; only render angles
are reduced before trigonometry. X/Y tilt an orthographically projected image
plane and Z rotates it in-plane, in X-then-Y-then-Z order. Edge-on planes render
transparent. Position, local-axis Scale and Opacity continue to compose with it.

Rotation and Opacity reuse `MMPropertyLane`/`MMPropertyPoseCache` for native reads,
atomic cache publication and timing; `MMPropertyRowBinding` handles inspector
refresh, explicit targeting, selection, shortcuts and undo for slider and vector
rows. `InspectorControls` remains AppKit-only. The timing graph accepts arbitrary
component arrays, draws one solid colored curve per axis and keeps component
colors stable across selection changes.

Temporary timing latency and click-routing probes were removed after host validation.
`MM_INSPECTOR_DEBUG_PAINT` retains opt-in layout painting, disabled by default and
excluded from Release builds.

### Blur and Anchor inspectors

Blur (2300) and Anchor (2400) appear directly below Opacity, in that order.
Both use `MMPropertyLane` and the existing native-keyframe timing, linking,
reset, graph and Added Motion paths. The shared lane registry handles cache
lookup, host callbacks and allowed secure-coded payload classes.

Blur reuses the scalar payload and slider row, with a `px` suffix and whole-pixel
readout (0–100). Its value is Gaussian sigma in full-resolution source pixels.
The renderer ports `KKMagicMoveBlurredTexture` from old MagicMove commit
`cb0c3d9a`: an MPS Gaussian pass before the transform, clamped edges, a
negligible-radius bypass, and the original 256 texture-pixel performance cap.
It has no Mirage dependency. The old percentage-to-sigma mapping is replaced
by pixel units. Blur follows the clip's transform and is evaluated for each
motion-blur sample on the same command buffer.

Anchor uses a secure two-component payload, with X/Y whole-pixel fields and
zero at the image centre. It controls the pivot for scaling and rotation;
changing Anchor alone at identity leaves the image in place. Pixel values are
converted using the source image's inverse pixel transform so reduced-resolution
previews retain the full-resolution anchor and blur appearance. Anchor values
can extend outside the image; its ±1000 range defines Added Motion amplitude,
not an editing limit. Blur defaults to zero, Anchor to (0, 0).

Host checkpoint: the user confirmed Blur and Anchor work well in the host.
The timing panel row gaps were then reduced by 3pt to match the requested 16pt
spacing, preserving divider padding. Build and timing panel tests passed.

Extended host checks: check both rows below Opacity, create/move native
keyframes, adjust incoming timing and outgoing Added Motion, link to another
property, reset/undo, and save/reopen. Inspect Blur at full and reduced preview
resolution; inspect Anchor while scaling/rotating, with motion blur on and off.
