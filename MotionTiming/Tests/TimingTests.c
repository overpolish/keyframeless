/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "MotionTiming.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wmissing-field-initializers"

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
    double values[6][4]; MTDestination d[6]; memset(d, 0, sizeof(d));
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

static void testAddedMotion(void) {
    double a[] = {0.0, 0.0}, b[] = {100.0, 0.0}, c[] = {200.0, 50.0};
    double mins[] = {-100.0, -100.0}, maxs[] = {100.0, 100.0};
    MTDestination d[] = {
        {0, 1, a, MTEasingSmooth, MTAddedMotionWave, mins, maxs, 2},
        {4, 1, b, MTEasingSmooth, MTAddedMotionNone, mins, maxs, 2},
        {8, 1, c, MTEasingSmooth, MTAddedMotionNone, mins, maxs, 2}
    };
    double out[2];
    // The outgoing owner modulates the entire interval, including its hold.
    assert(MTSample(d, 3, 2, 0, out) && out[0] == 0 && out[1] == 0);
    assert(MTSample(d, 3, 2, 1.25, out));
    assert(fabs(out[0]) > 1e-6); // wave is visible during the hold
    // The next pose remains exact, and a None interval preserves ordinary timing.
    assert(MTSample(d, 3, 2, 4, out) && out[0] == 100 && out[1] == 0);
    assert(MTSample(d, 3, 2, 7.5, out) && fabs(out[0] - 150.0) < 1e-9);
    // Every built-in effect is finite and lands exactly on the keypose.
    for (int motion = MTAddedMotionWave; motion <= MTAddedMotionHandheld; ++motion) {
        d[0].addedMotion = (MTAddedMotion)motion;
        for (int i = 0; i <= 20; ++i) {
            assert(MTSample(d, 3, 2, i * 0.2, out));
            assert(isfinite(out[0]) && isfinite(out[1]));
        }
        assert(MTSample(d, 3, 2, 4, out) && out[0] == 100 && out[1] == 0);
        double forward[2], backward[2];
        assert(MTSample(d, 3, 2, 1.25, forward));
        assert(MTSample(d, 3, 2, 3.25, backward));
        assert(MTSample(d, 3, 2, 1.25, out));
        assertVector(out, forward, 2);
        assert(MTSample(d, 3, 2, 3.25, out));
        assertVector(out, backward, 2);
    }
    d[0].addedMotion = (MTAddedMotion)99; out[0] = 7;
    assert(!MTSample(d, 3, 2, 1, out) && out[0] == 7);
}

static void testCustomMotionControls(void) {
    double a[] = {0.0}, b[] = {100.0}, c[] = {200.0}, out[1], baseline[1];
    MTDestination plain[] = {
        {0, 0, a, MTEasingSmooth}, {4, 1, b, MTEasingSmooth}, {8, 1, c, MTEasingSmooth}
    };
    MTDestination amountZero[] = {
        {0, 0, a, MTEasingSmooth, MTAddedMotionWave, NULL, NULL, 0, true, 0.0, 1.0},
        {4, 1, b, MTEasingSmooth}, {8, 1, c, MTEasingSmooth}
    };
    for (int i = 0; i <= 16; ++i) {
        double t = i * 0.5;
        assert(MTSample(plain, 3, 1, t, baseline));
        assert(MTSample(amountZero, 3, 1, t, out));
        assert(out[0] == baseline[0]);
    }

    MTDestination custom[] = {
        {0, 0, a, MTEasingSmooth, MTAddedMotionWave, NULL, NULL, 0, true, 1.0, 1.0},
        {4, 1, b, MTEasingSmooth}, {8, 1, c, MTEasingSmooth}
    };
    assert(MTSample(custom, 3, 1, 3.5, out));
    double defaultValue = out[0];
    custom[0].motionAmount = 2.0;
    assert(MTSample(custom, 3, 1, 3.5, out));
    assert(fabs(out[0] - defaultValue) > 1.0e-6);
    custom[0].motionAmount = 1.0;
    custom[0].motionSpeed = 2.0;
    assert(MTSample(custom, 3, 1, 3.5, out));
    assert(fabs(out[0] - defaultValue) > 1.0e-6);

    // Controls are validated only when opted in, and failures leave output untouched.
    custom[0].motionAmount = NAN; out[0] = 73.0;
    assert(!MTSample(custom, 3, 1, 3.5, out) && out[0] == 73.0);
    custom[0].motionAmount = -1.0;
    assert(!MTSample(custom, 3, 1, 3.5, out) && out[0] == 73.0);
    custom[0].motionAmount = 1.0; custom[0].motionSpeed = 0.0;
    assert(!MTSample(custom, 3, 1, 3.5, out) && out[0] == 73.0);
    custom[0].motionSpeed = INFINITY;
    assert(!MTSample(custom, 3, 1, 3.5, out) && out[0] == 73.0);

    // Different outgoing controls retain exact keys and a smooth join.
    custom[0].motionAmount = 0.7; custom[0].motionSpeed = 0.8;
    custom[0].addedMotion = MTAddedMotionWave;
    custom[1].customMotion = true; custom[1].motionAmount = 1.8; custom[1].motionSpeed = 1.6;
    custom[1].addedMotion = MTAddedMotionWiggle;
    assert(MTSample(custom, 3, 1, 4.0, out) && out[0] == 100.0);
    double left[1], right[1];
    assert(MTSample(custom, 3, 1, 4.0 - 1.0e-4, left));
    assert(MTSample(custom, 3, 1, 4.0 + 1.0e-4, right));
    assert(fabs(left[0] - right[0]) < 0.1);
}

int main(void) {
    testEasingTypes();
    testEndpointsAndHolds(); testIncomingDurationAndSmoothstep();
    testZeroDurationAndGapClamping(); testMultiComponentAndStatelessSampling();
    testDeterministicGeneratedInvariants(); testInvalidInputsLeaveOutputUntouched();
    testAddedMotion();
    testCustomMotionControls();
    puts("MotionTiming: all tests passed");
}
