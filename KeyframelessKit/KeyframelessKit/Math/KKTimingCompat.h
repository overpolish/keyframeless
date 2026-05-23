/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

/// YES iff `timeline` can be losslessly represented in Basic mode — i.e.
/// there exist consistent boundary times (t_inEnd, t_outStart) such that
/// every animatable lane's keypose times are a subset of
/// `{0, t_inEnd, t_outStart, 1}`, and the Hold interval (between t_inEnd
/// and t_outStart, when both are present) has equal endpoint values.
/// Lanes with only `{0}`, `{1}`, or `{0,1}` are trivially compatible.
/// In/Out interval curves are unconstrained (any single curve is fine);
/// modulation on any interval is allowed.
FOUNDATION_EXPORT BOOL KKTimelineIsBasicCompatible(KKTimeline *timeline);

/// Collapse any Basic-incompatible lane in `timeline` to a flat hold at the
/// lane's evaluated value at t=0.5, placed at `[0, endFrac]`. `endFrac`
/// should be Basic's `outEndFrac` (clip-frame-aligned, typically
/// `(clipDur - frameDur)/clipDur`) so the reseeded layout matches what
/// Basic would otherwise produce on its own; pass 1.0 when the host
/// doesn't have a frame-aligned end yet.
FOUNDATION_EXPORT KKTimeline *KKTimelineReseedToBasic(KKTimeline *timeline,
                                                      double endFrac);

NS_ASSUME_NONNULL_END
