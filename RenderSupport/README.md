# RenderSupport

Metal rendering helpers for plugins, using Apple frameworks. Plugins pass in textures and settings; the package does not use FxPlug or read keyframes.

- `RSMetalResources.m` selects the GPU by registry ID and caches pipelines by device, bundle, format, and shader functions.
- `RenderSupport.m` reuses command queues and sample textures, applies Gaussian blur, and averages motion-blur samples. The texture pool keeps the four most recently used size/format/device combinations.
- `Shaders/RenderSupport.metal` supplies the accumulation shaders. Each plugin compiles this source into its own default Metal library; MagicMove uses a small `.metal` include file for this.
- `RSOSCDrawing.m` builds the vertices for viewer on-screen controls (box outline, capsule handle glyphs, the anchor square and the rotation gizmo quad) and draws them into a host texture in one clear pass, rings first so glyphs stay on top. `Shaders/OSC.metal` holds the matching shaders and is compiled into the plugin library the same way; `RSOSCShaderTypes.h` is the vertex and ring parameter layout both sides share.

Motion blur samples the shutter window at a 90 kHz time resolution. Only one blur render runs at a time to limit memory use. All samples and the final average use one command buffer and one completion wait. Textures return to the pool after the GPU finishes, or when a failed render is abandoned before submission. Return borrowed command queues after completion; borrowing returns nil when all queues are busy.

The plugin supplies the render callback and handles source-frame selection, tile geometry, and saved parameters.

The code is adapted from the KeyframelessKit Metal helpers and MagicMove Gaussian pass, under the PolyForm Noncommercial license.

## Tests

```sh
RenderSupport/Tests/run.sh
RenderSupport/Tests/run.sh --cpu-only
```

The full run compiles the shaders and checks timing, GPU selection, queue limits and recovery, pipeline caching, sample averaging, shared command buffers, and texture reuse. MagicMove’s additional GPU tests exercise the production FxPlug adapter, spatial blur, transforms, and anchor handling.
