/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineAdvancedView_Private.h"

#import "KKTimelineScale.h"

// Per-lane non-linear ("Dynamic") display warp. Each lane has its own
// keyposes, so each warps independently: the data domain [0, lastFrameFrac] is
// partitioned at every keypose time, each segment gets a log-weighted display
// width (KKTimelineScaleLogWeight - the same primitive Basic uses) with a hard
// floor of one pill so short transitions stay grabbable, and the widths are
// renormalised to fill the track. The floor only ADDS width, so the map stays
// strictly increasing and fully invertible (no flat region). Within a single
// segment the map is linear, so the curve sampler can keep interpolating x
// between a gap's two endpoints - only the endpoints need warping.

// Fill breaks[0..M] (data fractions) and uAt[0..M] (cumulative visual u in
// [0,1], uAt[0]=0, uAt[M]=1). Buffers must hold at least count+2 entries.
// Returns the segment count M (0 if degenerate). `tracksW` is the unzoomed
// track width in points, used to size the one-pill floor in visual units.
// `times` are the lane's keypose times (any order); the bisection drag solver
// probes candidate positions by passing a mutated copy.
static NSInteger KKBuildLaneWarpFromTimes(const double *times, NSInteger count,
                                          double lf, double clipDur,
                                          CGFloat tracksW, double *breaks,
                                          double *uAt) {
  if (lf <= 0.0)
    lf = 1.0;
  NSInteger nb = 0;
  breaks[nb++] = 0.0;
  for (NSInteger i = 0; i < count; i++) {
    double t = times[i];
    t = (t < 0.0) ? 0.0 : (t > lf ? lf : t);
    breaks[nb++] = t;
  }
  breaks[nb++] = lf;
  // Clamping + endpoints can disorder the (otherwise sorted) keypose times;
  // insertion sort is fine for the handful of breakpoints involved.
  for (NSInteger i = 1; i < nb; i++) {
    double v = breaks[i];
    NSInteger j = i - 1;
    while (j >= 0 && breaks[j] > v) {
      breaks[j + 1] = breaks[j];
      j--;
    }
    breaks[j + 1] = v;
  }
  NSInteger m = 0;
  for (NSInteger i = 0; i < nb; i++)
    if (m == 0 || breaks[i] - breaks[m - 1] > 1.0e-9)
      breaks[m++] = breaks[i];
  NSInteger M = m - 1;
  if (M <= 0) {
    uAt[0] = 0.0;
    return 0;
  }

  double sumW = 0.0;
  NSInteger nz = 0;
  for (NSInteger j = 0; j < M; j++) {
    double dur = breaks[j + 1] - breaks[j];
    if (dur > 1.0e-9) {
      sumW += KKTimelineScaleLogWeight(dur, clipDur);
      nz++;
    }
  }
  if (nz == 0 || sumW <= 0.0) {
    for (NSInteger j = 0; j <= M; j++)
      uAt[j] = (double)j / (double)M;
    return M;
  }

  double floorU = (tracksW > 0.0) ? (double)kPillW / (double)tracksW : 0.0;
  // If a full pill per gap would overflow the track, fall back to equal widths
  // (the best we can do when there are more gaps than pixels).
  if (floorU * (double)nz > 1.0)
    floorU = 1.0 / (double)nz;
  double rem = 1.0 - floorU * (double)nz;

  uAt[0] = 0.0;
  double acc = 0.0;
  for (NSInteger j = 0; j < M; j++) {
    double dur = breaks[j + 1] - breaks[j];
    double d = 0.0;
    if (dur > 1.0e-9) {
      double wj = KKTimelineScaleLogWeight(dur, clipDur) / sumW;
      d = floorU + wj * rem;
    }
    acc += d;
    uAt[j + 1] = acc;
  }
  if (acc > 0.0)
    for (NSInteger j = 1; j <= M; j++)
      uAt[j] /= acc;
  return M;
}

