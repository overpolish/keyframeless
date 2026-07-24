/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Per-fraction STROKE PROPERTY evaluators: read a layer's stroke width /
// enabled / colour / cap-join / markers / dash style / draw-on from its
// timeline lanes at a clip fraction, falling back to the flat KKBezierPath
// props when a lane is absent. Split out of CanvasLayerTransform.m (which keeps
// the 3D matrix math) - these share the same CanvasLayerTransform.h
// declarations but are a distinct "evaluate stroke lanes" concern. The
// live-edit override hook (CanvasLayerEffectiveTimeline, shared in
// CanvasLayerTransform) lets the selected layer preview before it persists.

#import "CanvasLayerTimeline.h"  // CanvasResolvedLaneValue
#import "CanvasLayerTransform.h" // CanvasLayerEffectiveTimeline (shared)
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

void CanvasStrokeWidthAtFraction(KKBezierPath *path, double frac,
                                 NSString *overrideLayerID,
                                 KKTimeline *overrideTimeline, float *outStart,
                                 float *outEnd) {
  // Default to the layer's flat width (existing paths with no Stroke Width lane
  // yet); End falls back to Start when unset (no taper).
  float sw = path.strokeWidth;
  float ew = path.endWidth > 0.0f ? path.endWidth : sw;
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (![lane.key isEqualToString:@"Stroke Width"])
      continue;
    if (lane.keyposes.count > 0) {
      NSArray<NSNumber *> *v = CanvasResolvedLaneValue(lane, frac);
      if (v.count > 0)
        sw = (float)fmax(0.0, v[0].doubleValue);
      ew = (v.count > 1) ? (float)fmax(0.0, v[1].doubleValue) : sw;
    }
    break;
  }
  if (outStart)
    *outStart = sw;
  if (outEnd)
    *outEnd = ew;
}

BOOL CanvasStrokeEnabledAtFraction(KKBezierPath *path, double frac,
                                   NSString *overrideLayerID,
                                   KKTimeline *overrideTimeline) {
  BOOL on = path.strokeEnabled; // flat fallback (no "Enabled" lane yet)
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (![lane.key isEqualToString:@"Enabled"])
      continue;
    if (lane.keyposes.count > 0 || lane.linkExpression.length) {
      NSArray<NSNumber *> *v = CanvasResolvedDiscreteLaneValue(lane, frac);
      if (v.count > 0)
        on = v[0].doubleValue >= 0.5;
    }
    break;
  }
  return on;
}

KKColorLanesValue CanvasStrokeColorAtFraction(KKBezierPath *path, double frac,
                                              NSString *overrideLayerID,
                                              KKTimeline *overrideTimeline) {
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  // No colour lanes (a path whose animationJSON predates stroke colour): fall
  // back to the flat solid colour so it renders exactly as before.
  BOOL hasColorLanes = NO;
  for (KKLane *lane in tl.lanes)
    if ([lane.key isEqualToString:KKColorLanesModeLabel(@"Stroke")] ||
        [lane.key isEqualToString:KKColorLanesSolidLabel(@"Stroke")]) {
      hasColorLanes = YES;
      break;
    }
  if (!hasColorLanes) {
    KKColorLanesValue v;
    memset(&v, 0, sizeof(v));
    v.mode = path.strokeColorMode == 1 ? KKColorModeGradient : KKColorModeSolid;
    v.solidColor = simd_make_float3(path.strokeR, path.strokeG, path.strokeB);
    return v;
  }
  return KKColorLanesResolve(@"Stroke", /*includesDynamic=*/NO,
                             ^NSArray<NSNumber *> *(NSString *l) {
                               for (KKLane *lane in tl.lanes)
                                 if ([lane.key isEqualToString:l])
                                   return CanvasResolvedLaneValue(lane, frac);
                               return nil;
                             });
}

void CanvasStrokeCapJoinAtFraction(KKBezierPath *path, double frac,
                                   NSString *overrideLayerID,
                                   KKTimeline *overrideTimeline,
                                   uint8_t *outCap, uint8_t *outJoin) {
  uint8_t cap = path.lineCap, join = path.lineJoin; // flat fallback
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (lane.keyposes.count == 0 && lane.linkExpression.length == 0)
      continue;
    if ([lane.key isEqualToString:@"Line Cap"]) {
      NSArray<NSNumber *> *v = CanvasResolvedDiscreteLaneValue(lane, frac);
      if (v.count > 0)
        cap = (uint8_t)llround(fmax(0.0, v[0].doubleValue));
    } else if ([lane.key isEqualToString:@"Line Join"]) {
      NSArray<NSNumber *> *v = CanvasResolvedDiscreteLaneValue(lane, frac);
      if (v.count > 0)
        join = (uint8_t)llround(fmax(0.0, v[0].doubleValue));
    }
  }
  if (outCap)
    *outCap = cap;
  if (outJoin)
    *outJoin = join;
}

