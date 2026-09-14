/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Centerline tracing: the inverse of "Stroke to path" (CanvasApplyOutlineOp).
/// For every selected FILLED vector layer, rasterize its fill, thin it to a
/// 1px skeleton (Zhang-Suen), trace the skeleton into polyline branches and
/// insert ONE stroked path (each branch a contour) just above the source. The
/// source's fill is turned off (non-destructive, mirroring the outline op).
/// refWidth/Height are the TRUE render output px (used to size the recovered
/// stroke width). Mutates `paths` in place; returns the layerIDs that become
/// the new selection (the traced result(s)), or nil when it's a no-op.
NSArray<NSString *> *_Nullable CanvasApplyCenterlineOp(
    NSMutableArray<KKBezierPath *> *paths,
    NSArray<NSString *> *selectedLayerIDs, CGFloat refWidth, CGFloat refHeight);

NS_ASSUME_NONNULL_END