static double KKWarpU(double frac, const double *breaks, const double *uAt,
                      NSInteger M, double lf) {
  if (lf <= 0.0)
    lf = 1.0;
  if (frac <= 0.0)
    return 0.0;
  if (frac >= lf)
    return 1.0;
  for (NSInteger j = 0; j < M; j++) {
    if (frac <= breaks[j + 1]) {
      double seg = breaks[j + 1] - breaks[j];
      double localT = seg > 1.0e-12 ? (frac - breaks[j]) / seg : 0.0;
      return uAt[j] + (uAt[j + 1] - uAt[j]) * localT;
    }
  }
  return 1.0;
}

static double KKWarpFrac(double u, const double *breaks, const double *uAt,
                         NSInteger M, double lf) {
  if (lf <= 0.0)
    lf = 1.0;
  if (u <= 0.0)
    return 0.0;
  if (u >= 1.0)
    return lf;
  for (NSInteger j = 0; j < M; j++) {
    if (u <= uAt[j + 1]) {
      double du = uAt[j + 1] - uAt[j];
      double localT = du > 1.0e-12 ? (u - uAt[j]) / du : 0.0;
      return breaks[j] + (breaks[j + 1] - breaks[j]) * localT;
    }
  }
  return lf;
}

// Copy an NSArray of time NSNumbers into a C buffer (caller-owned, >= count).
static NSInteger KKCopyTimes(NSArray<NSNumber *> *times, double *out) {
  NSInteger n = (NSInteger)times.count;
  for (NSInteger i = 0; i < n; i++)
    out[i] = times[i].doubleValue;
  return n;
}

@implementation KKTimelineAdvancedView (Warp)

// Forward warp: data frac -> screen x, using the keypose `times` (already
// extracted) to build the per-lane partition. Shared by the live projection
// and the frozen warp used during a selection drag.
- (CGFloat)_warpedXForFrac:(double)frac
                timesArray:(NSArray<NSNumber *> *)times
                  inTracks:(NSRect)t {
  NSInteger count = (NSInteger)times.count;
  NSInteger cap = count + 2;
  double *raw = malloc(sizeof(double) * (size_t)count);
  double *breaks = malloc(sizeof(double) * (size_t)cap);
  double *uAt = malloc(sizeof(double) * (size_t)cap);
  KKCopyTimes(times, raw);
  double lf = [self _lastFrameFrac];
  NSInteger M = KKBuildLaneWarpFromTimes(raw, count, lf, [self _clipDuration],
                                         NSWidth(t), breaks, uAt);
  double u = (M > 0) ? KKWarpU(frac, breaks, uAt, M, lf)
                     : (lf < 1.0 ? frac / lf : frac);
  free(raw);
  free(breaks);
  free(uAt);
  double z = _zp ? _zp.zoom : 1.0;
  double pan = _zp ? _zp.panOffset : 0.0;
  return NSMinX(t) + (u - pan) * NSWidth(t) * z;
}

- (double)_warpedFracForX:(CGFloat)x
               timesArray:(NSArray<NSNumber *> *)times
                 inTracks:(NSRect)t {
  if (NSWidth(t) <= 0)
    return 0.0;
  double z = _zp ? _zp.zoom : 1.0;
  double pan = _zp ? _zp.panOffset : 0.0;
  double u = pan + (x - NSMinX(t)) / (NSWidth(t) * z);
  NSInteger count = (NSInteger)times.count;
  NSInteger cap = count + 2;
  double *raw = malloc(sizeof(double) * (size_t)count);
  double *breaks = malloc(sizeof(double) * (size_t)cap);
  double *uAt = malloc(sizeof(double) * (size_t)cap);
  KKCopyTimes(times, raw);
  double lf = [self _lastFrameFrac];
  NSInteger M = KKBuildLaneWarpFromTimes(raw, count, lf, [self _clipDuration],
                                         NSWidth(t), breaks, uAt);
  double f =
      (M > 0) ? KKWarpFrac(u, breaks, uAt, M, lf) : (lf < 1.0 ? u * lf : u);
  free(raw);
  free(breaks);
  free(uAt);
  double hi = lf < 1.0 ? lf : 1.0;
  return f < 0.0 ? 0.0 : (f > hi ? hi : f);
}

