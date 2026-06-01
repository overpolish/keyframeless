/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Reusable zoom/pan state for a timeline track, in normalised display
/// (`u`) space - model-agnostic, so `KKTimelineBasicView` and the upcoming
/// Advanced sequencer share identical cursor-anchored pinch + scroll-pan
/// behaviour. The owning view feeds raw events in and reads `zoom` /
/// `panOffset` back out (e.g. into its projection); pan clamping uses the
/// shared `KKTimelineScale` transform.
@interface KKTimelineZoomPan : NSObject

@property(nonatomic) double zoom;      ///< 1 = fit. Clamped to [1, maxZoom].
@property(nonatomic) double panOffset; ///< Visible start in u-space.
@property(nonatomic) double maxZoom;   ///< Default 20.

/// YES once zoomed or panned away from the fitted origin.
@property(nonatomic, readonly) BOOL isZoomed;

/// Back to fit (zoom 1, pan 0). Returns YES if anything changed.
- (BOOL)reset;

/// Cursor-anchored pinch: the u under screen x stays put across the zoom.
/// Returns YES if the rect is usable (caller should redraw).
- (BOOL)magnifyBy:(CGFloat)magnification atX:(CGFloat)x inRect:(NSRect)g;

/// Horizontal scroll pan. `precise` = trackpad pixel deltas (vs lines).
/// Returns YES if the rect is usable (caller should redraw).
- (BOOL)panByScrollDeltaX:(CGFloat)dx precise:(BOOL)precise inRect:(NSRect)g;

@end

NS_ASSUME_NONNULL_END
