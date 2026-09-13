/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "MMCombinedPose.h"
#import "MMScalePose.h"
#import "MMScalarPose.h"
#import "MMRotationPose.h"

typedef NS_ENUM(NSInteger, MMInspectorSetting) {
  MMInspectorDuration,
  MMInspectorAvailable,
  MMInspectorEasing,
  MMInspectorMotion,
  MMInspectorAmount,
  MMInspectorSpeed
};
@interface MMInspectorGap : NSObject
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
MMInspectorGap *MMReadInspectorGap(id<PROAPIAccessing> manager,
                                   UInt32 parameterID, CMTime time);
NSArray<NSValue *> *MMInspectorGraphSamples(MMInspectorGap *gap,
                                            NSUInteger count);
// Numeric samples in component order, for graphs with any number of axes.
NSArray<NSArray<NSNumber *> *> *MMInspectorGraphComponents(MMInspectorGap *gap, NSUInteger count);
// Caller brackets the host action and undo. Updates an existing native key
// only.
BOOL MMWriteInspectorSetting(id<PROAPIAccessing> manager, UInt32 parameterID,
                             CMTime playhead, MMInspectorSetting setting,
                             double value);
