/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Per-fraction FILL PROPERTY evaluators: read a layer's fill enabled / colour
// from its timeline lanes at a clip fraction, falling back to the flat
// KKBezierPath fill props when a lane is absent. The fill parallel of
// CanvasStrokeProperties.

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKColorLanes.h> // KKColorLanesValue

@class KKBezierPath;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Whether the fill is ON at `frac` from the layer's "Fill Enabled" toggle
/// lane, falling back to the flat `fillEnabled` when there is no lane. Shared
/// by the render so a lane-disabled fill stops drawing. `overrideLayerID` /
/// `overrideTimeline` let the live inspector edit of the selected layer preview
/// before it persists (pass nil/nil for the persisted state).
BOOL CanvasFillEnabledAtFraction(KKBezierPath *path, double frac,
                                 NSString *_Nullable overrideLayerID,
                                 KKTimeline *_Nullable overrideTimeline);

/// The resolved fill colour at `frac` from the layer's "Fill Mode/Solid/
/// Gradient" lanes (the shared KKColorLanes group, no Dynamic), falling back to
/// the flat fillColorMode / fillR,G,B when there is no lane yet. Same override
/// hook as the other evaluators.
KKColorLanesValue
CanvasFillColorAtFraction(KKBezierPath *path, double frac,
                          NSString *_Nullable overrideLayerID,
                          KKTimeline *_Nullable overrideTimeline);

/// The IMAGE-tint strength (0..1) at `frac` from the layer's "Fill Amount"
/// lane, falling back to the flat `fillTint`. 0 = original image, 1 = fully the
/// fill colour. Only meaningful for image layers.
float CanvasFillTintAtFraction(KKBezierPath *path, double frac,
                               NSString *_Nullable overrideLayerID,
                               KKTimeline *_Nullable overrideTimeline);

/// How a vector shape's fill is drawn at `frac`. `style` 0 = solid, 1 =
/// hachure, 2 = cross-hatch, 3 = zigzag, 4 = dots; `gap` the line spacing (px),
/// `angle` the hachure angle (RADIANS, converted from the lane's degrees),
/// `weight` the line thickness (px). Read from the "Fill Style"/"Fill
/// Gap"/"Fill Angle"/"Fill Weight" lanes, falling back to the flat sketchFill*
/// props.
typedef struct {
  uint8_t style;
  float gap;
  float angle;
  float weight;
} CanvasFillStyle;

CanvasFillStyle
CanvasFillStyleAtFraction(KKBezierPath *path, double frac,
                          NSString *_Nullable overrideLayerID,
                          KKTimeline *_Nullable overrideTimeline);

NS_ASSUME_NONNULL_END
