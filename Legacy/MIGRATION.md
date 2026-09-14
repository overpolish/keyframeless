# v1 relocation

The v1 tree moved under `Legacy/` on 2026-09-14. Its project, asset, service, submodule, release, and documentation layout is preserved relative to this directory. Open `Keyframeless.xcworkspace` here for v1.

The repository root contains the current MagicMove plugin, MotionTiming, InspectorControls, their tooling, and the icon used by MagicMove. A subsequent checkpoint removed MagicMove’s KeyframelessKit dependency. Current builds use only root packages; the verification below records the earlier relocation checkpoint.

## Verification

- Fresh Debug MagicMove build from the root workspace: passed (`DerivedData/V2Migration`).
- Full MagicMove regression suite using that runtime, including independent libraries, plugin integration, shader and motion-blur GPU tests: passed.
- Strict deep code-signature verification of MagicMove.app: passed.
- Legacy workspace dependency resolution: passed; existing pinned revisions preserved.
- Fresh Debug Mirage wrapper build from this workspace: passed (`DerivedData/LegacyMigration` at repository root).
- Mirage rack-model tests from the relocated tree: passed.
- All three submodule worktrees resolve under `Legacy/ThirdParty`.

The fresh MagicMove extension was registered for host testing. Interactive Motion/FCP behavior has not been reverified after the relocation. Other v1 products and release/notarization pipelines were not run.
