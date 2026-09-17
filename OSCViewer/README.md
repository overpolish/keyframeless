# OSCViewer

The FxPlug side of viewer on-screen controls, shared by plugins that show a transformed image with handles. It depends on `OSCControls` for the pure geometry and `RenderSupport` for drawing, and carries FCP's cursor art.

- `OSCViewerControl.m` implements `FxOnScreenControl_v4`: the instance lifecycle, the subclass contract's defaults, canvas geometry from the host, and the saved per-element visibility reads. It does not read keyframes or write lanes.
- `OSCViewerControl+Draw.m` owns the draw tick: the playhead-motion verdict that decides whether the elements appear at all, the four-element append (box outline, scale handles, rotation rings, anchor square) and the Metal pass.
- `OSCViewerControl+Input.m` owns everything the pointer and keyboard reach: hit precedence (anchor, handles, rings, position drag), cursor arbitration, the drags with their per-tick undo groups, and the callbacks that bring a hidden control back.
- `OSCViewerControl+Rotation.m` owns the rotation gizmo: ring drawing parameters, ring hit test and the trackball drag that turns the press pose about one axis.
- `OSCViewerControl+Anchor.m` owns the anchor square: its glyph, hit test and the pixel-delta that moves the pivot.
- `OSCCursor.m` resolves FCP's cursor art from the package resource bundle, falling back to private AppKit cursors, then public ones, when the art is missing.
- `OSCPlayheadMotion.c` infers whether the playhead is moving from the time each draw tick carries, since the host exposes no transport state to a control.

The input and drag paths keep their own diagnostics, off unless `/tmp/keyframeless-osc-log` exists; the file is re-checked every couple of seconds, so it can be armed against a running host. An environment variable cannot serve here, because the host spawns the control as a launchd XPC service that inherits nothing from the shell or the application.

While the playhead moves the elements are not appended, so the clear pass in `RSOSCDraw` is the whole draw: controls that strobe over footage during playback or a scrub are worth less than a clean viewer, and those ticks also skip every saved-visibility read. Hit testing and the saved visibility parameters are untouched, so a control that is momentarily unpainted still responds.

A control cannot invalidate itself: `FxOnScreenControlAPI` has no such call, and the host issues no draw tick once the playhead parks, so anything that hides has to arrange its own way back. Inside the package the only invalidation available is the `forceUpdate` flag the input callbacks carry, so `mouseMoved:`, `mouseEntered:` and `keyUp:` reset the inference and set it, while `hitTest:` resets without it, having no such flag. Each forces a redraw only when something was actually hidden, so hover ticks cost what they always did. Recovery with no input at all belongs to the plugin, which can write a parameter and make the host re-render; `MMOSCPlayheadNudge` in Magic Move is the reference. `OSCPlayheadMotionUpdate` is public so that watcher runs the same fold, and both processes agree on what counts as a moving playhead. A live drag is exempt throughout, since the pointer owns the control whatever the playhead does, and only a time that moves at least `OSCPlayheadStepSeconds` counts as an advance, so a parked playhead redrawn on neighbouring rational times is still parked rather than latching "moving" for good.

A plugin subclasses `OSCViewerControl` and supplies four things: the pose read (`boxPoseAtTime:pose:`), the saved visibility parameter per element (`visibilityParameterForElement:`), the lane writes (`writePose:kind:modifiers:atTime:`), and the editing caches that `beginDragOfKind:atTime:`/`endDrag` capture and release. Ring colours default to white; a plugin with a per-lane palette overrides `ringColors`.

The package links AppKit and imports the FxPlug SDK headers from `/Library/Developer/SDKs/FxPlug.sdk`, but never links FxPlug itself; the plugin target carries the framework.

## Tests

```sh
OSCViewer/Tests/run.sh
```

Checks the playhead-motion inference (stopped, advancing, stalls inside and outside the window, backwards jumps and unusable input) plus the cursor handle/angle mappings and the packaged-art lookup, without and with the SwiftPM resource bundle laid out as Xcode ships it. The control's interaction behaviour is covered through the MagicMove plugin test suites, which drive a subclass against a mock host; hiding during playback is a host check, listed in the plugin's test guide.
