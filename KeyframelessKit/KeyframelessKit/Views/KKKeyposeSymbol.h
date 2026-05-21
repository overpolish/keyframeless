/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Plugin- and model-agnostic timeline drawing primitives shared by
/// `KKTimelineBasicView` and the upcoming Advanced sequencer: the keypose
/// diamond glyph and the smooth motion-curve stroke. Callers compute the
/// points (each model warps frac→x its own way); the look stays identical.

/// Draw a keypose diamond centred at `center` with half-diagonal `radius`.
/// Filled = a solid diamond in `color`; unfilled = an
/// `inspectorBackground`-filled diamond stroked in `color` (the
/// hollow/time-locked endpoint look).
FOUNDATION_EXPORT void KKDrawKeyposeDiamond(NSPoint center, CGFloat radius,
                                            BOOL filled, NSColor *color);

/// Draw a vertical-capsule keypose marker filling `bounds`. The keypose
/// pill is the time-axis equivalent of the diamond: it says "drag in time
/// only" by spanning the full row/track height. Filled = solid `color`;
/// unfilled = `inspectorBackground` fill stroked in `color` (time-locked
/// endpoint look — matches the diamond's hollow style).
FOUNDATION_EXPORT void KKDrawKeyposePill(NSRect bounds, BOOL filled,
                                         NSColor *color);

/// Stroke a smooth motion curve through `points` (round joins/caps,
/// `width`). `dashed` draws the "nothing happens here" pattern at 0.45
/// alpha; solid uses `color` as-is. No-op for `count < 2`.
FOUNDATION_EXPORT void KKStrokeTimelineCurve(const NSPoint *points,
                                             NSInteger count, CGFloat width,
                                             BOOL dashed, NSColor *color);

NS_ASSUME_NONNULL_END
