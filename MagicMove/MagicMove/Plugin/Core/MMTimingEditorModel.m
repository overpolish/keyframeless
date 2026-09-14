/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMDefaults.h"
#import "MMTimingEditorModel.h"
#import "Constants.h"
#import "MMNativeLinks.h"
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
  else
    entries = [[MMPropertyLaneForParameter(parameterID) cacheForManager:manager] snapshotEntries];
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
    } else if (MMPropertyLaneForParameter(gap.parameterID)) {
      id<MMPropertyPose> p=[MMPropertyLaneForParameter(gap.parameterID) sampleEntries:gap.entries time:t];
      if(!p) return @[];
      [points addObject:[NSValue valueWithPoint:NSMakePoint(p.values[0].doubleValue,p.values[p.values.count>1 ? 1:0].doubleValue)]];
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
      setting > MMInspectorResetMotionControls)
    return NO;
  if ((setting == MMInspectorDuration && (value < 0 || value > 60)) ||
      (setting == MMInspectorAmount && (value < 0 || value > 3)) ||
      (setting == MMInspectorSpeed && (value < 0.05 || value > 10)) ||
      (setting == MMInspectorEasing &&
       (value < 0 || value > 3 || floor(value) != value)) ||
      (setting == MMInspectorMotion &&
       (value < 0 || value > 3 || floor(value) != value)))
    return NO;
  if ((setting==MMInspectorMotionSeed || setting==MMInspectorMotionMask) &&
      (value<0 || value>UINT32_MAX || floor(value)!=value)) return NO;
  if (setting==MMInspectorMotionLinked && value!=0 && value!=1) return NO;
  MMInspectorGap *gap = MMReadInspectorGap(manager, parameterID, playhead);
  if (!gap)
    return NO;
  CMTime target =
      setting >= MMInspectorMotion ? gap.sourceTime : gap.destinationTime;
  id old = parameterID == MMCustomControls
               ? (id)MMReadCombinedValue(manager, target)
               : (MMPropertyLaneForParameter(parameterID) ? (id)[MMPropertyLaneForParameter(parameterID) readValue:manager time:target] : MMReadScaleValue(manager, target));
  if (!old)
    return NO;
  MMPoseTiming *timing = [old timing];
  NSMutableDictionary *history=[timing.motionSettings mutableCopy];
  MTAddedMotion previousMotion=[old addedMotion];
  if (previousMotion!=MTAddedMotionNone)
    history[@(previousMotion).stringValue]=@{@"amount":@(timing.amount),@"speed":@(timing.speed)};
  NSDictionary *motionDefault=nil;
  if (setting==MMInspectorMotion && (MTAddedMotion)value!=previousMotion && (MTAddedMotion)value!=MTAddedMotionNone)
    motionDefault=history[@((NSInteger)value).stringValue] ?: MMReadDefault(MMMotionDefaultKey((MTAddedMotion)value));
  if (setting==MMInspectorResetMotionControls)
    motionDefault=MMReadDefault(MMMotionDefaultKey(previousMotion));
  MMPoseTiming *updated = [[MMPoseTiming alloc]
      initWithDuration:setting == MMInspectorDuration ? value : timing.duration
             available:setting == MMInspectorAvailable ? value != 0
                                                       : timing.available
                amount:setting == MMInspectorAmount ? value : motionDefault ? [motionDefault[@"amount"] doubleValue] : timing.amount
                 speed:setting == MMInspectorSpeed ? value : motionDefault ? [motionDefault[@"speed"] doubleValue] : timing.speed];
  updated=[updated timingByReplacingMotionSettings:history];
  updated=[updated timingByReplacingLinkID:timing.linkID];
  updated=[updated timingByReplacingMotionSeed:setting==MMInspectorMotionSeed ? (uint32_t)value : timing.motionSeed
      linked:setting==MMInspectorMotionLinked ? value!=0 : timing.motionLinked
      componentMask:setting==MMInspectorMotionMask ? (uint32_t)value : timing.motionComponentMask];
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
  } else if(MMPropertyLaneForParameter(parameterID)!=nil) {
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
  if(timing.linkID.length && setting<MMInspectorMotionSeed) return MMWriteNativeLinkedPose(manager,parameterID,target,pose);
  id<FxParameterSettingAPI_v5> set =
      [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id cache=parameterID==MMCustomControls ? (id)MMCombinedCacheForManager(manager) : (MMPropertyLaneForParameter(parameterID) ? (id)[MMPropertyLaneForParameter(parameterID) cacheForManager:manager] : MMScaleCacheForManager(manager));
  BOOL written=[set setCustomParameterValue:pose toParameter:parameterID atTime:target];
  if(!written) return NO;
  // Never enumerate native keys inside a UI write action: the host can block
  // until that action ends. Publish the known result instead.
  [cache publishPose:pose atTime:target inSnapshot:gap.entries];
  return YES;
}

NSArray<NSArray<NSNumber *> *> *MMInspectorGraphComponents(MMInspectorGap *gap, NSUInteger count) {
  if(!gap || count<2) return @[];
  if(!MMPropertyLaneForParameter(gap.parameterID)) {
    NSArray *points=MMInspectorGraphSamples(gap,count);
    NSMutableArray *samples=[NSMutableArray arrayWithCapacity:points.count];
    for(NSValue *value in points) {
      NSPoint point=value.pointValue;
      [samples addObject:@[@(point.x),@(point.y)]];
    }
    return samples;
  }
  NSMutableArray *samples=[NSMutableArray arrayWithCapacity:count];
  double start=CMTimeGetSeconds(gap.sourceTime),end=CMTimeGetSeconds(gap.destinationTime);
  for(NSUInteger i=0;i<count;i++) {
    CMTime time=CMTimeMakeWithSeconds(start+(end-start)*i/(count-1),1000000);
    id<MMPropertyPose> pose=[MMPropertyLaneForParameter(gap.parameterID) sampleEntries:gap.entries time:time];
    if(!pose) return @[];
    [samples addObject:pose.values];
  }
  return samples;
}

CMTime MMInspectorGraphStart(NSArray<MMInspectorGap *> *gaps) {
  CMTime start=kCMTimeInvalid;
  for (MMInspectorGap *gap in gaps)
    if (!CMTIME_IS_NUMERIC(start) || CMTimeCompare(gap.sourceTime,start)<0) start=gap.sourceTime;
  return start;
}
NSArray<MMInspectorGap *> *MMReadInspectorGraphGaps(id<PROAPIAccessing> manager, UInt32 parameter, CMTime playhead) {
  MMInspectorGap *selected=MMReadInspectorGap(manager,parameter,playhead);
  // A property's first gap may start later than a linked peer's gap.
  if (!selected && CMTIME_IS_NUMERIC(playhead)) {
    NSArray *entries=parameter==MMCustomControls ? [MMCombinedCacheForManager(manager) snapshotEntries] :
        parameter==MMScaleControls ? [MMScaleCacheForManager(manager) snapshotEntries] :
        [[MMPropertyLaneForParameter(parameter) cacheForManager:manager] snapshotEntries];
    if (entries.count>=2 && entries.firstObject[@"nativeTime"]) {
      CMTime first; [entries.firstObject[@"nativeTime"] getValue:&first];
      if (CMTimeCompare(playhead,first)<0) selected=MMReadInspectorGap(manager,parameter,first);
    }
  }
  if (!selected) return @[];
  NSString *link=[selected.destinationPose timing].linkID;
  NSMutableArray *gaps=[NSMutableArray new];
  for (NSNumber *p in @[@(MMCustomControls),@(MMScaleControls),@(MMRotationControls),@(MMOpacityControls),@(MMBlurControls),@(MMAnchorControls)]) {
    MMInspectorGap *gap=p.unsignedIntValue==parameter ? selected :
        link.length ? MMReadInspectorGap(manager,p.unsignedIntValue,selected.destinationTime) : nil;
    if (!gap || CMTimeCompare(gap.destinationTime,selected.destinationTime)!=0) continue;
    if (gap==selected || [[gap.destinationPose timing].linkID isEqual:link]) [gaps addObject:gap];
  }
  if (CMTimeCompare(playhead,MMInspectorGraphStart(gaps))<0 || CMTimeCompare(playhead,selected.destinationTime)>0) return @[];
  return gaps;
}
static NSUInteger MMGraphComponentCount(UInt32 parameter) {
  return MMPropertyLaneForParameter(parameter) ? MMPropertyLaneForParameter(parameter).componentCount : 2;
}
NSArray<NSNumber *> *MMInspectorGraphStartFractions(NSArray<MMInspectorGap *> *gaps) {
  NSMutableArray *starts=[NSMutableArray new];
  double start=CMTimeGetSeconds(MMInspectorGraphStart(gaps));
  double end=CMTimeGetSeconds(gaps.firstObject.destinationTime);
  for (MMInspectorGap *gap in gaps)
    for (NSUInteger axis=0;axis<MMGraphComponentCount(gap.parameterID);axis++)
      [starts addObject:@((CMTimeGetSeconds(gap.sourceTime)-start)/(end-start))];
  return starts;
}
NSArray<NSArray<NSNumber *> *> *MMInspectorCombinedGraphPoints(NSArray<MMInspectorGap *> *gaps, NSUInteger count, CGSize imageSize) {
  if (!gaps.count || count<2) return @[];
  NSMutableArray<NSMutableArray *> *output=[NSMutableArray new];
  for (NSUInteger i=0;i<count;i++) [output addObject:[NSMutableArray new]];
  for (MMInspectorGap *gap in gaps) {
    NSArray *samples=MMInspectorGraphComponents(gap,count);
    if (samples.count!=count) return @[];
    NSMutableArray *converted=[NSMutableArray new];
    double low=INFINITY, high=-INFINITY;
    for (NSArray *sample in samples) {
      NSMutableArray *values=[sample mutableCopy];
      if (gap.parameterID==MMCustomControls && imageSize.width>0 && imageSize.height>0) {
        values[0]=@([values[0] doubleValue]*imageSize.width/100);
        values[1]=@([values[1] doubleValue]*imageSize.height/100);
      }
      for (NSNumber *value in values) { low=fmin(low,value.doubleValue); high=fmax(high,value.doubleValue); }
      [converted addObject:values];
    }
    for (NSUInteger i=0;i<count;i++)
      for (NSNumber *value in converted[i])
        [output[i] addObject:gaps.count==1 ? value : @(high-low<1e-6 ? 0.5 : (value.doubleValue-low)/(high-low))];
  }
  return output;
}
