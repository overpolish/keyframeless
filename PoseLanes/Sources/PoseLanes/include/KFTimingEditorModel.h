/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "KFPose.h"

typedef NS_ENUM(NSInteger, KFInspectorSetting) {
  KFInspectorDuration,
  KFInspectorAvailable,
  KFInspectorEasing,
  KFInspectorMotion,
  KFInspectorAmount,
  KFInspectorSpeed,
  KFInspectorMotionSeed,
  KFInspectorMotionLinked,
  KFInspectorMotionMask,
  KFInspectorResetMotionControls
};
@interface KFInspectorGap : NSObject
@property UInt32 parameterID;
@property NSUInteger destinationIndex;
@property CMTime sourceTime;
@property CMTime destinationTime;
@property(nonatomic, strong) id sourcePose;
@property(nonatomic, strong) id destinationPose;
@property(nonatomic, copy) NSArray<NSDictionary *> *entries;
@end
// Exact arrivals show the gap that just completed. Outside the sequence there
// is no editable gap. These functions only read the disposable inspector cache.
KFInspectorGap *KFReadInspectorGap(id<PROAPIAccessing> manager,
                                   UInt32 parameterID, CMTime time);
NSArray<NSValue *> *KFInspectorGraphSamples(KFInspectorGap *gap,
                                            NSUInteger count);
// Numeric samples in component order, for graphs with any number of axes.
NSArray<NSArray<NSNumber *> *> *KFInspectorGraphComponents(KFInspectorGap *gap, NSUInteger count);
// Caller brackets the host action and undo. Updates an existing native key
// only.
BOOL KFWriteInspectorSetting(id<PROAPIAccessing> manager, UInt32 parameterID,
                             CMTime playhead, KFInspectorSetting setting,
                             double value);

// Incoming gaps sharing the selected destination's link, using cached poses only.
NSArray<KFInspectorGap *> *KFReadInspectorGraphGaps(id<PROAPIAccessing> manager, UInt32 parameter, CMTime playhead);
CMTime KFInspectorGraphStart(NSArray<KFInspectorGap *> *gaps);
NSArray<NSNumber *> *KFInspectorGraphStartFractions(NSArray<KFInspectorGap *> *gaps);
NSArray<NSArray<NSNumber *> *> *KFInspectorCombinedGraphPoints(NSArray<KFInspectorGap *> *gaps, NSUInteger count, CGSize imageSize);
