# MagicMove architecture

MagicMove handles FxPlug callbacks, parameters, saved values, undo, inspector views, and image tiles. It links three local static packages:

| Package           | Responsibility                                         | External frameworks                                   |
| ----------------- | ------------------------------------------------------ | ----------------------------------------------------- |
| MotionTiming      | Deterministic timing and Added Motion evaluation       | None                                                  |
| InspectorControls | Reusable inspector layout and interaction              | AppKit, CoreGraphics                                  |
| RenderSupport     | Metal resources, spatial blur, and sample accumulation | Foundation, CoreMedia, Metal, MetalPerformanceShaders |

The application embeds Apple's FxPlug and PluginManager frameworks.

## Keyframes and persistence

Property values are immutable, securely coded custom parameter objects. The host owns their keyframe times. Timing metadata travels with each value through `MMPoseTiming`; `MMPropertyLane` and the property adapters handle reads, edits, rendering, and reset.

Incoming duration/easing belong to the destination keyframe. Added Motion belongs to the preceding keyframe. Linking synchronizes native keyframe times and incoming settings while preserving independently editable values and motion settings.

Match In/Out is lane-wide, so each property keeps it in one hidden toggle rather than repeating it in every keyframed pose. Endpoints are then resolved positionally on each read and no insertion, deletion or move has to migrate stored state. A timing or value edit walks a small graph of edges: link members share timing and motion settings, and a matched property pairs the incoming transitions of the second and last keys and the values of the first and last. Each edge carries only the settings it owns, so values mirror across a match but never across a link. The walk ends in one write, one undo group and one cache publish. Key structure changes queue the property during the native callback and re-pair it on the deferred commit path, because evaluating the pairing needs host reads that do not belong in a callback.

Native APIs do not supply persistent identities for individual keyframes. Association uses unchanged times, values, and relative order to match old and new snapshots. When identical values move, the result can be ambiguous. Tests cover crossing keyframes and moving multiple selections.

The plugin implements `KKDataBlob` with the same Objective-C class name and `data` archive key so saved timing records still decode. Some hidden parameters are also kept for compatibility with saved effects.

## Host actions and cached state

Create parameters without starting host-action polling. Start the refresh timer only after `pluginInstanceAddedToDocument`, because detached library and drag instances do not have ready timing APIs. The plugin holds its API manager weakly and invalidates its timer when released.

Every host write needs a custom-parameter action, with a matching end call. Related writes share an undo group. Native linked-key drags defer partner writes until release to avoid interrupting the host's drag operation. Callback handling accounts for reentrant notifications, delayed echoes, undo restoration, and failed writes.

Inspector views read cached snapshots rather than enumerating native keyframes on every refresh. Publish a complete snapshot atomically; generation checks prevent an older read from overwriting a newer edit. A failed read marks the snapshot unavailable. Successful panel writes update the local cache directly: enumerating native keys during the write action can stall the host.

Each plugin instance owns one view cache per property and publishes their tokens in a single host action, from `pluginInstanceAddedToDocument` or the first view build. Rows read those caches; they never create or publish their own. The host rebuilds every inspector row several times per selection and keeps more than one generation alive, so a per-row token write cost a host round trip each time. Instances created before the host exposes a setting API publish on the next cache access.

Inspector views poll because the host has no playhead-movement callback. `MMInspectorClock` owns one 10Hz timer per plugin instance and refreshes every registered view from a single host action, instead of each view running its own timer and action. Registrations are weak and the timer only runs while views are registered. Both the clock and the deferred-edit timer run in the default run loop mode: a host action opened inside an AppKit tracking loop is what the menu paths deliberately avoid. Values therefore hold still while a menu or tracking loop is up. Each view keeps a standalone refresh method for direct callers, which opens its own action and delegates to the same action-scoped body.

Menu actions use the hidden custom scratch parameter to request host refresh. This asks the host to repaint without moving the mouse. The plugin handles this write and its undo group.

The graph reuses sampled curves until values, gap, selection, or image geometry change. Playhead updates do not rebuild curves. Row highlights and hit testing leave the native keyframe-control gutter available to the host.

