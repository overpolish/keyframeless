/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "MotionTiming.h"
#include <math.h>

bool MTSample(const MTDestination *d, size_t count, size_t components,
              double seconds, double *output) {
    if (!d || !count || !components || !output || !isfinite(seconds)) return false;
    for (size_t i = 0; i < count; ++i) {
        if (!d[i].values || d[i].easing < MTEasingSmooth || d[i].easing > MTEasingEaseOut || !isfinite(d[i].arrival) || d[i].arrival < 0 ||
            !isfinite(d[i].duration) || d[i].duration < 0 ||
            (i && d[i].arrival <= d[i-1].arrival)) return false;
        for (size_t c = 0; c < components; ++c)
            if (!isfinite(d[i].values[c])) return false;
    }
    size_t next = 0;
    while (next < count && seconds >= d[next].arrival) ++next;
    if (next == 0 || next == count) {
        const double *values = d[next == 0 ? 0 : count-1].values;
        for (size_t c = 0; c < components; ++c) output[c] = values[c];
        return true;
    }
    double duration = fmin(d[next].duration, d[next].arrival - d[next-1].arrival);
    double start = d[next].arrival - duration;
    double t = duration > 0 ? fmax(0, (seconds-start)/duration) : 0;
    double progress;
    switch (d[next].easing) {
        case MTEasingLinear: progress = t; break;
        case MTEasingEaseIn: progress = t*t; break;
        case MTEasingEaseOut: progress = t*(2-t); break;
        default: progress = t*t*(3-2*t); break;
    }
    for (size_t c = 0; c < components; ++c)
        output[c] = (1-progress)*d[next-1].values[c] + progress*d[next].values[c];
    return true;
}
