/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "MotionTiming.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static void assertVector(const double *actual, const double *expected, size_t count) {
    for (size_t i = 0; i < count; ++i) assert(fabs(actual[i] - expected[i]) < 1e-9);
}

static void testEndpointsAndHolds(void) {
    double first[] = {0, 50}, second[] = {100, 100}, third[] = {200, 150};
    MTDestination d[] = {{0, 0, first, MTEasingSmooth}, {4, 1.2, second, MTEasingSmooth}, {8, 1, third, MTEasingSmooth}};
    double out[2];
    assert(MTSample(d, 3, 2, -1, out)); assertVector(out, first, 2);
    assert(MTSample(d, 3, 2, 2.8, out)); assertVector(out, first, 2);
    assert(MTSample(d, 3, 2, 4, out)); assertVector(out, second, 2);
    assert(MTSample(d, 3, 2, 7, out)); assertVector(out, second, 2);
    assert(MTSample(d, 3, 2, 8, out)); assertVector(out, third, 2);
    assert(MTSample(d, 3, 2, 20, out)); assertVector(out, third, 2);
}

static void testIncomingDurationAndSmoothstep(void) {
    double a[] = {0}, b[] = {100};
    MTDestination d[] = {{0, 99, a, MTEasingSmooth}, {10, 4, b, MTEasingSmooth}};
    double out[1];
    // The destination owns the incoming transition duration; the first duration is ignored.
    assert(MTSample(d, 2, 1, 5, out) && out[0] == 0);
    assert(MTSample(d, 2, 1, 8, out) && fabs(out[0] - 50) < 1e-9);
    // At non-midpoint t=.25, smoothstep progress is .15625.
    assert(MTSample(d, 2, 1, 7, out) && fabs(out[0] - 15.625) < 1e-9);
    assert(MTSample(d, 2, 1, 10, out) && out[0] == 100);
}

static void testZeroDurationAndGapClamping(void) {
    double a[] = {0}, b[] = {100}, c[] = {200};
    MTDestination zero[] = {{0, 7, a, MTEasingSmooth}, {5, 0, b, MTEasingSmooth}};
    MTDestination longDuration[] = {{0, 7, a, MTEasingSmooth}, {5, 20, b, MTEasingSmooth}, {10, 1, c, MTEasingSmooth}};
    double out[1];
    assert(MTSample(zero, 2, 1, 4.999999, out) && out[0] == 0);
    assert(MTSample(zero, 2, 1, 5, out) && out[0] == 100);
    // A duration longer than the available gap is capped to the gap.
    assert(MTSample(longDuration, 3, 1, 2.5, out) && fabs(out[0] - 50) < 1e-9);
    assert(MTSample(longDuration, 3, 1, 0, out) && out[0] == 0);
    assert(MTSample(longDuration, 3, 1, 5, out) && out[0] == 100);
}

static void testMultiComponentAndStatelessSampling(void) {
    double a[] = {0, 10, 100}, b[] = {100, 20, 200}, c[] = {200, 30, 300};
    MTDestination d[] = {{0, 2, a, MTEasingSmooth}, {4, 2, b, MTEasingSmooth}, {8, 2, c, MTEasingSmooth}};
    double expected[] = {50, 15, 150}, out[3], repeat[3];
    assert(MTSample(d, 3, 3, 3, out)); assertVector(out, expected, 3);
    // Sampling is independent of call history and direction.
    assert(MTSample(d, 3, 3, 7, repeat));
    assert(MTSample(d, 3, 3, 3, out)); assertVector(out, expected, 3);
    assert(MTSample(d, 3, 3, -2, out)); assertVector(out, a, 3);
    assert(MTSample(d, 3, 3, 100, out)); assertVector(out, c, 3);
}