## Rendering

`pluginState:atTime:` captures parameters and computes transform samples. Rendering uses those captured values without writing parameters. All render geometry works in canonical square-pixel space: the transform aspect, the Anchor pivot, and the Blur sigma come from a tile's pixel bounds mapped through its inverse pixel transform, so preview scaling, proxies, and non-square pixels cannot distort the result. The host adapter preserves sub-tile UV mapping and selects the GPU using the destination image's device registry ID.

Magic Move redistributes pixels: an output pixel can come from anywhere in the input, and the output reaches past the input frame. Two static properties are therefore required. `ChangesOutputSize` makes the host call `destinationImageRect:` and size its output from that rect. `NeedsFullBuffer` is also required, despite its documented performance cost, because the host otherwise tiles the render in full-width horizontal bands and stops issuing bands before covering the grown output, clipping moved content along a band edge. That clipping can only appear vertically, since the bands are never split horizontally, and answering `sourceTileRect:` per tile does not change which bands the host enumerates. Motion's own warp filters do not need either key: a fisheye samples from elsewhere inside the frame but never places a pixel outside it, so its output rect equals its input rect. The cost is bounded by the one-frame cap on `destinationImageRect:` below and by `sourceTileRect:` still answering with the minimal region.

`sourceTileRect:` answers each destination tile with its own inverse-projected source region, the same inverse the shader solves, unioned across motion-blur samples and widened by the Gaussian reach. A degenerate or edge-on transform has no invertible region, so the whole image is the only safe answer. The host may still hand over less than requested, so the renderer derives the source mapping from the tile it actually received: the shader keeps its math in frame coordinates and maps into the texture through that tile, so a partial tile lands where it belongs instead of stretching across the frame. Anything the host omitted reads as empty, like a sample outside the image.

`destinationImageRect:` returns the transformed source quad, not the frame, because Position and rotation carry content outside the clip's own frame and anything cut there is gone before the host applies its own transform. The rect is the union of the frame and the transformed extent across all motion-blur samples, widened by the Gaussian reach and capped at one frame of margin per side so a 4K allocation stays affordable. The extreme ends of the Position range still clip. Since the output is then larger than the frame, the shader converts destination coordinates into frame coordinates before the inverse transform, and inspector and on-screen geometry are published from the source image rather than the grown destination.

Motion blur samples at 90 kHz, reuses textures, and limits concurrent renders. All samples and their final average use one command buffer and one completion wait. Spatial Gaussian blur clamps at the image edges, skips radii below 0.5 texture pixels, and caps sigma at 256 texture pixels. If motion-blur resources are unavailable, the plugin renders a sharp frame.

The shared accumulation shader is compiled into the plugin's own default Metal library. RenderSupport has no FxPlug types: image tiles, frame times from the host, and source-frame selection remain in the plugin.

## On-screen controls

`MagicMoveOSC` subclasses `OSCViewerControl`, which owns the shared control behaviour: the host geometry, draw and hit precedence, cursor arbitration and the per-tick undo group. The plugin supplies the pose read, the visibility parameters and the lane writes. Drawing goes through `RenderSupport` (`RSOSCDrawing` builds the vertices and encodes the clear pass; `Shaders/OSC.metal` is compiled into the plugin library), and the cursor art through `OSCViewer`'s `OSCCursor`. Four hidden saved toggles control visibility: `MMShowPositionOSC` owns the outline, `MMShowScaleOSC` the handles, `MMShowRotationOSC` the rotation rings and `MMShowAnchorOSC` the anchor square. Hiding the handles also removes them from `OSCBoxHitTest`, so no invisible resize region remains, and hidden rings or a hidden square are neither drawn nor hit-tested; hiding the outline is visual only, because the position drag covers the whole canvas and behaves the same everywhere. With everything hidden the draw is just the surface clear.

