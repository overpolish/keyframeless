/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "MotionTiming.h"
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static double mt_seed_hash(int seed, int index) {
    unsigned v = (unsigned)(seed * 2654435761u + index * 2246822519u);
    v ^= v >> 16; v *= 0x45d9f3b; v ^= v >> 16;
    return (double)(v & 0xFFFF) / 65535.0;
}

// KKEasing hold algorithms, with intensity/frequency controls, seed=0.
// Additional components retain the existing deterministic phase variation.
static double mt_motion_factor(double t, MTAddedMotion motion, size_t component,
                               double amount, double speed) {
    t = fmax(0.0, fmin(1.0, t));
    int seed = 0;
    if (component > 0) {
        seed = (int)((unsigned)component * 0x9E3779B9u);
        if (seed == 0) seed = (int)component + 1;
    }
    double envelope = sin(t * M_PI);
    if (motion == MTAddedMotionWave) {
        double phase = seed ? mt_seed_hash(seed, 0) * M_PI * 2.0 : 0.0;
        return 1.0 + amount * 0.45 * sin(t * M_PI * 12.0 * speed + phase) * envelope;
    }
    if (motion == MTAddedMotionWiggle) {
        double f0=17.0,f1=31.0,f2=59.0,f3=97.0,p0=0,p1=0,p2=0,p3=0;
        if (seed) {
            f0=13.0+mt_seed_hash(seed,0)*10.0; f1=27.0+mt_seed_hash(seed,1)*12.0;
            f2=47.0+mt_seed_hash(seed,2)*24.0; f3=79.0+mt_seed_hash(seed,3)*36.0;
            p0=mt_seed_hash(seed,4)*M_PI*2.0; p1=mt_seed_hash(seed,5)*M_PI*2.0;
            p2=mt_seed_hash(seed,6)*M_PI*2.0; p3=mt_seed_hash(seed,7)*M_PI*2.0;
        }
        double noise = sin(t * f0 * 3.0 * speed + p0) * 0.4 + sin(t * f1 * 3.0 * speed + p1) * 0.3 +
                       sin(t * f2 * 3.0 * speed + p2) * 0.2 + sin(t * f3 * 3.0 * speed + p3) * 0.1;
        return 1.0 + amount * 0.24 * noise * envelope;
    }
    if (motion == MTAddedMotionHandheld) {
        double sum = 0.0, norm = 0.0, amp = 1.0;
        for (int k = 0; k < 5; ++k) {
            double phase = seed ? mt_seed_hash(seed, k) * M_PI * 2.0 : k * 1.2399;
            double detune = 1.0 + 0.03 * (mt_seed_hash(seed, k + 16) - 0.5);
            double cycles = 3.75 * pow(2.0, k) * detune;
            sum += amp * sin(t * 2.0 * M_PI * cycles * speed + phase);
            norm += amp; amp *= 0.5;
        }
        return 1.0 + amount * 0.36 * (sum / norm) * envelope;
    }
    return 1.0;
}

static double mt_modulate(double value, double factor, const MTDestination *d,
                          size_t component) {
    if (fabs(value) >= 1.0e-6) return value * factor;
    if (d->modulationMins && d->modulationMaxs && component < d->modulationRangeCount) {
        double range = d->modulationMaxs[component] - d->modulationMins[component];
        if (range > 0.0) return value + (factor - 1.0) * range * 0.25;
    }
    return value;
}

static bool mt_motion_enabled(const MTDestination *d) {
    return d->addedMotion != MTAddedMotionNone &&
           (!d->customMotion || d->motionAmount > 0.0);
}

static double mt_base_progress(double t, MTEasing easing) {
    switch (easing) {
        case MTEasingLinear: return t;
        case MTEasingEaseIn: return t * t;
        case MTEasingEaseOut: return t * (2.0 - t);
        default: return t * t * (3.0 - 2.0 * t);
    }
}

