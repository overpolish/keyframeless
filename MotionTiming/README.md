# MotionTiming

A C library for keyframe timing and Added Motion. It has no dependency on Foundation, FxPlug, or UI code.

Each destination contains an arrival time, an incoming duration, an easing type, and a vector of values. The values move together. The evaluator holds the previous value until the transition begins, so a hold does not need an extra keyframe. Easing options are Smooth (smoothstep), Linear, Ease In (quadratic), and Ease Out (quadratic).

The caller supplies times in seconds and can sample in any order. The same inputs always produce the same result. Saving values, handling undo, and converting host time are the caller's responsibility. See [MotionTiming.h](Sources/MotionTiming/include/MotionTiming.h) for input requirements and behavior at keyframe boundaries.

## Build and test

From the repository root:

```sh
swift build --package-path MotionTiming
MotionTiming/Tests/run.sh
```

Tests run with AddressSanitizer and UndefinedBehaviorSanitizer. MagicMove links the library as a static Swift package.
