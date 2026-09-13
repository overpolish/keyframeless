/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMTimingEditorModel.h"
#import "Constants.h"
#import <AppKit/AppKit.h>
#import <math.h>
@implementation MMInspectorGap
@end
MMInspectorGap *MMReadInspectorGap(id<PROAPIAccessing> manager,
                                   UInt32 parameterID, CMTime time) {
  if (!CMTIME_IS_NUMERIC(time))
    return nil;
  NSArray *entries;
  if (parameterID == MMCustomControls)
    entries = [MMCombinedCacheForManager(manager) snapshotEntries];
  else if (parameterID == MMScaleControls)
    entries = [MMScaleCacheForManager(manager) snapshotEntries];
  else if (parameterID == MMRotationControls)
    entries = [[MMRotationLane() cacheForManager:manager] snapshotEntries];
  else if (parameterID == MMOpacityControls)
    entries = [[MMOpacityLane() cacheForManager:manager] snapshotEntries];
  else
    return nil;
  if (entries.count < 2 || !entries.firstObject[@"nativeTime"])
    return nil;
  double now = CMTimeGetSeconds(time);
  if (now < [entries.firstObject[@"time"] doubleValue] - 1e-6 ||
      now > [entries.lastObject[@"time"] doubleValue] + 1e-6)
    return nil;
  for (NSUInteger i = 1; i < entries.count; i++) {
    if (now > [entries[i][@"time"] doubleValue] + 1e-6)
      continue;
    MMInspectorGap *gap = [MMInspectorGap new];
    gap.parameterID = parameterID;
    gap.destinationIndex = i;
    CMTime source, destination;
    [entries[i - 1][@"nativeTime"] getValue:&source];
    [entries[i][@"nativeTime"] getValue:&destination];
    gap.sourceTime = source;
    gap.destinationTime = destination;
    gap.sourcePose = entries[i - 1][@"pose"];
    gap.destinationPose = entries[i][@"pose"];
    gap.entries = entries;
    return gap;
  }
  return nil;
}
NSArray<NSValue *> *MMInspectorGraphSamples(MMInspectorGap *gap,
                                            NSUInteger count) {
  if (!gap || count < 2)
    return @[];
  NSMutableArray *points = [NSMutableArray arrayWithCapacity:count];
  double start = CMTimeGetSeconds(gap.sourceTime),
         end = CMTimeGetSeconds(gap.destinationTime);
  for (NSUInteger i = 0; i < count; i++) {
    CMTime t =
        CMTimeMakeWithSeconds(start + (end - start) * i / (count - 1), 1000000);
    if (gap.parameterID == MMCustomControls) {
      MMCombinedPose *p = MMSampleCombinedSnapshot(gap.entries, t);
      if (!p)
        return @[];
      [points addObject:[NSValue valueWithPoint:NSMakePoint(p.positionX,
                                                            p.positionY)]];
    } else if (gap.parameterID == MMOpacityControls) {
      MMScalarPose *p=[MMOpacityLane() sampleEntries:gap.entries time:t];
      if(!p) return @[];
      [points addObject:[NSValue valueWithPoint:NSMakePoint(p.value,p.value)]];
    } else if(gap.parameterID == MMRotationControls) {
      id<MMPropertyPose> p=[MMRotationLane() sampleEntries:gap.entries time:t];
      if(!p) return @[];
      [points addObject:[NSValue valueWithPoint:NSMakePoint(p.values[0].doubleValue,p.values[1].doubleValue)]];
    } else {
      MMScalePose *p = MMSampleScaleSnapshot(gap.entries, t);
      if (!p)
        return @[];
      [points addObject:[NSValue valueWithPoint:NSMakePoint(p.x, p.y)]];
    }
  }
  return points;
}
BOOL MMWriteInspectorSetting(id<PROAPIAccessing> manager, UInt32 parameterID,
                             CMTime playhead, MMInspectorSetting setting,
                             double value) {
  if (!isfinite(value) || setting < MMInspectorDuration ||
      setting > MMInspectorSpeed)
    return NO;
  if ((setting == MMInspectorDuration && (value < 0 || value > 60)) ||
      (setting == MMInspectorAmount && (value < 0 || value > 3)) ||
      (setting == MMInspectorSpeed && (value < 0.05 || value > 10)) ||
      (setting == MMInspectorEasing &&
       (value < 0 || value > 3 || floor(value) != value)) ||
      (setting == MMInspectorMotion &&
       (value < 0 || value > 3 || floor(value) != value)))
    return NO;
  MMInspectorGap *gap = MMReadInspectorGap(manager, parameterID, playhead);
  if (!gap)
    return NO;
  CMTime target =
      setting >= MMInspectorMotion ? gap.sourceTime : gap.destinationTime;
  id old = parameterID == MMCustomControls
               ? (id)MMReadCombinedValue(manager, target)
               : (parameterID == MMRotationControls ? (id)[MMRotationLane() readValue:manager time:target] : (parameterID == MMOpacityControls ? (id)[MMOpacityLane() readValue:manager time:target] : MMReadScaleValue(manager, target)));
  if (!old)
    return NO;
  MMPoseTiming *timing = [old timing];
  MMPoseTiming *updated = [[MMPoseTiming alloc]
      initWithDuration:setting == MMInspectorDuration ? value : timing.duration
             available:setting == MMInspectorAvailable ? value != 0
                                                       : timing.available
                amount:setting == MMInspectorAmount ? value : timing.amount
                 speed:setting == MMInspectorSpeed ? value : timing.speed];
  MTEasing easing =
      setting == MMInspectorEasing ? (MTEasing)value : [old easing];
  MTAddedMotion motion =
      setting == MMInspectorMotion ? (MTAddedMotion)value : [old addedMotion];
  id pose;
  if (parameterID == MMCustomControls) {
    MMCombinedPose *p = old;
    pose = [[[MMCombinedPose alloc] initWithPositionX:p.positionX
                                            positionY:p.positionY
                                                scale:p.scale
                                             authored:p.authored
                                               easing:easing
                                          addedMotion:motion]
        poseByReplacingTiming:updated];
  } else if(parameterID == MMOpacityControls || parameterID == MMRotationControls) {
    id<MMPropertyPose> p=old;
    pose=[p poseByReplacingValues:p.values authored:p.authored easing:easing addedMotion:motion timing:updated];
  } else {
    MMScalePose *p = old;
    pose =
        [[[MMScalePose alloc] initWithX:p.x
                                      y:p.y
                               authored:p.authored
                                 easing:easing
                            addedMotion:motion] poseByReplacingTiming:updated];
  }
  id<FxParameterSettingAPI_v5> set =
      [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id cache=parameterID==MMCustomControls ? (id)MMCombinedCacheForManager(manager) : (parameterID==MMRotationControls ? (id)[MMRotationLane() cacheForManager:manager] : (parameterID==MMOpacityControls ? (id)[MMOpacityLane() cacheForManager:manager] : MMScaleCacheForManager(manager)));
  BOOL written=[set setCustomParameterValue:pose toParameter:parameterID atTime:target];
  if(!written) return NO;
  // Never enumerate native keys inside a UI write action: the host can block
  // until that action ends. Publish the known result, as Scale value edits do.
  [cache publishPose:pose atTime:target inSnapshot:gap.entries];
  return YES;
}

NSArray<NSArray<NSNumber *> *> *MMInspectorGraphComponents(MMInspectorGap *gap, NSUInteger count) {
  if(!gap || count<2) return @[];
  if(gap.parameterID!=MMRotationControls) {
    NSArray *points=MMInspectorGraphSamples(gap,count);
    NSMutableArray *samples=[NSMutableArray arrayWithCapacity:points.count];
    for(NSValue *value in points) {
      NSPoint point=value.pointValue;
      [samples addObject:gap.parameterID==MMOpacityControls ? @[@(point.x)] : @[@(point.x),@(point.y)]];
    }
    return samples;
  }
  NSMutableArray *samples=[NSMutableArray arrayWithCapacity:count];
  double start=CMTimeGetSeconds(gap.sourceTime),end=CMTimeGetSeconds(gap.destinationTime);
  for(NSUInteger i=0;i<count;i++) {
    CMTime time=CMTimeMakeWithSeconds(start+(end-start)*i/(count-1),1000000);
    id<MMPropertyPose> pose=[MMRotationLane() sampleEntries:gap.entries time:time];
    if(!pose) return @[];
    [samples addObject:pose.values];
  }
  return samples;
}
