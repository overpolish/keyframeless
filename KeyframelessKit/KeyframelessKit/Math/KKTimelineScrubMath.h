/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Ruler-strip scrub band hit test, shared by KKTimelineBasicView and
/// KKTimelineAdvancedView. The band sits immediately above the track top —
/// click anywhere there to jump the playhead. Both views use identical
/// ruler height + gap; this helper bakes them in.
FOUNDATION_EXPORT BOOL KKTimelineScrubBandContainsPoint(NSPoint pt,
                                                        CGFloat trackMinX,
                                                        CGFloat trackMaxX,
                                                        CGFloat trackTopY);

/// Visual scrubber → host-deliverable fraction. FCP can't park its playhead
/// at clipEnd (last frame sits one frame before it), so a right-edge visual
/// must deliver `(clipDur - frameDur) / clipDur` for the seek to land on a
/// real frame. Pass-through if clipDur or frameDur is unset/invalid.
FOUNDATION_EXPORT double
KKTimelineScrubFracDelivered(double visualFrac, double clipDurationSeconds,
                             double frameDurationSeconds);

/// Closest-candidate-in-pixels snap. Returns the snapped frac (or `rawFrac`
/// if none within `pixelTolerance`). `xForFrac` maps frac→x in the same
/// coordinate space as `x`. If `outSnapFrac` is non-NULL, it's written with
/// the chosen candidate (or NAN if none snapped) — callers store this for
/// drawing a guide line / sticky-snap state.
FOUNDATION_EXPORT double KKTimelineSnapFracInPixels(
    CGFloat x, double rawFrac, NSArray<NSNumber *> *candidateFracs,
    CGFloat (^xForFrac)(double frac), CGFloat pixelTolerance,
    double *_Nullable outSnapFrac);

NS_ASSUME_NONNULL_END
