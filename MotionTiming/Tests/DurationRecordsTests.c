/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "MotionTiming.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#pragma clang diagnostic ignored "-Wmissing-field-initializers"
#include <stdint.h>
#include <string.h>

static void expectDurations(const MTDurationRecord *records, size_t count,
                            const double *durations) {
    for (size_t i = 0; i < count; ++i) assert(records[i].duration == durations[i]);
}

static void expectAssociations(const MTDurationRecord *records, size_t count,
                               const uint64_t *linkIDs,
                               const size_t *previousIndices) {
    for (size_t i = 0; i < count; ++i) {
        assert(records[i].linkID == linkIDs[i]);
        assert(records[i].previousIndex == previousIndices[i]);
    }
}

static void testGeneratedCorrespondenceInvariants(void) {
    enum { Count = 12 };
    MTDurationRecord previous[Count], current[Count], output[Count];
    for (size_t i = 0; i < Count; ++i) {
        previous[i] = (MTDurationRecord){(double)i * 2, (double)(100 + i),
                                        (double)i / 3, (i % 2) != 0,
                                        (uint64_t)(1000 + i), 999, false, MTEasingSmooth};
        previous[i].easing = (MTEasing)(i % 4);
        current[i] = (MTDurationRecord){(double)i * 2 + 0.5, (double)(200 + i),
                                        99, true, 9999, 9999, false, MTEasingSmooth};
    }
    assert(MTReconcileDurations(previous, Count, current, Count, 7, output));
    for (size_t i = 0; i < Count; ++i) {
        assert(output[i].duration == previous[i].duration);
        assert(output[i].easing == previous[i].easing);
        assert(output[i].useAvailableTime == previous[i].useAvailableTime);
        assert(output[i].linkID == previous[i].linkID);
        assert(output[i].previousIndex == i);
    }
}

static void testInvalidInputsPreserveOutput(void) {
    MTDurationRecord previous[] = {{0, 1, 2, false, 11, 0, false, MTEasingSmooth}};
    MTDurationRecord current[] = {{1, 2, 3, true, 22, 1, false, MTEasingSmooth}};
    MTDurationRecord output[] = {{8, 9, 10, true, 33, 44, false, MTEasingSmooth}};
    MTDurationRecord expected = output[0];
    assert(!MTReconcileDurations(previous, 1, current, 1, NAN, output));
    assert(memcmp(output, &expected, sizeof(expected)) == 0);
    assert(!MTReconcileDurations(previous, 1, current, 1, INFINITY, output));
    assert(memcmp(output, &expected, sizeof(expected)) == 0);
    assert(!MTReconcileDurations(previous, 1, current, 1, 1, NULL));
    assert(memcmp(output, &expected, sizeof(expected)) == 0);
    MTDurationRecord invalid = previous[0]; invalid.duration = NAN;
    assert(!MTReconcileDurations(&invalid, 1, current, 1, 1, output));
    assert(memcmp(output, &expected, sizeof(expected)) == 0);
    invalid = previous[0]; invalid.duration = INFINITY;
    assert(!MTReconcileDurations(&invalid, 1, current, 1, 1, output));
    assert(memcmp(output, &expected, sizeof(expected)) == 0);
    invalid = previous[0]; invalid.time = INFINITY;
    assert(!MTReconcileDurations(&invalid, 1, current, 1, 1, output));
    assert(memcmp(output, &expected, sizeof(expected)) == 0);
    MTDurationRecord unordered[] = {{0, 1, 2, false, 11, 0, false, MTEasingSmooth}, {0, 2, 3, false, 12, 0, false, MTEasingSmooth}};
    assert(!MTReconcileDurations(unordered, 2, current, 1, 1, output));
    assert(memcmp(output, &expected, sizeof(expected)) == 0);
}

