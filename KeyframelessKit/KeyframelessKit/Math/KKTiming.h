/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef double (^KKTimingInterpolator)(double t);

@interface KKTimingPhase : NSObject

@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) double duration;
/// Raw normalized value fed to the interpolation block.
/// In: 0→1 as the phase progresses. Out: 1→0 as the phase progresses.
/// Mid: 0→1 through the hold region.
@property(nonatomic, readonly) double progress;
/// Easing block — maps a raw 0→1 value to an eased 0→1 value.
@property(nonatomic, readonly, copy) KKTimingInterpolator interpolate;
/// Convenience: interpolate(progress).
@property(nonatomic, readonly) double factor;

+ (instancetype)phaseWithEnabled:(BOOL)enabled
                        duration:(double)duration
                        progress:(double)progress
                     interpolate:(KKTimingInterpolator)interpolate;

@end

@interface KKTimingResult : NSObject

@property(nonatomic, readonly) KKTimingPhase *inPhase;
@property(nonatomic, readonly) KKTimingPhase *midPhase;
@property(nonatomic, readonly) KKTimingPhase *outPhase;

+ (instancetype)resultWithIn:(KKTimingPhase *)inPhase
                         mid:(KKTimingPhase *)midPhase
                         out:(KKTimingPhase *)outPhase;

@end

NS_ASSUME_NONNULL_END
