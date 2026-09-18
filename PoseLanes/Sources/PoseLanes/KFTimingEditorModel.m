/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFMatchEndpoints.h"
#import "KFCreationDefaults.h"
#import "KFTimingEditorModel.h"
#import "KFNativeLinks.h"
#import <AppKit/AppKit.h>
#import <math.h>
@implementation KFInspectorGap
@end
static KFInspectorGap *KFGapForIndex(NSArray *entries, UInt32 parameterID,
                                     NSUInteger index) {
  KFInspectorGap *gap = [KFInspectorGap new];
  gap.parameterID = parameterID;
  gap.destinationIndex = index;
  CMTime source, destination;
  [entries[index - 1][@"nativeTime"] getValue:&source];
  [entries[index][@"nativeTime"] getValue:&destination];
  gap.sourceTime = source;
  gap.destinationTime = destination;
  gap.sourcePose = entries[index - 1][@"pose"];
  gap.destinationPose = entries[index][@"pose"];
  gap.entries = entries;
  return gap;
}
// A lane whose keys the host has not published yet samples as one unkeyed
// entry, so both reads require a native time on the first entry.
static NSArray *KFKeyedEntries(id<PROAPIAccessing> manager, UInt32 parameterID) {
  NSArray *entries=[[KFPropertyLaneForParameter(parameterID) cacheForManager:manager] snapshotEntries];
  return entries.count >= 2 && entries.firstObject[@"nativeTime"] ? entries : nil;
}
KFInspectorGap *KFReadInspectorGap(id<PROAPIAccessing> manager,
                                   UInt32 parameterID, CMTime time) {
  if (!CMTIME_IS_NUMERIC(time))
    return nil;
  NSArray *entries = KFKeyedEntries(manager, parameterID);
  if (!entries)
    return nil;
  double now = CMTimeGetSeconds(time);
  if (now < [entries.firstObject[@"time"] doubleValue] - 1e-6 ||
      now > [entries.lastObject[@"time"] doubleValue] + 1e-6)
    return nil;
  for (NSUInteger i = 1; i < entries.count; i++) {
    if (now > [entries[i][@"time"] doubleValue] + 1e-6)
      continue;
    return KFGapForIndex(entries, parameterID, i);
  }
  return nil;
}
NSArray<KFInspectorGap *> *KFReadInspectorLaneGaps(id<PROAPIAccessing> manager,
                                                   UInt32 parameterID) {
  NSArray *entries = KFKeyedEntries(manager, parameterID);
  if (!entries)
    return @[];
  NSMutableArray *gaps = [NSMutableArray arrayWithCapacity:entries.count - 1];
  for (NSUInteger i = 1; i < entries.count; i++)
    [gaps addObject:KFGapForIndex(entries, parameterID, i)];
  return gaps;
}
// Two-component view of a gap, for the graph's paired plot.
NSArray<NSValue *> *KFInspectorGraphSamples(KFInspectorGap *gap, NSUInteger count) {
  if (!gap || count < 2)
    return @[];
  KFPropertyLane *lane=KFPropertyLaneForParameter(gap.parameterID);
  if (!lane) return @[];
  NSMutableArray *points = [NSMutableArray arrayWithCapacity:count];
  double start = CMTimeGetSeconds(gap.sourceTime),
         end = CMTimeGetSeconds(gap.destinationTime);
  for (NSUInteger i = 0; i < count; i++) {
    CMTime t =
        CMTimeMakeWithSeconds(start + (end - start) * i / (count - 1), 1000000);
    id<KFPropertyPose> pose=[lane sampleEntries:gap.entries time:t];
    if (!pose) return @[];
    NSArray<NSNumber *> *values=pose.values;
    [points addObject:[NSValue valueWithPoint:NSMakePoint(values[0].doubleValue,
                                                          values[values.count>1 ? 1:0].doubleValue)]];
  }
  return points;
}
BOOL KFWriteInspectorSetting(id<PROAPIAccessing> manager, UInt32 parameterID,
                             CMTime playhead, KFInspectorSetting setting,
                             double value) {
  if (!isfinite(value) || setting < KFInspectorDuration ||
      setting > KFInspectorResetMotionControls)
    return NO;
  if ((setting == KFInspectorDuration && (value < 0 || value > 60)) ||
      (setting == KFInspectorAmount && (value < 0 || value > 3)) ||
      (setting == KFInspectorSpeed && (value < 0.05 || value > 10)) ||
      (setting == KFInspectorEasing &&
       (value < 0 || value > 3 || floor(value) != value)) ||
      (setting == KFInspectorMotion &&
       (value < 0 || value > 3 || floor(value) != value)))
    return NO;
  if ((setting==KFInspectorMotionSeed || setting==KFInspectorMotionMask) &&
      (value<0 || value>UINT32_MAX || floor(value)!=value)) return NO;
  if (setting==KFInspectorMotionLinked && value!=0 && value!=1) return NO;
  KFInspectorGap *gap = KFReadInspectorGap(manager, parameterID, playhead);
  if (!gap)
    return NO;
  CMTime target =
      setting >= KFInspectorMotion ? gap.sourceTime : gap.destinationTime;
  id old = (id)[KFPropertyLaneForParameter(parameterID) readValue:manager time:target];
  if (!old)
    return NO;
  KFPoseTiming *timing = [old timing];
  NSMutableDictionary *history=[timing.motionSettings mutableCopy];
  MTAddedMotion previousMotion=[old addedMotion];
  if (previousMotion!=MTAddedMotionNone)
    history[@(previousMotion).stringValue]=@{@"amount":@(timing.amount),@"speed":@(timing.speed)};
  NSDictionary *motionDefault=nil;
  if (setting==KFInspectorMotion && (MTAddedMotion)value!=previousMotion && (MTAddedMotion)value!=MTAddedMotionNone)
    motionDefault=history[@((NSInteger)value).stringValue] ?: KFReadDefault(KFMotionDefaultKey((MTAddedMotion)value));
  if (setting==KFInspectorResetMotionControls)
    motionDefault=KFReadDefault(KFMotionDefaultKey(previousMotion));
  KFPoseTiming *updated = [[KFPoseTiming alloc]
      initWithDuration:setting == KFInspectorDuration ? value : timing.duration
             available:setting == KFInspectorAvailable ? value != 0
                                                       : timing.available
                amount:setting == KFInspectorAmount ? value : motionDefault ? [motionDefault[@"amount"] doubleValue] : timing.amount
                 speed:setting == KFInspectorSpeed ? value : motionDefault ? [motionDefault[@"speed"] doubleValue] : timing.speed];
  updated=[updated timingByReplacingMotionSettings:history];
  updated=[updated timingByReplacingLinkID:timing.linkID];
  updated=[updated timingByReplacingMotionSeed:setting==KFInspectorMotionSeed ? (uint32_t)value : timing.motionSeed
      linked:setting==KFInspectorMotionLinked ? value!=0 : timing.motionLinked
      componentMask:setting==KFInspectorMotionMask ? (uint32_t)value : timing.motionComponentMask];
  MTEasing easing =
      setting == KFInspectorEasing ? (MTEasing)value : [old easing];
  MTAddedMotion motion =
      setting == KFInspectorMotion ? (MTAddedMotion)value : [old addedMotion];
  id<KFPropertyPose> previous=old;
  id pose=[previous poseByReplacingValues:previous.values authored:previous.authored
      easing:easing addedMotion:motion timing:updated];
  BOOL transition = setting==KFInspectorDuration || setting==KFInspectorAvailable || setting==KFInspectorEasing;
  if((timing.linkID.length && setting<KFInspectorMotionSeed) ||
     (transition && KFMirrorsTimingEdit(manager,parameterID,target)))
    return KFWriteNativeLinkedPose(manager,parameterID,target,pose);
  id<FxParameterSettingAPI_v5> set =
      [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  KFPropertyPoseCache *cache=[KFPropertyLaneForParameter(parameterID) cacheForManager:manager];
  BOOL written=[set setCustomParameterValue:pose toParameter:parameterID atTime:target];
  if(!written) return NO;
  // Never enumerate native keys inside a UI write action: the host can block
  // until that action ends. Publish the known result instead.
  [cache publishPose:pose atTime:target inSnapshot:gap.entries];
  return YES;
}

NSArray<NSArray<NSNumber *> *> *KFInspectorGraphComponents(KFInspectorGap *gap, NSUInteger count) {
  if(!gap || count<2 || !KFPropertyLaneForParameter(gap.parameterID)) return @[];
  NSMutableArray *samples=[NSMutableArray arrayWithCapacity:count];
  double start=CMTimeGetSeconds(gap.sourceTime),end=CMTimeGetSeconds(gap.destinationTime);
  for(NSUInteger i=0;i<count;i++) {
    CMTime time=CMTimeMakeWithSeconds(start+(end-start)*i/(count-1),1000000);
    id<KFPropertyPose> pose=[KFPropertyLaneForParameter(gap.parameterID) sampleEntries:gap.entries time:time];
    if(!pose) return @[];
    [samples addObject:pose.values];
  }
  return samples;
}

CMTime KFInspectorGraphStart(NSArray<KFInspectorGap *> *gaps) {
  CMTime start=kCMTimeInvalid;
  for (KFInspectorGap *gap in gaps)
    if (!CMTIME_IS_NUMERIC(start) || CMTimeCompare(gap.sourceTime,start)<0) start=gap.sourceTime;
  return start;
}
NSArray<KFInspectorGap *> *KFReadInspectorGraphGaps(id<PROAPIAccessing> manager, UInt32 parameter, CMTime playhead) {
  KFInspectorGap *selected=KFReadInspectorGap(manager,parameter,playhead);
  // A property's first gap may start later than a linked peer's gap.
  if (!selected && CMTIME_IS_NUMERIC(playhead)) {
    NSArray *entries=[[KFPropertyLaneForParameter(parameter) cacheForManager:manager] snapshotEntries];
    if (entries.count>=2 && entries.firstObject[@"nativeTime"]) {
      CMTime first; [entries.firstObject[@"nativeTime"] getValue:&first];
      if (CMTimeCompare(playhead,first)<0) selected=KFReadInspectorGap(manager,parameter,first);
    }
  }
  if (!selected) return @[];
  NSString *link=[selected.destinationPose timing].linkID;
  NSMutableArray *gaps=[NSMutableArray new];
  for (NSNumber *p in KFProperties()) {
    KFInspectorGap *gap=p.unsignedIntValue==parameter ? selected :
        link.length ? KFReadInspectorGap(manager,p.unsignedIntValue,selected.destinationTime) : nil;
    if (!gap || CMTimeCompare(gap.destinationTime,selected.destinationTime)!=0) continue;
    if (gap==selected || [[gap.destinationPose timing].linkID isEqual:link]) [gaps addObject:gap];
  }
  if (CMTimeCompare(playhead,KFInspectorGraphStart(gaps))<0 || CMTimeCompare(playhead,selected.destinationTime)>0) return @[];
  return gaps;
}
static NSUInteger KFGraphComponentCount(UInt32 parameter) {
  return KFPropertyLaneForParameter(parameter).componentCount;
}
NSArray<NSNumber *> *KFInspectorGraphStartFractions(NSArray<KFInspectorGap *> *gaps) {
  NSMutableArray *starts=[NSMutableArray new];
  double start=CMTimeGetSeconds(KFInspectorGraphStart(gaps));
  double end=CMTimeGetSeconds(gaps.firstObject.destinationTime);
  for (KFInspectorGap *gap in gaps)
    for (NSUInteger axis=0;axis<KFGraphComponentCount(gap.parameterID);axis++)
      [starts addObject:@((CMTimeGetSeconds(gap.sourceTime)-start)/(end-start))];
  return starts;
}
NSArray<NSArray<NSNumber *> *> *KFInspectorCombinedGraphPoints(NSArray<KFInspectorGap *> *gaps, NSUInteger count, CGSize imageSize) {
  if (!gaps.count || count<2) return @[];
  NSMutableArray<NSMutableArray *> *output=[NSMutableArray new];
  for (NSUInteger i=0;i<count;i++) [output addObject:[NSMutableArray new]];
  for (KFInspectorGap *gap in gaps) {
    NSArray *samples=KFInspectorGraphComponents(gap,count);
    if (samples.count!=count) return @[];
    NSMutableArray *converted=[NSMutableArray new];
    double low=INFINITY, high=-INFINITY;
    for (NSArray *sample in samples) {
      NSMutableArray *values=[sample mutableCopy];
      if (KFPropertyLaneForParameter(gap.parameterID).percentOfImage && imageSize.width>0 && imageSize.height>0) {
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
