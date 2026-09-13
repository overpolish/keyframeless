/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
@import MotionTiming;
#import "MMPoseTiming.h"

// Scale is a separate native key lane. Values are percentages (0...400).
@interface MMScalePose
    : NSObject <NSSecureCoding, NSCopying, FxCustomParameterInterpolation_v2>
@property(nonatomic, readonly) double x;
@property(nonatomic, readonly) double y;
@property(nonatomic, readonly) BOOL authored;
@property(nonatomic, readonly) MMPoseTiming *timing;
- (MMScalePose *)poseByReplacingTiming:(MMPoseTiming *)timing;
@property(nonatomic, readonly) MTEasing easing;
@property(nonatomic, readonly) MTAddedMotion addedMotion;
- (instancetype)initWithX:(double)x y:(double)y authored:(BOOL)authored;
- (instancetype)initWithX:(double)x
                        y:(double)y
                 authored:(BOOL)authored
                   easing:(MTEasing)easing
              addedMotion:(MTAddedMotion)motion;
@end

@interface MMScalePoseCache : NSObject
@property(nonatomic, readonly) NSString *token;
- (NSArray<NSDictionary *> *)snapshotEntries;
- (void)publishEntries:(NSArray<NSDictionary *> *)entries;
// Replace the disposable snapshot after a successful whole-parameter reset.
- (void)publishConstantPose:(MMScalePose *)pose;
// Publish a successful existing-key write without host enumeration. The pre-write
// snapshot can restore an unavailable cache after the successful write.
- (void)publishPose:(MMScalePose *)pose atTime:(CMTime)time
        inSnapshot:(NSArray<NSDictionary *> *)snapshot;
- (MMScalePose *)sampleAtTime:(CMTime)time;
- (BOOL)valueTargetAtTime:(CMTime)time targetTime:(CMTime *)target;
@end

MMScalePoseCache *MMCreateScalePoseCache(void);
void MMRefreshScalePoseCache(id<PROAPIAccessing> manager, CMTime time);
MMScalePose *MMReadScaleValue(id<PROAPIAccessing> manager, CMTime time);
MMScalePose *MMReadScalePose(id<PROAPIAccessing> manager, CMTime time,
                             BOOL *active, NSError **error);
NSArray<MMScalePose *> *MMReadScalePoseSamples(id<PROAPIAccessing> manager,
                                               NSArray<NSValue *> *times,
                                               BOOL *active, NSError **error);
BOOL MMWriteScaleComponent(id<PROAPIAccessing> manager, MMScalePoseCache *cache,
                           UInt32 component, double value, CMTime time);

MMScalePoseCache *MMScaleCacheForManager(id<PROAPIAccessing> manager);

MMScalePose *MMSampleScaleSnapshot(NSArray<NSDictionary *> *entries, CMTime time);