void CanvasStrokeMarkersAtFraction(KKBezierPath *path, double frac,
                                   NSString *overrideLayerID,
                                   KKTimeline *overrideTimeline,
                                   uint8_t *outStart, uint8_t *outEnd,
                                   float *outStartMul, float *outEndMul) {
  uint8_t startM = path.startMarker, endM = path.endMarker; // flat fallback
  float startMul = path.startMarkerSize, endMul = path.endMarkerSize;
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (lane.keyposes.count == 0 && lane.linkExpression.length == 0)
      continue;
    if ([lane.key isEqualToString:@"Start Marker"]) {
      NSArray<NSNumber *> *v = CanvasResolvedDiscreteLaneValue(lane, frac);
      if (v.count > 0)
        startM = (uint8_t)llround(fmax(0.0, v[0].doubleValue));
    } else if ([lane.key isEqualToString:@"End Marker"]) {
      NSArray<NSNumber *> *v = CanvasResolvedDiscreteLaneValue(lane, frac);
      if (v.count > 0)
        endM = (uint8_t)llround(fmax(0.0, v[0].doubleValue));
    } else if ([lane.key isEqualToString:@"Start Marker Width"]) {
      // Percentage of the local stroke width; converted to a multiplier.
      // Continuous - display evaluation like its Stroke Width sibling.
      NSArray<NSNumber *> *v = CanvasResolvedLaneValue(lane, frac);
      if (v.count > 0)
        startMul = (float)(fmax(0.0, v[0].doubleValue) / 100.0);
    } else if ([lane.key isEqualToString:@"End Marker Width"]) {
      NSArray<NSNumber *> *v = CanvasResolvedLaneValue(lane, frac);
      if (v.count > 0)
        endMul = (float)(fmax(0.0, v[0].doubleValue) / 100.0);
    }
  }
  if (outStart)
    *outStart = startM;
  if (outEnd)
    *outEnd = endM;
  if (outStartMul)
    *outStartMul = startMul;
  if (outEndMul)
    *outEndMul = endMul;
}

CanvasStrokeStyle CanvasStrokeStyleAtFraction(KKBezierPath *path, double frac,
                                              NSString *overrideLayerID,
                                              KKTimeline *overrideTimeline) {
  CanvasStrokeStyle s;
  s.style = path.strokeStyle; // flat fallback
  s.dashLength = path.dashLength;
  s.dashGap = path.dashGap;
  s.dotGap = path.dotGap;
  s.marchSpeed = path.marchingAntsSpeed;
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (lane.keyposes.count == 0 && lane.linkExpression.length == 0)
      continue;
    if ([lane.key isEqualToString:@"Stroke Style"]) {
      NSArray<NSNumber *> *v = CanvasResolvedDiscreteLaneValue(lane, frac);
      if (v.count > 0)
        s.style = (uint8_t)llround(fmax(0.0, v[0].doubleValue));
    } else if ([lane.key isEqualToString:@"Dash Length"]) {
      // Continuous lanes: display evaluation, like Stroke Width / Marching
      // Ants Speed (the discrete index lanes above stay exact via the
      // discrete resolver unless an expression owns them).
      NSArray<NSNumber *> *v = CanvasResolvedLaneValue(lane, frac);
      if (v.count > 0)
        s.dashLength = (float)fmax(0.0, v[0].doubleValue);
    } else if ([lane.key isEqualToString:@"Dash Gap"]) {
      NSArray<NSNumber *> *v = CanvasResolvedLaneValue(lane, frac);
      if (v.count > 0)
        s.dashGap = (float)fmax(0.0, v[0].doubleValue);
    } else if ([lane.key isEqualToString:@"Dot Gap"]) {
      NSArray<NSNumber *> *v = CanvasResolvedLaneValue(lane, frac);
      if (v.count > 0)
        s.dotGap = (float)fmax(0.0, v[0].doubleValue);
    } else if ([lane.key isEqualToString:@"Marching Ants Speed"]) {
      // Animatable: read the smoothed value so a keyframed speed eases.
      NSArray<NSNumber *> *v = CanvasResolvedLaneValue(lane, frac);
      if (v.count > 0)
        s.marchSpeed = (float)v[0].doubleValue;
    }
  }
  return s;
}

CanvasStrokeDrawOn CanvasStrokeDrawOnAtFraction(KKBezierPath *path, double frac,
                                                NSString *overrideLayerID,
                                                KKTimeline *overrideTimeline) {
  CanvasStrokeDrawOn d;
  d.start = fmaxf(0.0f, fminf(1.0f, path.drawOnStart)); // flat fallback
  d.end = fmaxf(0.0f, fminf(1.0f, path.drawOnEnd));
  // Offset wraps to [0,1) for ANY value (the field is unbounded so it can spin
  // round and round, forwards or backwards): x - floor(x).
  float o0 = path.drawOnOrigin;
  d.offset = o0 - floorf(o0);
  d.offsetEngaged = d.offset > 1e-6f;
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (lane.keyposes.count == 0)
      continue;
    if ([lane.key isEqualToString:@"Draw On Start"]) {
      NSArray<NSNumber *> *v = CanvasResolvedLaneValue(lane, frac);
      if (v.count > 0)
        d.start = (float)fmax(0.0, fmin(1.0, v[0].doubleValue / 100.0));
    } else if ([lane.key isEqualToString:@"Draw On End"]) {
      NSArray<NSNumber *> *v = CanvasResolvedLaneValue(lane, frac);
      if (v.count > 0)
        d.end = (float)fmax(0.0, fmin(1.0, v[0].doubleValue / 100.0));
    } else if ([lane.key isEqualToString:@"Draw On Offset"]) {
      NSArray<NSNumber *> *v = CanvasResolvedLaneValue(lane, frac);
      if (v.count > 0) {
        double o = v[0].doubleValue / 100.0; // unbounded; wrap to [0,1)
        d.offset = (float)(o - floor(o));
        // Engaged when the offset is ANIMATED (lane.enabled) - so a spin stays
        // in offset mode CONSISTENTLY through every 0/100/200 % wrap (no mode
        // flip / flash where the value momentarily hits 0) - or when a static
        // value is non-zero (a fixed shifted reveal). A static 0 that isn't
        // animated is a genuine no-shift, so it falls back to the normal
        // draw-on markers.
        d.offsetEngaged = lane.enabled || fabs(o) > 1e-6;
      }
    }
  }
  return d;
}
