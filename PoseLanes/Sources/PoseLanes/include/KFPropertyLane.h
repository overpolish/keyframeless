/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
#import "KFPoseTiming.h"
@import MotionTiming;
@protocol KFPropertyPose <NSObject, NSSecureCoding, NSCopying, FxCustomParameterInterpolation_v2>
@property(nonatomic, readonly) NSArray<NSNumber *> *values;
@property(nonatomic, readonly) double value; // First component for scalar clients.
@property(nonatomic, readonly) BOOL authored;
@property(nonatomic, readonly) MTEasing easing;
@property(nonatomic, readonly) MTAddedMotion addedMotion;
@property(nonatomic, readonly) KFPoseTiming *timing;
- (id<KFPropertyPose>)poseByReplacingValues:(NSArray<NSNumber *> *)values authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion timing:(KFPoseTiming *)timing;
@end
@interface KFPropertyPoseCache : NSObject
@property(nonatomic, readonly) NSString *token;
- (NSArray<NSDictionary *> *)snapshotEntries;
- (void)publishEntries:(NSArray<NSDictionary *> *)entries;
// Replace the disposable snapshot after a successful whole-parameter reset.
- (void)publishConstantPose:(id<KFPropertyPose>)pose;
- (void)publishPose:(id<KFPropertyPose>)pose atTime:(CMTime)time inSnapshot:(NSArray<NSDictionary *> *)snapshot;
@end

// Immutable host adapter configuration. Each inspector owns its own disposable
// cache, while rendering can read this lane with no inspector attached.
@class NSColor;
@interface KFPropertyLane : NSObject
@property(nonatomic, readonly) UInt32 parameterID;
@property(nonatomic, readonly) UInt32 cacheTokenID;
// Lane-wide Match In/Out toggle; the setting never rides in a pose payload.
@property(nonatomic, readonly) UInt32 matchToggleID;
// Nonzero when the lane couples its components, as Scale does.
@property(nonatomic, readonly) UInt32 proportionalToggleID;
@property(nonatomic, readonly, copy) NSString *displayName;
// One colour per component, shared by inspector rows and the timing graph.
@property(nonatomic, readonly, copy) NSArray<NSColor *> *componentColors;
@property(nonatomic, readonly) double defaultValue;
@property(nonatomic, readonly) double minimum;
@property(nonatomic, readonly) double maximum;
@property(nonatomic, readonly) id<KFPropertyPose> defaultPose;
@property(nonatomic, readonly) BOOL boundsValues;
// Values are a percentage of the image, so editors show them in pixels.
@property(nonatomic, readonly) BOOL percentOfImage;
@property(nonatomic, readonly) NSUInteger componentCount;
// Row presentation: one label per component, a shared unit suffix and the
// precision the fields show.
@property(nonatomic, readonly, copy) NSArray<NSString *> *componentLabels;
@property(nonatomic, readonly, copy) NSString *unitSuffix;
@property(nonatomic, readonly) NSUInteger fractionDigits;
// The on-screen control this property owns, or zero when it has none. Its row
// menu offers the visibility toggle.
@property(nonatomic, readonly) UInt32 visibilityToggleID;
- (instancetype)initWithParameterID:(UInt32)parameterID
                        displayName:(NSString *)displayName
                       cacheTokenID:(UInt32)cacheTokenID
                      matchToggleID:(UInt32)matchToggleID
               proportionalToggleID:(UInt32)proportionalToggleID
                 visibilityToggleID:(UInt32)visibilityToggleID
                    componentColors:(NSArray<NSColor *> *)componentColors
                    componentLabels:(NSArray<NSString *> *)componentLabels
                         unitSuffix:(NSString *)unitSuffix
                     fractionDigits:(NSUInteger)fractionDigits
                        defaultPose:(id<KFPropertyPose>)pose
                            minimum:(double)minimum
                            maximum:(double)maximum
                       boundsValues:(BOOL)boundsValues
                     percentOfImage:(BOOL)percentOfImage;
- (KFPropertyPoseCache *)createCache;
- (KFPropertyPoseCache *)cacheForManager:(id<PROAPIAccessing>)manager;
- (void)refreshCacheForManager:(id<PROAPIAccessing>)manager time:(CMTime)time;
- (id<KFPropertyPose>)readValue:(id<PROAPIAccessing>)manager time:(CMTime)time;
- (id<KFPropertyPose>)sampleEntries:(NSArray<NSDictionary *> *)entries time:(CMTime)time;
- (NSArray<id<KFPropertyPose>> *)readSamples:(id<PROAPIAccessing>)manager times:(NSArray<NSValue *> *)times error:(NSError **)error;
- (BOOL)writeComponent:(NSUInteger)component value:(double)value manager:(id<PROAPIAccessing>)manager cache:(KFPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit;
// Replaces every component in one host write, for editors that drive the whole
// pose at once, such as the viewer's rotation rings.
- (BOOL)writeValues:(NSArray<NSNumber *> *)values manager:(id<PROAPIAccessing>)manager cache:(KFPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit;
- (BOOL)writeValue:(double)value manager:(id<PROAPIAccessing>)manager cache:(KFPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit;
@end

// Process-global lane table, in inspector order. The plugin registers it once
// at load; everything else resolves a lane from a parameter ID.
void KFRegisterLanes(NSArray<KFPropertyLane *> *lanes);
NSArray<KFPropertyLane *> *KFPropertyLanes(void);
KFPropertyLane *KFPropertyLaneForParameter(UInt32 parameterID);
// Parameter IDs and display names of the lane table, for menus and registration.
NSArray<NSNumber *> *KFProperties(void);
NSString *KFPropertyDisplayName(UInt32 parameter);
// The hidden toggle that decides whether a value edit creates a keyframe. The
// plugin registers it once at load.
void KFSetExplicitCreationParameter(UInt32 parameterID);
// Reads that toggle inside the caller's host action.
BOOL KFExplicitCreationEnabled(id<PROAPIAccessing> manager, CMTime time, BOOL *explicit);
// The cache an editor should write through: the inspector's registered one
// when a view is attached, otherwise a private snapshot so viewer edits still
// target the right key.
KFPropertyPoseCache *KFPropertyEditingCache(KFPropertyLane *lane, id<PROAPIAccessing> manager, CMTime time);
