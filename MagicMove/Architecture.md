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

Native APIs do not supply persistent identities for individual keyframes. Association uses unchanged times, values, and relative order to match old and new snapshots. When identical values move, the result can be ambiguous. Tests cover crossing keyframes and moving multiple selections.

The plugin implements `KKDataBlob` with the same Objective-C class name and `data` archive key so saved timing records still decode. Some hidden parameters are also kept for compatibility with saved effects.

## Host actions and cached state

Create parameters without starting host-action polling. Start the refresh timer only after `pluginInstanceAddedToDocument`, because detached library and drag instances do not have ready timing APIs. The plugin holds its API manager weakly and invalidates its timer when released.

Every host write needs a custom-parameter action, with a matching end call. Related writes share an undo group. Native linked-key drags defer partner writes until release to avoid interrupting the host's drag operation. Callback handling accounts for reentrant notifications, delayed echoes, undo restoration, and failed writes.

Inspector views read cached snapshots rather than enumerating native keyframes on every refresh. Publish a complete snapshot atomically; generation checks prevent an older read from overwriting a newer edit. A failed read marks the snapshot unavailable. Successful panel writes update the local cache directly: enumerating native keys during the write action can stall the host.

Menu actions use the hidden custom scratch parameter to request host refresh. This asks the host to repaint without moving the mouse. The plugin handles this write and its undo group.

The graph reuses sampled curves until values, gap, selection, or image geometry change. Playhead updates do not rebuild curves. Row highlights and hit testing leave the native keyframe-control gutter available to the host.

## Rendering

`pluginState:atTime:` captures parameters and computes transform samples. Rendering uses those captured values without writing parameters. Source pixel transforms convert full-resolution Position, Anchor, and Blur units for preview/proxy textures. The host adapter preserves sub-tile UV mapping and selects the GPU using the destination image's device registry ID.

Motion blur samples at 90 kHz, reuses textures, and limits concurrent renders. All samples and their final average use one command buffer and one completion wait. Spatial Gaussian blur clamps at the image edges, skips radii below 0.5 texture pixels, and caps sigma at 256 texture pixels. If motion-blur resources are unavailable, the plugin renders a sharp frame.

The shared accumulation shader is compiled into the plugin's own default Metal library. RenderSupport has no FxPlug types: image tiles, frame times from the host, and source-frame selection remain in the plugin.

## Verification

Run the [automated tests](Tests/README.md). They use the production code with simulated host APIs and real Metal textures. Event handling, undo grouping, visual layout, and export also need to be checked in Motion/FCP.