static void testDeterministicGeneratedInvariants(void) {
    double values[6][4]; MTDestination d[6];
    for (size_t i = 0; i < 6; ++i) {
        d[i].arrival = (double)i * 3; d[i].duration = 1.5 + (double)(i % 3);
        for (size_t c = 0; c < 4; ++c) values[i][c] = (double)(i * 100 + c * 7);
        d[i].values = values[i]; d[i].easing = MTEasingSmooth;
    }
    for (size_t sample = 0; sample <= 60; ++sample) {
        double out[4]; assert(MTSample(d, 6, 4, (double)sample / 2, out));
        for (size_t c = 0; c < 4; ++c) {
            assert(isfinite(out[c]));
            assert(out[c] >= values[0][c] && out[c] <= values[5][c]);
        }
    }
}

static void testInvalidInputsLeaveOutputUntouched(void) {
    double a[] = {1}, b[] = {2}, out[] = {42};
    MTDestination valid[] = {{0, 1, a, MTEasingSmooth}, {2, 1, b, MTEasingSmooth}}, invalid;
    assert(!MTSample(NULL, 0, 1, 0, out) && out[0] == 42);
    assert(!MTSample(valid, 2, 0, 0, out) && out[0] == 42);
    assert(!MTSample(valid, 2, 1, NAN, out) && out[0] == 42);
    assert(!MTSample(valid, 2, 1, INFINITY, out) && out[0] == 42);
    assert(!MTSample(valid, 2, 1, 0, NULL));
    invalid = valid[0]; invalid.values = NULL;
    assert(!MTSample(&invalid, 1, 1, 0, out) && out[0] == 42);
    invalid = valid[0]; invalid.arrival = NAN;
    assert(!MTSample(&invalid, 1, 1, 0, out) && out[0] == 42);
    invalid = valid[0]; invalid.arrival = INFINITY;
    assert(!MTSample(&invalid, 1, 1, 0, out) && out[0] == 42);
    invalid = valid[0]; invalid.duration = NAN;
    assert(!MTSample(&invalid, 1, 1, 0, out) && out[0] == 42);
    invalid = valid[0]; invalid.duration = INFINITY;
    assert(!MTSample(&invalid, 1, 1, 0, out) && out[0] == 42);
    double nanValue[] = {NAN}; invalid = valid[0]; invalid.values = nanValue;
    assert(!MTSample(&invalid, 1, 1, 0, out) && out[0] == 42);
    invalid = valid[0]; invalid.arrival = -1;
    assert(!MTSample(&invalid, 1, 1, 0, out) && out[0] == 42);
    MTDestination unordered[] = {{0, 1, a, MTEasingSmooth}, {0, 1, b, MTEasingSmooth}};
    assert(!MTSample(unordered, 2, 1, 0, out) && out[0] == 42);
    unordered[1].arrival = -1;
    assert(!MTSample(unordered, 2, 1, 0, out) && out[0] == 42);
}

static void testEasingTypes(void) {
    double a[] = {0,100}, b[] = {100,200}, out[2];
    MTDestination d[] = {{0,0,a,MTEasingEaseOut}, {4,2,b,MTEasingSmooth}};
    double expected[] = {15.625,25,6.25,43.75};
    for (int e=0; e<=3; ++e) {
        d[1].easing = (MTEasing)e;
        assert(MTSample(d,2,2,2.5,out));
        assert(fabs(out[0]-expected[e])<1e-9 && fabs(out[1]-100-expected[e])<1e-9);
        assert(MTSample(d,2,2,1,out) && out[0]==0);
        assert(MTSample(d,2,2,4,out) && out[0]==100);
    }
    d[1].easing = (MTEasing)99; out[0] = 123;
    assert(!MTSample(d,2,2,2.5,out) && out[0]==123);
}

int main(void) {
    testEasingTypes();
    testEndpointsAndHolds(); testIncomingDurationAndSmoothstep();
    testZeroDurationAndGapClamping(); testMultiComponentAndStatelessSampling();
    testDeterministicGeneratedInvariants(); testInvalidInputsLeaveOutputUntouched();
    puts("MotionTiming: all tests passed");
}
