# Keyframeless

Motion graphics plugins for Final Cut Pro and Motion, with native keyframes and simple controls for timing and movement.

## Components

- [Magic Move](MagicMove/README.md): animate position, scale, rotation, opacity, blur, and anchor with incoming transition timing and Added Motion.
- [MotionTiming](MotionTiming/README.md): keyframe timing and Added Motion.
- [InspectorControls](InspectorControls/README.md): reusable AppKit inspector controls.
- [PluginPreferences](PluginPreferences/README.md): saved defaults for plugin settings.
- [RenderSupport](RenderSupport/README.md): Metal rendering, spatial blur, motion blur, and on-screen-control drawing.
- [OSCControls](OSCControls/README.md): pure geometry for viewer on-screen controls.
- [OSCViewer](OSCViewer/README.md): the FxPlug side of viewer on-screen controls and FCP cursor art.

## Build and test

Requires macOS, Xcode, and the FxPlug SDK installed under `/Library/Developer/Frameworks`.

Open `Keyframeless.xcworkspace`, select the **MagicMove** scheme, and build. From the repository root:

```sh
xcodebuild -workspace Keyframeless.xcworkspace -scheme MagicMove \
  -configuration Debug -derivedDataPath DerivedData/Keyframeless build
scripts/test-magicmove.sh
```

See the [test guide](MagicMove/Tests/README.md) for individual suites, alternate build directories, and host checks. After building, `scripts/gen-clangd.sh` configures source indexing for the plugin and shared packages.

## Contributing and licensing

See [Contributing](CONTRIBUTING.md) for code organisation and testing guidance.

Source is provided under the [PolyForm Noncommercial license](LICENSE). See the [commercial license](COMMERCIAL-LICENSE.md) and [third-party notices](THIRD-PARTY-NOTICES.md) for additional terms and attribution.