static void testUniqueCrossingAndExactTimePriority(void) {
    MTDurationRecord previous[] = {
        {.time=0, .value=10, .duration=1, .linkID=101},
        {.time=2, .value=20, .duration=2, .linkID=202},
        {.time=4, .value=30, .duration=3, .useAvailableTime=true, .linkID=303}
    };
    MTDurationRecord crossed[] = {
        {.time=0, .value=10}, {.time=1, .value=30}, {.time=2, .value=20}
    }, out[3];
    assert(MTReconcileDurations(previous, 3, crossed, 3, 1.2, out));
    assert(out[1].linkID==303 && out[1].previousIndex==2 && out[1].duration==3 && out[1].useAvailableTime);
    assert(out[2].linkID==202 && out[2].previousIndex==1 && out[2].duration==2);
    // Swapping values on unchanged times is a value edit: time wins over value.
    MTDurationRecord edited[] = {
        {.time=0, .value=30}, {.time=2, .value=20}, {.time=4, .value=10}
    };
    assert(MTReconcileDurations(previous, 3, edited, 3, 1.2, out));
    assert(out[0].linkID==101 && out[2].linkID==303);
    assert(MTReconcileDurations(previous, 3, NULL, 0, 1.2, NULL));
}

static void testMatchEndpointsPersistAcrossReconciliation(void) {
    MTDurationRecord previous[] = {
        {.time=0, .value=10, .duration=1, .matchEndpoints=true},
        {.time=2, .value=20, .duration=2, .matchEndpoints=true},
        {.time=4, .value=30, .duration=3, .matchEndpoints=true}
    };
    MTDurationRecord inserted[] = {
        {.time=0, .value=10}, {.time=1, .value=15},
        {.time=2, .value=20}, {.time=4, .value=30}
    };
    MTDurationRecord output[4], reduced[2];
    assert(MTReconcileDurations(previous, 3, inserted, 4, 9, output));
    for (size_t i = 0; i < 4; ++i) assert(output[i].matchEndpoints);

    MTDurationRecord deleted[] = {
        {.time=0, .value=10}, {.time=2, .value=20}
    };
    assert(MTReconcileDurations(output, 4, deleted, 2, 9, reduced));
    for (size_t i = 0; i < 2; ++i) assert(reduced[i].matchEndpoints);
}

