/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
#import "MMPropertyLane.h"
@import MotionTiming;

// Scalar native keypose payload, independent of any one property or UI.
@interface MMScalarPose : NSObject <MMPropertyPose>
@property(nonatomic, readonly) double value;
@property(nonatomic, readonly) NSArray<NSNumber *> *values;
@property(nonatomic, readonly) BOOL authored;
@property(nonatomic, readonly) MTEasing easing;
@property(nonatomic, readonly) MTAddedMotion addedMotion;
@property(nonatomic, readonly) MMPoseTiming *timing;
- (instancetype)initWithValue:(double)value authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion;
- (MMScalarPose *)poseByReplacingTiming:(MMPoseTiming *)timing;
@end

MMPropertyLane *MMOpacityLane(void);
