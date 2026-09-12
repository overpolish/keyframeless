/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
@import MotionTiming;

// One host key stores both components; native key times remain authoritative.
@interface MMCombinedPose : NSObject <NSSecureCoding, NSCopying, FxCustomParameterInterpolation_v2>
@property(nonatomic, readonly) double positionX;
@property(nonatomic, readonly) double positionY;
@property(nonatomic, readonly) double scale;
@property(nonatomic, readonly) BOOL authored;
@property(nonatomic, readonly) MTEasing easing;
@property(nonatomic, readonly) MTAddedMotion addedMotion;
- (instancetype)initWithPositionX:(double)x scale:(double)scale authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)addedMotion;
- (instancetype)initWithPositionX:(double)x positionY:(double)y scale:(double)scale authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)addedMotion;
- (instancetype)initWithPositionX:(double)x positionY:(double)y scale:(double)scale authored:(BOOL)authored easing:(MTEasing)easing;
- (instancetype)initWithPositionX:(double)x positionY:(double)y scale:(double)scale authored:(BOOL)authored;
- (instancetype)initWithPositionX:(double)x scale:(double)scale authored:(BOOL)authored easing:(MTEasing)easing;
- (instancetype)initWithPositionX:(double)x scale:(double)scale authored:(BOOL)authored;
@end

// Uses MotionTiming rather than host curve weights for rendered/interactively shown values.
// An untouched, unkeyed combined parameter leaves the existing scalar model active.
MMCombinedPose *MMReadCombinedPose(id<PROAPIAccessing> manager, CMTime time,
                                 BOOL *active, NSError **error);

// Inspector cache is disposable and shared through a transient host token, never
// serialized into poses. All key enumeration stays in host callbacks/rendering.
@interface MMCombinedPoseCache : NSObject
@property(nonatomic, readonly) NSString *token;
- (MMCombinedPose *)sampleAtTime:(CMTime)time;
- (BOOL)valueTargetAtTime:(CMTime)time targetTime:(CMTime *)target;
- (MMCombinedPose *)poseForEditingAtTime:(CMTime)time latestValue:(MMCombinedPose *)latest;
@end
MMCombinedPoseCache *MMCreateCombinedPoseCache(void);
void MMRefreshCombinedPoseCache(id<PROAPIAccessing> manager, CMTime time);
MMCombinedPose *MMReadCombinedValue(id<PROAPIAccessing> manager, CMTime time);

BOOL MMCombinedIncomingEasing(id<PROAPIAccessing> manager, CMTime time, int *easing, CMTime *targetTime);

BOOL MMWriteCombinedComponent(id<PROAPIAccessing> manager, MMCombinedPoseCache *cache,
                              UInt32 component, double value, CMTime time);

BOOL MMCombinedOutgoingMotion(id<PROAPIAccessing> manager, CMTime time, int *motion, CMTime *targetTime);

// Reads one native snapshot, then evaluates all shutter times without host reads.
NSArray<MMCombinedPose *> *MMReadCombinedPoseSamples(id<PROAPIAccessing> manager,
    NSArray<NSValue *> *times, BOOL *active, NSError **error);