static double mt_raw_component(const MTDestination *d, size_t count, size_t c, double seconds) {
    size_t next = 0;
    while (next < count && seconds >= d[next].arrival) ++next;
    if (next == 0) return d[0].values[c];
    if (next == count) return d[count - 1].values[c];
    const MTDestination *a = &d[next - 1], *b = &d[next];
    double span = b->arrival - a->arrival;
    double local = fmax(0.0, fmin(1.0, (seconds - a->arrival) / span));
    double duration = fmin(b->duration, span);
    double start = b->arrival - duration;
    double progress = duration > 0.0 ? mt_base_progress(fmax(0.0, fmin(1.0, (seconds - start) / duration)), b->easing) : 0.0;
    double value = (1.0 - progress) * a->values[c] + progress * b->values[c];
    if (a->addedMotion != MTAddedMotionNone && local > 0.0 && local < 1.0) {
        double amount = a->customMotion ? a->motionAmount : 1.0;
        double speed = a->customMotion ? a->motionSpeed : 1.0;
        value = mt_modulate(value, mt_motion_factor(local, a->addedMotion, c, amount, speed), a, c);
    }
    return value;
}

static double mt_hermite(const MTDestination *d, size_t count, size_t c,
                         double x, double boundary, double window) {
    if (window <= 0.0 || x <= boundary - window || x >= boundary + window)
        return mt_raw_component(d, count, c, x);
    double h = fmax(window * 0.05, 1.0e-5);
    double pB = mt_raw_component(d, count, c, boundary);
    double mB = (mt_raw_component(d,count,c,boundary+h)-mt_raw_component(d,count,c,boundary-h))/(2.0*h);
    bool left = x < boundary;
    double lo = left ? boundary-window : boundary;
    double hi = left ? boundary : boundary+window;
    double p0 = left ? mt_raw_component(d,count,c,lo) : pB;
    double p1 = left ? pB : mt_raw_component(d,count,c,hi);
    double m0 = left ? (mt_raw_component(d,count,c,lo+h)-mt_raw_component(d,count,c,lo-h))/(2.0*h) : mB;
    double m1 = left ? mB : (mt_raw_component(d,count,c,hi+h)-mt_raw_component(d,count,c,hi-h))/(2.0*h);
    double u=(x-lo)/(hi-lo), u2=u*u, u3=u2*u;
    return (2*u3-3*u2+1)*p0 + (u3-2*u2+u)*m0*(hi-lo) +
           (-2*u3+3*u2)*p1 + (u3-u2)*m1*(hi-lo);
}

bool MTSample(const MTDestination *d, size_t count, size_t components,
              double seconds, double *output) {
    if (!d || !count || !components || !output || !isfinite(seconds)) return false;
    for (size_t i = 0; i < count; ++i) {
        if (!d[i].values || d[i].easing < MTEasingSmooth || d[i].easing > MTEasingEaseOut || d[i].addedMotion < MTAddedMotionNone || d[i].addedMotion > MTAddedMotionHandheld || !isfinite(d[i].arrival) || d[i].arrival < 0 ||
            !isfinite(d[i].duration) || d[i].duration < 0 ||
            (i && d[i].arrival <= d[i-1].arrival)) return false;
        for (size_t c = 0; c < components; ++c)
            if (!isfinite(d[i].values[c])) return false;
        if ((d[i].modulationMins == NULL) != (d[i].modulationMaxs == NULL) ||
            (d[i].modulationRangeCount > 0 && (!d[i].modulationMins || !d[i].modulationMaxs))) return false;
        for (size_t c = 0; c < d[i].modulationRangeCount; ++c)
            if (!isfinite(d[i].modulationMins[c]) || !isfinite(d[i].modulationMaxs[c]) ||
                d[i].modulationMaxs[c] < d[i].modulationMins[c]) return false;
        if (d[i].customMotion &&
            (!isfinite(d[i].motionAmount) || d[i].motionAmount < 0.0 ||
             !isfinite(d[i].motionSpeed) || d[i].motionSpeed <= 0.0)) return false;
    }
    for (size_t c = 0; c < components; ++c) {
        output[c] = mt_raw_component(d, count, c, seconds);
        for (size_t i = 1; i + 1 < count; ++i) {
            if (!mt_motion_enabled(&d[i-1]) && !mt_motion_enabled(&d[i])) continue;
            // KK_JOIN_BLEND_MOD_FRAC: preserve the broad motion join fillet.
            double w = 0.42 * fmin(d[i].arrival-d[i-1].arrival, d[i+1].arrival-d[i].arrival);
            if (fabs(seconds-d[i].arrival) < w) { output[c] = mt_hermite(d,count,c,seconds,d[i].arrival,w); break; }
        }
    }
    return true;
}
