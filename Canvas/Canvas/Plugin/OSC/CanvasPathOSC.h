/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@protocol CanvasPenSurface;
@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Draw a committed path's edit OSC - the anchors (points) and the connecting
/// curve (line) - onto `surface` via its CanvasPenSurface draw primitives, so
/// it looks identical in the viewer and the mini and stays in sync with the pen
/// preview. Each point is projected through the layer's transform + ancestor
/// groups at `frac` (CanvasProjectLayerPointsObj), so it lands exactly where
/// the stroke renders. Anchors whose index is in `selected` draw in the host
/// accent (active). When `marqueeActive`, the `marqueeSurfaceRect` rubber-band
/// is drawn on top (surface points, no projection). When `ghost` is YES the
/// anchors draw dimmed - used to preview a hidden Points OSC during an Opt-peek
/// so an Opt-click can re-show it (mirrors the transform handles' reveal
/// ghost).
/// The connecting guide curve is drawn from the corner-EXPANDED geometry so it
/// matches the rounded stroke, while the anchors stay at the stored (sharp)
/// corners. `showCornerWidgets` draws the live-corner radius handles (cursor tool
/// only - they're not interactive while drawing with the pen).
void CanvasDrawPathEditOSC(id<CanvasPenSurface> surface,
                           NSArray<KKBezierPath *> *layers, KKBezierPath *path,
                           double frac, float aspect,
                           NSIndexSet *_Nullable selected, BOOL marqueeActive,
                           CGRect marqueeSurfaceRect, BOOL ghost,
                           BOOL showCornerWidgets);

NS_ASSUME_NONNULL_END
