# MotionTiming

A small shared timing library for focused plugins. Its only current consumer is
Magic Move. It has no dependency on Mirage's keyposes, custom
UI, Foundation, or FxPlug.

Each destination contains an arrival time, an incoming transition duration,
and a vector of values. Values share timing by construction. The evaluator
holds the previous destination until the transition begins; users need no
extra pose to mark the end of a hold.

Times are seconds supplied by the caller. Sampling is deterministic and supports
arbitrary frame order. The host adapter owns persistence, undo, and conversion
from host time. See `Sources/MotionTiming/include/MotionTiming.h` for validation
and boundary rules.

Build independently with `swift build --package-path MotionTiming` from the
repository root. Run `MotionTiming/Tests/run.sh` for timing tests under address
and undefined-behaviour sanitizers. The static SwiftPM product is also linked
by the MagicMove Xcode project.

This is an initial evaluator, not a replacement for Mirage's full motion engine.
More behaviours should follow user-tested checkpoints, without importing the
old timeline or inspector model into this library.
