/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
#import "MMPoseTiming.h"
@import MotionTiming;
@protocol MMPropertyPose <NSObject, NSSecureCoding, NSCopying, FxCustomParameterInterpolation_v2>
@property(nonatomic, readonly) NSArray<NSNumber *> *values;
@property(nonatomic, readonly) double value; // First component for scalar clients.
@property(nonatomic, readonly) BOOL authored;
@property(nonatomic, readonly) MTEasing easing;
@property(nonatomic, readonly) MTAddedMotion addedMotion;
@property(nonatomic, readonly) MMPoseTiming *timing;
- (id<MMPropertyPose>)poseByReplacingValues:(NSArray<NSNumber *> *)values authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion timing:(MMPoseTiming *)timing;
@end
@interface MMPropertyPoseCache : NSObject
@property(nonatomic, readonly) NSString *token;
- (NSArray<NSDictionary *> *)snapshotEntries;
- (void)publishEntries:(NSArray<NSDictionary *> *)entries;
// Replace the disposable snapshot after a successful whole-parameter reset.
- (void)publishConstantPose:(id<MMPropertyPose>)pose;
- (void)publishPose:(id<MMPropertyPose>)pose atTime:(CMTime)time inSnapshot:(NSArray<NSDictionary *> *)snapshot;
@end

// Immutable host adapter configuration. Each inspector owns its own disposable
// cache, while rendering can read this lane with no inspector attached.
@interface MMPropertyLane : NSObject
@property(nonatomic, readonly) UInt32 parameterID;
@property(nonatomic, readonly) UInt32 cacheTokenID;
@property(nonatomic, readonly) double defaultValue;
@property(nonatomic, readonly) double minimum;
@property(nonatomic, readonly) double maximum;
@property(nonatomic, readonly) id<MMPropertyPose> defaultPose;
@property(nonatomic, readonly) BOOL boundsValues;
@property(nonatomic, readonly) NSUInteger componentCount;
- (instancetype)initWithParameterID:(UInt32)parameterID cacheTokenID:(UInt32)cacheTokenID defaultPose:(id<MMPropertyPose>)pose minimum:(double)minimum maximum:(double)maximum boundsValues:(BOOL)boundsValues;
- (MMPropertyPoseCache *)createCache;
- (MMPropertyPoseCache *)cacheForManager:(id<PROAPIAccessing>)manager;
- (void)refreshCacheForManager:(id<PROAPIAccessing>)manager time:(CMTime)time;
- (id<MMPropertyPose>)readValue:(id<PROAPIAccessing>)manager time:(CMTime)time;
- (id<MMPropertyPose>)sampleEntries:(NSArray<NSDictionary *> *)entries time:(CMTime)time;
- (NSArray<id<MMPropertyPose>> *)readSamples:(id<PROAPIAccessing>)manager times:(NSArray<NSValue *> *)times error:(NSError **)error;
- (BOOL)writeComponent:(NSUInteger)component value:(double)value manager:(id<PROAPIAccessing>)manager cache:(MMPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit;
- (BOOL)writeValue:(double)value manager:(id<PROAPIAccessing>)manager cache:(MMPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit;
@end