- (NSArray<NSNumber *> *)_laneKeyposeTimes:(KKLane *)lane {
  NSMutableArray<NSNumber *> *out =
      [NSMutableArray arrayWithCapacity:lane.keyposes.count];
  for (KKKeyPose *kp in lane.keyposes)
    [out addObject:@(kp.time)];
  return out;
}

- (CGFloat)_xForFrac:(double)frac inLane:(KKLane *)lane inTracks:(NSRect)t {
  if (!_dynamicDisplay || lane.keyposes.count < 2)
    return [self _xForFrac:frac inTracks:t];
  return [self _warpedXForFrac:frac
                    timesArray:[self _laneKeyposeTimes:lane]
                      inTracks:t];
}

- (double)_fracForX:(CGFloat)x inLane:(KKLane *)lane inTracks:(NSRect)t {
  if (!_dynamicDisplay || lane.keyposes.count < 2)
    return [self _fracForX:x inTracks:t];
  return [self _warpedFracForX:x
                    timesArray:[self _laneKeyposeTimes:lane]
                      inTracks:t];
}

// Single-pill drag: the dragged keypose's time is itself a warp breakpoint, so
// inverting the cursor through the current warp pings (Basic's lesson, see
// project_basic_timeline_log_scale). Bisect for the data frac whose warped x
// equals the cursor, rebuilding the warp with the dragged KP at each candidate.
// Exact, feedback-free, live - the handle tracks the cursor under the warp.
- (double)_dragFracForX:(CGFloat)x
                 inLane:(KKLane *)lane
          draggingKPIdx:(NSInteger)kpIdx
               inTracks:(NSRect)t {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (!_dynamicDisplay || kps.count < 2 || kpIdx < 0 ||
      kpIdx >= (NSInteger)kps.count || NSWidth(t) <= 0)
    return [self _fracForX:x inTracks:t];
  double lf = [self _lastFrameFrac];
  double clipDur = [self _clipDuration];
  CGFloat w = NSWidth(t);
  double z = _zp ? _zp.zoom : 1.0;
  double pan = _zp ? _zp.panOffset : 0.0;
  double targetU = pan + (x - NSMinX(t)) / (w * z);
  if (targetU <= 0.0)
    return 0.0;
  if (targetU >= 1.0)
    return lf;
  NSInteger count = (NSInteger)kps.count;
  NSInteger cap = count + 2;
  double *times = malloc(sizeof(double) * (size_t)count);
  double *breaks = malloc(sizeof(double) * (size_t)cap);
  double *uAt = malloc(sizeof(double) * (size_t)cap);
  for (NSInteger i = 0; i < count; i++)
    times[i] = kps[i].time;
  double lo = 0.0, hi = lf;
  for (int it = 0; it < 48; it++) {
    double mid = 0.5 * (lo + hi);
    times[kpIdx] = mid;
    NSInteger M =
        KKBuildLaneWarpFromTimes(times, count, lf, clipDur, w, breaks, uAt);
    double uMid = (M > 0) ? KKWarpU(mid, breaks, uAt, M, lf)
                          : (lf < 1.0 ? mid / lf : mid);
    if (uMid < targetU)
      lo = mid;
    else
      hi = mid;
  }
  double result = 0.5 * (lo + hi);
  free(times);
  free(breaks);
  free(uAt);
  return result < 0.0 ? 0.0 : (result > lf ? lf : result);
}

// Frozen-warp inverse for a selection drag: bisecting a whole moving group has
// no single fixed point, so the pressed lane's warp is snapshotted at drag
// start (_dragFrozenLaneTimes) and the cursor is inverted through it for the
// whole drag - stable, no creep. The group moves by a uniform frac delta.
- (double)_frozenDragFracForX:(CGFloat)x inTracks:(NSRect)t {
  if (!_dynamicDisplay || _dragFrozenLaneTimes.count < 2)
    return [self _fracForX:x inTracks:t];
  return [self _warpedFracForX:x timesArray:_dragFrozenLaneTimes inTracks:t];
}

@end