The rotation gizmo is three great circles, one per Euler axis, centred on the render's pivot: the position offset plus the anchor, which is the point the image actually turns about. `OSCRotationGeometry` builds the pose as the render's own `Rz * Ry * Rx`, so the screen block of that matrix is the image plane's projection and the rings tilt exactly with it. Its frame is canvas pixels with Y up and Z toward the viewer, and only the near hemisphere is grabbable, because the far half draws dimmed and reads as empty space. Grabbing a ring turns the object about that axis as a trackball: each tick composes the press pose with an elemental rotation, decomposes back to Euler angles on the branch nearest the previous tick, and unwraps, so a sweep past 90 degrees stays continuous and full turns accumulate instead of wrapping. Cmd snaps the dragged axis onto whole 15 degree marks, 0, 15, 30 and so on, by quantising the press angle plus the turn; the snap stays on the object-axis turn, before composing, since snapping the decomposed angles would jiggle the other two. All three axes go out in one `writeValues:` per tick, and the rings draw in a second pipeline before the glyphs, so the scale handles stay on top. Hit precedence after the anchor square is handles, then rings, then the position drag. `OSCViewerControl+Rotation` owns that drawing and hit test; the box outline and handles share none of it.

The anchor square is the pivot handle on that same point, hidden by default because the pivot only matters while it is being moved. It is a rounded square rather than a round handle, ported from the archived square glyph and drawn last, over the outline, the handles and the rings. It is hit first, being the smallest target and sitting inside the position drag region, and its drag moves the Anchor lane by the pointer's own displacement in image pixels, so the pivot follows the pointer one to one however far off-centre the square was grabbed. Because `OSCBoxCorners` measures from the anchor, moving it under a rotation or a non-unit scale also moves the rendered image; that is the render's own geometry, not something the control compensates for.

The controls also hide while the playhead moves, whether it is playing back or being scrubbed, which `OSCViewerControl` infers from the time each draw tick carries: the host tells a control nothing about transport state. That is display only, and the saved toggles, the hit precedence and an in-progress drag are unaffected.

Getting them back needs the plugin, because a control cannot invalidate itself and the host issues no draw tick once the playhead parks. `MMOSCPlayheadNudge` watches the playhead on the inspector clock and, once it settles, writes a nonce to `MMHostRefreshToken` exactly as the inspector's own settings do: the host re-renders, `drawOSC` runs again, and the control's own inference now sees a parked playhead. One write per stop, skipped entirely when every control is switched off, and wrapped in a named undo group because no parameter flag exempts the write from the undo stack. The control still resets its inference on pointer and key callbacks, which recover it immediately without waiting for the nudge.

Every viewer drag opens and closes its undo group inside the tick that writes. A group cannot span callbacks: the host scopes it to the calling thread, where `startUndoGroup` pushes a live-thread scope keyed on the pthread and `endUndoGroup` pops it, while OSC callbacks arrive on a concurrent dispatch queue. Holding a group from the press to the release therefore pops a scope on a thread that never pushed one, and the host faults reading that thread's empty scope stack.

The toggles appear as checkmarked items in the logo header settings menu and in the Position, Scale, Rotation and Anchor row menus. All surfaces share `MMToggleBoolSetting`, which writes inside an undo group followed by the refresh-token write, and records the new value as the creation preference so a new effect starts from whatever was toggled last. Menu items read their state inside a host action, since `MMSettingMenuTarget` cannot read parameters outside one.

## Verification

Run the [automated tests](Tests/README.md). They use the production code with simulated host APIs and real Metal textures. Event handling, undo grouping, visual layout, and export also need to be checked in Motion/FCP.

## User defaults

`MMDefaults` defines duration, easing, and per-type Added Motion preferences using `PluginPreferences`. Pose decoding and rendering never read preferences. Automatic value edits apply defaults when they create a keyframe; native insertions use the existing deferred host-edit path. The insertion tracker rejects moves and remembers observed key states so undo restoration does not apply current preferences. A queued insertion is discarded if the key changes before the write.

`MMPoseTiming` archives Amount / Speed history by Added Motion type. Missing history is valid for existing documents. Changing a type records its current values and restores the chosen type's history, falling back to preferences only on its first use.