int main(void) {
    testUniqueCrossingAndExactTimePriority();
    testGeneratedCorrespondenceInvariants();
    testInvalidInputsPreserveOutput();
    testMatchEndpointsPersistAcrossReconciliation();
    MTDurationRecord previous[] = {
        {0, 10, 1, false, 101, 77, true, MTEasingSmooth},
        {2, 20, 2, false, 202, 77, true, MTEasingSmooth},
        {4, 30, 3, false, 303, 77, true, MTEasingSmooth}
    };
    MTDurationRecord current[4];
    double expected[] = {1, 2, 3, 9};
    previous[1].useAvailableTime = true;

    // Moving a key while preserving its distinct value retains its duration.
    MTDurationRecord retime[] = {
        {-1, 10, 0, false, 0, 0, false, MTEasingSmooth}, {3, 20, 0, false, 0, 0, false, MTEasingSmooth},
        {5, 30, 0, false, 0, 0, false, MTEasingSmooth}
    };
    assert(MTReconcileDurations(previous, 3, retime, 3, 9, current));
    expectDurations(current, 3, expected);
    assert(current[1].useAvailableTime && !current[0].useAvailableTime);
    const uint64_t retimeLinks[] = {101, 202, 303};
    const size_t retimeIndices[] = {0, 1, 2};
    expectAssociations(current, 3, retimeLinks, retimeIndices);

    // A same-time value edit is paired chronologically after exact matches.
    MTDurationRecord edit[] = {
        {0, 10, 0, false, 0, 0, false, MTEasingSmooth}, {2, 25, 0, false, 0, 0, false, MTEasingSmooth},
        {4, 30, 0, false, 0, 0, false, MTEasingSmooth}
    };
    double editExpected[] = {1, 2, 3};
    assert(MTReconcileDurations(previous, 3, edit, 3, 9, current));
    expectDurations(current, 3, editExpected);
    const uint64_t editLinks[] = {101, 202, 303};
    const size_t editIndices[] = {0, 1, 2};
    expectAssociations(current, 3, editLinks, editIndices);

    // Same-value multi-select moves pair in chronological order after exact matches.
    MTDurationRecord sameValuePrevious[] = {
        {0, 10, 1, false, 401, 0, false, MTEasingSmooth}, {2, 10, 2, true, 402, 0, false, MTEasingSmooth},
        {4, 20, 3, false, 403, 0, false, MTEasingSmooth}
    };
    MTDurationRecord sameValueCurrent[] = {
        {1, 10, 0, false, 0, 0, false, MTEasingSmooth}, {3, 10, 0, false, 0, 0, false, MTEasingSmooth},
        {4, 20, 0, false, 0, 0, false, MTEasingSmooth}
    };
    assert(MTReconcileDurations(sameValuePrevious, 3, sameValueCurrent, 3, 9, current));
    const uint64_t sameValueLinks[] = {401, 402, 403};
    const size_t sameValueIndices[] = {0, 1, 2};
    expectAssociations(current, 3, sameValueLinks, sameValueIndices);
    assert(current[1].useAvailableTime);

    // Insertions/deletions preserve unique value identities and default new keys.
    MTDurationRecord inserted[] = {
        {0, 10, 0, false, 0, 0, false, MTEasingSmooth}, {1, 15, 0, false, 0, 0, false, MTEasingSmooth},
        {2, 20, 0, false, 0, 0, false, MTEasingSmooth}, {4, 30, 0, false, 0, 0, false, MTEasingSmooth}
    };
    double insertionExpected[] = {1, 9, 2, 3};
    assert(MTReconcileDurations(previous, 3, inserted, 4, 9, current));
    expectDurations(current, 4, insertionExpected);
    assert(current[2].useAvailableTime && !current[1].useAvailableTime);
    const uint64_t insertionLinks[] = {101, 0, 202, 303};
    const size_t insertionIndices[] = {0, SIZE_MAX, 1, 2};
    expectAssociations(current, 4, insertionLinks, insertionIndices);
    MTDurationRecord deleted[] = {
        {0, 10, 0, false, 0, 0, false, MTEasingSmooth}, {4, 30, 0, false, 0, 0, false, MTEasingSmooth}
    };
    double deletionExpected[] = {1, 3};
    assert(MTReconcileDurations(previous, 3, deleted, 2, 9, current));
    expectDurations(current, 2, deletionExpected);
    const uint64_t deletionLinks[] = {101, 303};
    const size_t deletionIndices[] = {0, 2};
    expectAssociations(current, 2, deletionLinks, deletionIndices);

    // Crossing distinct values with no time collision uses chronological pairing.
    MTDurationRecord crossed[] = {
        {1, 35, 0, false, 0, 0, false, MTEasingSmooth}, {3, 5, 0, false, 0, 0, false, MTEasingSmooth},
        {5, 25, 0, false, 0, 0, false, MTEasingSmooth}
    };
    double crossedExpected[] = {1, 2, 3};
    assert(MTReconcileDurations(previous, 3, crossed, 3, 9, current));
    expectDurations(current, 3, crossedExpected);
    const uint64_t crossedLinks[] = {101, 202, 303};
    const size_t crossedIndices[] = {0, 1, 2};
    expectAssociations(current, 3, crossedLinks, crossedIndices);

    MTDurationRecord untouched[] = {{7, 70, 42, false, 0, 0, false, MTEasingSmooth}};
    MTDurationRecord invalid[] = {{0, 1, 4, false, 0, 0, false, MTEasingSmooth}, {0, 2, 5, false, 0, 0, false, MTEasingSmooth}};
    assert(!MTReconcileDurations(invalid, 2, untouched, 1, 9, current));
    assert(current[0].duration == 1 && current[1].duration == 2 &&
           current[2].duration == 3);
    invalid[1].time = NAN;
    assert(!MTReconcileDurations(previous, 3, invalid, 2, 9, current));
    assert(MTReconcileDurations(NULL, 0, NULL, 0, 0, NULL));
    assert(!MTReconcileDurations(NULL, 1, NULL, 0, 0, NULL));
    assert(!MTReconcileDurations(previous, 3, untouched, 1, NAN, current));

    // New records clear stale link IDs and transient associations.
    MTDurationRecord newRecord[] = {{6, 60, 0, true, 999, 999, false, MTEasingSmooth}};
    assert(MTReconcileDurations(previous, 3, newRecord, 1, 9, current));
    assert(current[0].linkID == 0 && current[0].previousIndex == SIZE_MAX);
    assert(!current[0].useAvailableTime && current[0].duration == 9);

    puts("DurationRecords: all tests passed");
}
