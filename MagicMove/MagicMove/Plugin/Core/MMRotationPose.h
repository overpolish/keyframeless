/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "MMPropertyLane.h"

// Euler angles in degrees. Values remain unwrapped to preserve full turns.
@interface MMRotationPose : NSObject <MMPropertyPose>
@property(nonatomic, readonly) double x;
@property(nonatomic, readonly) double y;
@property(nonatomic, readonly) double z;
@property(nonatomic, readonly) NSArray<NSNumber *> *values;
@property(nonatomic, readonly) double value;
@property(nonatomic, readonly) BOOL authored;
@property(nonatomic, readonly) MTEasing easing;
@property(nonatomic, readonly) MTAddedMotion addedMotion;
@property(nonatomic, readonly) MMPoseTiming *timing;
- (instancetype)initWithX:(double)x y:(double)y z:(double)z authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion;
- (MMRotationPose *)poseByReplacingTiming:(MMPoseTiming *)timing;
@end
MMPropertyLane *MMRotationLane(void);
