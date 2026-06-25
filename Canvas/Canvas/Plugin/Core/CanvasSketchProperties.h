/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKBezierPath;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Resolved Sketch (hand-drawn) parameters at a clip fraction.
typedef struct {
  BOOL enabled;
  float roughness; // 0-3
  float bowing;    // 0-3
  uint8_t strokes; // over-draw passes (1 single, 2 double)
  uint32_t seed;   // fixed randomness
} CanvasSketchParams;

/// Whether the layer's Sketch is on at `frac` (the "Sketch Enabled" lane, flat
/// `sketchEnabled` fallback).
BOOL CanvasSketchEnabledAtFraction(KKBezierPath *path, double frac,
                                   NSString *_Nullable overrideLayerID,
                                   KKTimeline *_Nullable overrideTimeline);

/// Resolve all Sketch params at `frac` (roughness/bowing smoothed, strokes/seed
/// stepped). Falls back to the flat sketch* props when a lane is absent.
CanvasSketchParams
CanvasSketchParamsAtFraction(KKBezierPath *path, double frac,
                             NSString *_Nullable overrideLayerID,
                             KKTimeline *_Nullable overrideTimeline);

NS_ASSUME_NONNULL_END
