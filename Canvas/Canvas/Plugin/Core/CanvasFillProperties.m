/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Per-fraction FILL PROPERTY evaluators (the fill parallel of
// CanvasStrokeProperties): read a layer's fill enabled / colour from its
// timeline lanes at a clip fraction, falling back to the flat KKBezierPath fill
// props when a lane is absent. The live-edit override hook lets the selected
// layer preview before it persists.

#import "CanvasFillProperties.h"
#import "CanvasLayerTransform.h" // CanvasLayerEffectiveTimeline (shared)
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTimingStage.h>

BOOL CanvasFillEnabledAtFraction(KKBezierPath *path, double frac,
                                 NSString *overrideLayerID,
                                 KKTimeline *overrideTimeline) {
  BOOL on = path.fillEnabled; // flat fallback (no "Fill Enabled" lane yet)
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (![lane.label isEqualToString:@"Fill Enabled"])
      continue;
    if (lane.keyposes.count > 0) {
      NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
      if (v.count > 0)
        on = v[0].doubleValue >= 0.5;
    }
    break;
  }
  return on;
}

KKColorLanesValue CanvasFillColorAtFraction(KKBezierPath *path, double frac,
                                            NSString *overrideLayerID,
                                            KKTimeline *overrideTimeline) {
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  // No colour lanes (a path whose animationJSON predates fill colour): fall
  // back to the flat solid colour so it renders exactly as before.
  BOOL hasColorLanes = NO;
  for (KKLane *lane in tl.lanes)
    if ([lane.label isEqualToString:KKColorLanesModeLabel(@"Fill")] ||
        [lane.label isEqualToString:KKColorLanesSolidLabel(@"Fill")]) {
      hasColorLanes = YES;
      break;
    }
  if (!hasColorLanes) {
    KKColorLanesValue v;
    memset(&v, 0, sizeof(v));
    v.mode = path.fillColorMode == 1 ? KKColorModeGradient : KKColorModeSolid;
    v.solidColor = simd_make_float3(path.fillR, path.fillG, path.fillB);
    return v;
  }
  return KKColorLanesResolve(
      @"Fill", /*includesDynamic=*/NO, ^NSArray<NSNumber *> *(NSString *l) {
        for (KKLane *lane in tl.lanes)
          if ([lane.label isEqualToString:l])
            return KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
        return nil;
      });
}

float CanvasFillTintAtFraction(KKBezierPath *path, double frac,
                               NSString *overrideLayerID,
                               KKTimeline *overrideTimeline) {
  float tint = path.fillTint; // flat fallback (no "Fill Amount" lane yet)
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (![lane.label isEqualToString:@"Fill Amount"])
      continue;
    if (lane.keyposes.count > 0) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      if (v.count > 0)
        tint = (float)fmax(0.0, fmin(1.0, v[0].doubleValue / 100.0));
    }
    break;
  }
  return tint;
}

CanvasFillStyle CanvasFillStyleAtFraction(KKBezierPath *path, double frac,
                                          NSString *overrideLayerID,
                                          KKTimeline *overrideTimeline) {
  const double kDegToRad = M_PI / 180.0;
  CanvasFillStyle s;
  s.style = path.sketchFillStyle; // flat fallback
  s.gap = path.sketchFillGap;
  s.angle = (float)(path.sketchFillAngle * kDegToRad);
  s.weight = path.sketchFillWeight;
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (lane.keyposes.count == 0)
      continue;
    if ([lane.label isEqualToString:@"Fill Style"]) {
      NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
      if (v.count > 0)
        s.style = (uint8_t)llround(fmax(0.0, v[0].doubleValue));
    } else if ([lane.label isEqualToString:@"Fill Gap"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      if (v.count > 0)
        s.gap = (float)fmax(1.0, v[0].doubleValue);
    } else if ([lane.label isEqualToString:@"Fill Angle"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      if (v.count > 0)
        s.angle = (float)(v[0].doubleValue * kDegToRad);
    } else if ([lane.label isEqualToString:@"Fill Weight"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      if (v.count > 0)
        s.weight = (float)fmax(0.5, v[0].doubleValue);
    }
  }
  return s;
}
