# Architecture

- Keep each plugin and shared package focused on its stated job.
- Plugins own their parameter identifiers, lane definitions, render, on-screen controls, and preference storage, and register everything the shared packages read back from them.
- `PluginHost` owns the FxPlug effect base class, host actions and ticks, the inspector refresh clock, hidden bool settings, the property-menu lifecycle, keyboard shortcut routing, and the render-host adapter. Keep it free of keyframed-property knowledge and plugin parameter identifiers.
- `PoseLanes` owns the keyframed-property model: the pose class and its timing, lanes and their caches, native keyframe editing, links, Match In/Out, creation defaults, the timing editor, and the inspector rows. It depends on PluginHost and knows a plugin only through the lane table it registers.
- `MotionTiming` owns deterministic timing and Added Motion evaluation. Keep it independent of plugin UI, Foundation, and host APIs.
- `InspectorControls` owns reusable AppKit controls, layout, and tokens. Reuse its rows and value fields for inspector UI. Keep it free of FxPlug, plugin parameter IDs, timing, and persistence.
- `PluginPreferences` owns reusable preference storage and validation hooks. Plugins define defaults and when to apply them; keep document values and host writes out of the package.
- `RenderSupport` owns reusable Metal resources and rendering operations. Keep it free of FxPlug, plugin parameter IDs, and timing-engine dependencies.
- MagicMove is unreleased and carries no saved-document compatibility requirement: parameter identifiers and encoded values may change. Every value is a keyframed custom parameter.

# Implementation and verification

- Before implementing a control, layout, or interaction, inspect the plugin and shared packages for an equivalent. Reuse working behavior and host-specific details instead of guessing from appearance.
- Add meaningful automated tests alongside implementation. Cover shared-package behavior and plugin integration, including relevant persistence, undo, lifecycle, and failure cases. Prefer observable behavior over tests that mirror implementation details.
- Test shared packages independently as well as through plugin integration. Run checks appropriate to each change.
- For behavior that depends on Motion or FCP, specify what to check in the host and record the results. Automated mocks cannot verify host behavior.
- When changing build paths or dependencies, verify with fresh derived data and set `MM_DERIVED_DATA` to that directory for plugin tests.

# Workspace and archive

- Use the root `Keyframeless.xcworkspace` for plugin development. Keep shared assets in `Assets/` and repository tooling in `scripts/`.
- `Legacy/` contains archived projects, libraries, assets, services, tooling, and documentation. Its workspace and scripts apply to the archived projects only.
- Plugins and shared packages must build and test without `Legacy/`. Do not add build or runtime dependencies on archived libraries.
- Consult archived implementations for proven algorithms, interactions, and performance characteristics. When porting code, preserve its licensing and attribution and adapt it to the package that will use it.

# Documentation and comments

- Write README and CONTRIBUTING for human contributors. Keep them self-contained; do not direct readers to AGENTS.md or frame the repository around agent workflows. AGENTS.md is guidance for agents only.
- Describe the project and its architecture directly. Avoid version-era labels, migration narratives, and implementation diaries in general documentation. Keep necessary compatibility details with the relevant code or architecture documentation.
- Use plain, direct language. Avoid filler, promotional wording, and habitual em dashes; use ordinary sentences and punctuation. Keep each prose paragraph on one source line; do not hard-wrap it. Preserve useful formatting in code blocks, tables, and lists.
- Comments should explain why the code is needed, including constraints, tradeoffs, and non-obvious behavior. Remove comments that merely repeat names, assignments, or control flow. Keep public API contracts, units, compatibility notes, host workarounds, and licensing or attribution.
- Describe the current behavior in comments. Keep implementation history and progress reports out of the source unless they explain a constraint that still applies.
