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
/// curve (line) - onto `surface` via its CanvasPenSurface draw primitives, so it
/// looks identical in the viewer and the mini and stays in sync with the pen
/// preview. Each point is projected through the layer's transform + ancestor
/// groups at `frac` (CanvasProjectLayerPointsObj), so it lands exactly where the
/// stroke renders. Read-only display; point selection / dragging come later.
void CanvasDrawPathEditOSC(id<CanvasPenSurface> surface,
                           NSArray<KKBezierPath *> *layers, KKBezierPath *path,
                           double frac, float aspect);

NS_ASSUME_NONNULL_END
