# OSCViewer

The FxPlug side of viewer on-screen controls, shared by plugins that show a transformed image with handles. It depends on `OSCControls` for the pure geometry and `RenderSupport` for drawing, and carries FCP's cursor art.

- `OSCViewerControl.m` implements `FxOnScreenControl_v4`: canvas geometry from the host, the four-element draw (box outline, scale handles, rotation rings, anchor square), hit precedence (anchor, handles, rings, position drag), cursor arbitration, and the per-tick undo group. It does not read keyframes or write lanes.
- `OSCViewerControl+Rotation.m` owns the rotation gizmo: ring drawing parameters, ring hit test and the trackball drag that turns the press pose about one axis.
- `OSCViewerControl+Anchor.m` owns the anchor square: its glyph, hit test and the pixel-delta that moves the pivot.
- `OSCCursor.m` resolves FCP's cursor art from the package resource bundle, falling back to private AppKit cursors, then public ones, when the art is missing.

A plugin subclasses `OSCViewerControl` and supplies four things: the pose read (`boxPoseAtTime:pose:`), the saved visibility parameter per element (`visibilityParameterForElement:`), the lane writes (`writePose:kind:modifiers:atTime:`), and the editing caches that `beginDragOfKind:atTime:`/`endDrag` capture and release. Ring colours default to white; a plugin with a per-lane palette overrides `ringColors`.

The package links AppKit and imports the FxPlug SDK headers from `/Library/Developer/SDKs/FxPlug.sdk`, but never links FxPlug itself; the plugin target carries the framework.

## Tests

```sh
OSCViewer/Tests/run.sh
```

Checks the cursor handle/angle mappings and the packaged-art lookup, without and with the SwiftPM resource bundle laid out as Xcode ships it. The control's interaction behaviour is covered through the MagicMove plugin test suites, which drive a subclass against a mock host.
