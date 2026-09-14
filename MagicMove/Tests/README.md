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

The suite compiles current plugin and shared-package sources with AddressSanitizer and UndefinedBehaviorSanitizer. Only Apple's FxPlug runtime is reused from the built app. Tests do not register an effect, modify a host document, or load archived frameworks. Temporary test artifacts are cleaned up.

## Suites

| Runner | Scope |
| --- | --- |
| `InspectorControls/Tests/run.sh` | AppKit layout, value editing, menus, sliders, and header |
| `MotionTiming/Tests/run.sh` | Timing evaluator and keyframe association records |
| `RenderSupport/Tests/run.sh` | Subframe timing, real Metal resource handling, accumulation, and failure recovery |
| `MagicMove/Tests/run.sh` | Plugin code with `MockHost` and other simulated host APIs |
| `MagicMove/Tests/run-shader.sh` | Freshly compiled transform shader and pixel comparisons |
| `MagicMove/Tests/run-blur.sh` | Production render adapter, motion/spatial blur, anchor, and preview scaling |

Select plugin suites with `MM_TEST_SUITES`, for example:

```sh
MM_TEST_SUITES="ModelTests NativeLinksTests" MagicMove/Tests/run.sh
```

Standalone package runners do not require a built plugin. RenderSupport accepts `--cpu-only` to omit GPU checks. The plugin blur test uses the built app's metallib, so rebuild after changing shaders. A skipped GPU stage is not a successful GPU verification.

## Coverage

| Area | Checks |
| --- | --- |
| Timing | Incoming duration and easing, holds, zero duration, available time, gap limits, endpoint values, and sampling in any order |
| Keyframe association | Matching by time/value/order, insertion, deletion, crossing, multi-selection, and retained settings |
| Property editing | Static values, single and multiple keyframes, component preservation, explicit editing, and reset |
| Links and endpoint matching | Partner creation, independent values, shared timing, moves, deletion, unlinking, and failed-write rollback |
| Inspector and graph | Gap selection, cached curve samples, enablement, property switching, units, and one undo group per drag |
| Saved data | Secure coding, older records, full-width IDs, duplicate effects, corrupt data, and restoration without extra writes |
| Callbacks | Reentrant and delayed notifications, undo restoration, drag completion, stale reads, and missing host APIs |
| Rendering | Captured state, source tile bounds, shader pixels, premultiplied alpha, blur, anchor, and preview scaling |

## Compatibility and resource checks

`HostLifecycleTests` verifies detached instances, document attachment, timer cleanup, weak API-manager ownership, and decoding an archive produced by the original framework. [Fixtures](Fixtures/README.md) documents the historical payload and Added Motion golden samples; do not regenerate expected data from the implementation being tested.

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

Include the application versions, checks you ran, and results in the pull request.
