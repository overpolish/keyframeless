/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Per-fraction SKETCH PROPERTY evaluators (the sketch parallel of
// CanvasFillProperties): read a layer's hand-drawn roughness params from its
// timeline lanes at a clip fraction, falling back to the flat KKBezierPath
// sketch* props when a lane is absent.

#import "CanvasSketchProperties.h"
#import "CanvasLayerTransform.h" // CanvasLayerEffectiveTimeline (shared)
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

BOOL CanvasSketchEnabledAtFraction(KKBezierPath *path, double frac,
                                   NSString *overrideLayerID,
                                   KKTimeline *overrideTimeline) {
  BOOL on = path.sketchEnabled; // flat fallback
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (![lane.label isEqualToString:@"Sketch Enabled"])
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

CanvasSketchParams CanvasSketchParamsAtFraction(KKBezierPath *path, double frac,
                                                NSString *overrideLayerID,
                                                KKTimeline *overrideTimeline) {
  CanvasSketchParams p;
  p.enabled = path.sketchEnabled; // flat fallbacks
  p.roughness = path.sketchRoughness;
  p.bowing = path.sketchBowing;
  p.strokes = path.sketchStrokes ?: 2;
  p.seed = path.sketchSeed ?: 1;
  KKTimeline *tl =
      CanvasLayerEffectiveTimeline(path, overrideLayerID, overrideTimeline);
  for (KKLane *lane in tl.lanes) {
    if (lane.keyposes.count == 0)
      continue;
    if ([lane.label isEqualToString:@"Sketch Enabled"]) {
      NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
      if (v.count > 0)
        p.enabled = v[0].doubleValue >= 0.5;
    } else if ([lane.label isEqualToString:@"Sketch Roughness"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      if (v.count > 0)
        p.roughness = (float)fmax(0.0, v[0].doubleValue);
    } else if ([lane.label isEqualToString:@"Sketch Bowing"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      if (v.count > 0)
        p.bowing = (float)fmax(0.0, v[0].doubleValue);
    } else if ([lane.label isEqualToString:@"Sketch Strokes"]) {
      // Pill index: 0 = Single (1 pass), 1 = Double (2 passes).
      NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
      if (v.count > 0)
        p.strokes = v[0].doubleValue >= 0.5 ? 2 : 1;
    } else if ([lane.label isEqualToString:@"Sketch Seed"]) {
      NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
      if (v.count > 0)
        p.seed = (uint32_t)fmax(1.0, llround(v[0].doubleValue));
    }
  }
  return p;
}
