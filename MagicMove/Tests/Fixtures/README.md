# Compatibility fixtures

These files were captured from KeyframelessKit on 2026-09-14:

- `LegacyTimingBlob.archive`: a secure archive of `KKDataBlob` with UTF-8 contents `[{"time":2,"duration":0.3}]`. Verifies that the plugin-owned compatibility class can read existing saved values.
- `AddedMotionGolden.h`: outputs of `KKApplyHoldEffectForComponent` for Wave/Wiggle/Handheld at 39 evenly spaced samples and two axes, plus 100 outputs from `KKHermiteJoinBlend` across the established join window. The scenarios are exercised in `AddedMotionTests.m`.

The tests compare against these saved results without loading KeyframelessKit. Do not regenerate the expected results from the code being tested.
