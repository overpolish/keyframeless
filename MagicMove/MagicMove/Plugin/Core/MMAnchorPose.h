/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "MMPropertyLane.h"

// Anchor displacement from the image centre, in full-resolution pixels.
@interface MMAnchorPose : NSObject <MMPropertyPose>
@property(nonatomic, readonly) double x;
@property(nonatomic, readonly) double y;
@property(nonatomic, readonly) NSArray<NSNumber *> *values;
@property(nonatomic, readonly) double value;
@property(nonatomic, readonly) BOOL authored;
@property(nonatomic, readonly) MTEasing easing;
@property(nonatomic, readonly) MTAddedMotion addedMotion;
@property(nonatomic, readonly) MMPoseTiming *timing;
- (instancetype)initWithX:(double)x y:(double)y authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion;
- (MMAnchorPose *)poseByReplacingTiming:(MMPoseTiming *)timing;
@end
MMPropertyLane *MMAnchorLane(void);
