/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "KFPropertyLane.h"

// The keyframed payload of every property: the component values of one keypose
// plus the timing metadata of the transition into it. The lane fixes how many
// components a pose carries; nothing here knows which property it belongs to.
@interface KFPose : NSObject <KFPropertyPose>
@property(nonatomic, readonly) NSArray<NSNumber *> *values;
@property(nonatomic, readonly) double value; // First component, for scalar clients.
@property(nonatomic, readonly) BOOL authored;
@property(nonatomic, readonly) MTEasing easing;
@property(nonatomic, readonly) MTAddedMotion addedMotion;
@property(nonatomic, readonly) KFPoseTiming *timing;
- (instancetype)initWithValues:(NSArray<NSNumber *> *)values
                      authored:(BOOL)authored
                        easing:(MTEasing)easing
                   addedMotion:(MTAddedMotion)motion;
- (KFPose *)poseByReplacingTiming:(KFPoseTiming *)timing;
@end
