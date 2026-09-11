#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
binary=$(mktemp -t motion-timing-tests)
trap 'rm -f "$binary"' EXIT
xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$root/Sources/MotionTiming/include" \
    "$root/Sources/MotionTiming/MotionTiming.c" "$root/Tests/TimingTests.c" \
    -o "$binary"
"$binary"
duration_binary=$(mktemp -t motion-duration-tests)
trap 'rm -f "$binary" "$duration_binary"' EXIT
xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$root/Sources/MotionTiming/include" \
    "$root/Sources/MotionTiming/MTDurationRecords.c" "$root/Tests/DurationRecordsTests.c" \
    -o "$duration_binary"
"$duration_binary"
