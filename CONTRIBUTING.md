# Contributing

## Where code belongs

- `MagicMove/` owns FxPlug integration, parameter registration, persistence, undo, and the plugin inspector.
- `MotionTiming/` owns deterministic timing and Added Motion evaluation, independent of host APIs and UI.
- `InspectorControls/` owns reusable AppKit layout and interaction. Plugins supply values, actions, and host-specific behavior.
- `RenderSupport/` owns reusable Metal resources and rendering operations. Image tiles and host parameter access remain in plugin adapters.

Shared packages should build on their own. Keep plugin-specific code in the plugin. See [MagicMove architecture](MagicMove/Architecture.md) for how the parts fit together and the host behavior they need to preserve.

## Testing changes

Follow the [build instructions](README.md#build-and-test) and run the relevant [test suites](MagicMove/Tests/README.md). Add regression tests when changing behavior. Changes to parameter identifiers or saved values must still allow existing documents to open correctly.

For changes involving Motion/FCP lifecycle, interaction, or rendering, also test in the host application. In the pull request, say what you tested, which application versions you used, and what still needs checking.

Use the repository's conventional commit style, for example `fix(MagicMove): ...` or `feat(InspectorControls): ...`.
