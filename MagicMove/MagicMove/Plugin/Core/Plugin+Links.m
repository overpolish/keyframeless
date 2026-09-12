/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Plugin_Private.h"
#import "Constants.h"
#import "MMDestinations.h"
#import <math.h>

// Native key metadata and scalar values are separate in FxPlug. Keep both
// when moving a partner, including enough information to restore a failed edit.
@interface MMLinkPose : NSObject
@property(nonatomic) FxKeyframe key;
@property(nonatomic) MTDurationRecord record;
@property(nonatomic) double originalTime;
@property(nonatomic) BOOL isNew;
@end
@implementation MMLinkPose
@end

// Captured entirely in the native callback. Release applies this snapshot
// without querying the host's native keyframe list again.
@interface MMLinkEdit : NSObject
@property MMTimingLane *lane;
@property MMTimingLane *partner;
@property NSData *saved;
@property NSData *partnerSaved;
@property NSData *data;
@property NSData *partnerData;
@property NSArray<MMLinkPose *> *before;
@property NSArray<MMLinkPose *> *after;
@property NSArray<MMLinkPose *> *sourceBefore;
@property NSArray<MMLinkPose *> *sourceAfter;
@end
@implementation MMLinkEdit
@end

static BOOL MMLinkError(NSError **error, NSString *message) {
  if (error) *error = [NSError errorWithDomain:FxPlugErrorDomain code:kFxError_InvalidParameter
                                     userInfo:@{NSLocalizedDescriptionKey:message}];
  return NO;
}
static BOOL MMSameTime(double a, double b) { return fabs(a-b) < 1e-6; }
static uint64_t MMNewLinkID(void) {
  uint64_t value;
  do { arc4random_buf(&value, sizeof(value)); } while (!value);
  return value;
}
static MMLinkPose *MMPoseAtTime(NSArray<MMLinkPose *> *poses, double time) {
  for (MMLinkPose *pose in poses) if (MMSameTime(pose.record.time, time)) return pose;
  return nil;
}
static MMLinkPose *MMPoseWithLink(NSArray<MMLinkPose *> *poses, uint64_t link) {
  if (link) for (MMLinkPose *pose in poses) if (pose.record.linkID == link) return pose;
  return nil;
}
static NSMutableArray<MMLinkPose *> *MMNativePoses(id<PROAPIAccessing> manager,
                                                  UInt32 valueID, NSData *data, NSError **error) {
  id<FxKeyframeAPI_v3> api = [manager apiForProtocol:@protocol(FxKeyframeAPI_v3)];
  if (!api) { MMLinkError(error, @"Host keyframe editing is unavailable"); return nil; }
  const MTDurationRecord *records = data.bytes;
  NSUInteger count = data.length/sizeof(*records);
  NSMutableArray *poses = [NSMutableArray array];
  for (NSUInteger i=0; i<count; ++i) {
    FxKeyframe key;
    FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
    NSError *failure = [api keyframe:&key forParameter:valueID channel:0 andIndex:i];
    if (failure) { if (error) *error = failure; return nil; }
    // The adapter sorts records; associate metadata by time, not host index.
    NSUInteger match = NSNotFound;
    for (NSUInteger j=0; j<count; ++j)
      if (MMSameTime(records[j].time, CMTimeGetSeconds(key.time))) { match = j; break; }
    if (match == NSNotFound) { MMLinkError(error, @"Keys changed while preparing a linked edit"); return nil; }
    MMLinkPose *pose = [MMLinkPose new];
    pose.key = key; pose.record = records[match]; pose.originalTime = records[match].time;
    [poses addObject:pose];
  }
  return poses;
}
static NSData *MMRecordsFromPoses(NSArray<MMLinkPose *> *poses) {
  NSArray *ordered = [poses sortedArrayUsingComparator:^NSComparisonResult(MMLinkPose *a, MMLinkPose *b) {
    return a.record.time < b.record.time ? NSOrderedAscending :
           a.record.time > b.record.time ? NSOrderedDescending : NSOrderedSame;
  }];
  NSMutableData *data = [NSMutableData dataWithLength:ordered.count*sizeof(MTDurationRecord)];
  MTDurationRecord *records = data.mutableBytes;
  for (NSUInteger i=0; i<ordered.count; ++i) records[i] = ((MMLinkPose *)ordered[i]).record;
  return data;
}
static NSMutableArray<MMLinkPose *> *MMCopyPoses(NSArray<MMLinkPose *> *poses) {
  NSMutableArray *result = [NSMutableArray array];
  for (MMLinkPose *old in poses) {
    MMLinkPose *copy = [MMLinkPose new];
    copy.key = old.key; copy.record = old.record; copy.originalTime = old.originalTime; copy.isNew = old.isNew;
    [result addObject:copy];
  }
  return result;
}
static void MMSortPoses(NSMutableArray<MMLinkPose *> *poses) {
  [poses sortUsingComparator:^NSComparisonResult(MMLinkPose *a, MMLinkPose *b) {
    return a.record.time < b.record.time ? NSOrderedAscending : a.record.time > b.record.time ? NSOrderedDescending : NSOrderedSame;
  }];
}
static BOOL MMMatchEndpoints(id<PROAPIAccessing> manager, MMTimingLane *lane,
                             NSMutableArray<MMLinkPose *> *poses, NSData *saved,
                             UInt32 parameterID, CMTime time, NSError **error) {
  MMSortPoses(poses);
  if (!poses.count) return YES;
  BOOL matchEdit = parameterID == lane.matchEditorID;
  BOOL matchIn = poses.count > 1 && MMSameTime(poses.lastObject.record.time, CMTimeGetSeconds(time));
  BOOL enabled = poses.firstObject.record.matchEndpoints;
  if (matchEdit) {
    MMLinkPose *selected = matchIn ? poses.lastObject : poses.firstObject;
    if (!MMSameTime(selected.record.time, CMTimeGetSeconds(time))) return YES;
    id<FxParameterRetrievalAPI_v6> get = [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if (![get getBoolValue:&enabled fromParameter:parameterID atTime:time]) return NO;
  }
  if (enabled && matchEdit && poses.count == 1) {
    id<FxTimingAPI_v4> timing = [manager apiForProtocol:@protocol(FxTimingAPI_v4)];
    if (!timing) return MMLinkError(error, @"Effect timing is unavailable for creating the matching endpoint");
    CMTime start = kCMTimeInvalid, duration = kCMTimeInvalid, frame = kCMTimeInvalid;
    [timing startTimeForEffect:&start]; [timing durationTimeForEffect:&duration]; [timing frameDuration:&frame];
    if (!CMTIME_IS_NUMERIC(start) || !CMTIME_IS_NUMERIC(duration) || !CMTIME_IS_NUMERIC(frame) ||
        CMTimeCompare(frame, kCMTimeZero) <= 0 || CMTimeCompare(duration, frame) < 0)
      return MMLinkError(error, @"Effect timing cannot provide a distinct matching endpoint");
    CMTime end = CMTimeSubtract(CMTimeAdd(start, duration), frame);
    // A sole pose has no intrinsic In/Out role. Default to creating Out;
    // a pose already on the last frame instead creates its matching In.
    matchIn = MMSameTime(CMTimeGetSeconds(end), poses.firstObject.record.time);
    CMTime boundary = matchIn ? start : end;
    if ((matchIn && CMTimeCompare(boundary, poses.firstObject.key.time) >= 0) ||
        (!matchIn && CMTimeCompare(boundary, poses.firstObject.key.time) <= 0))
      return MMLinkError(error, @"There is no room for a matching endpoint in that direction");
    MMLinkPose *newPose = [MMLinkPose new];
    FxKeyframe key; FxInitKeyframe(key, kFxKeyframe_CurrentVersion); key.time = boundary;
    newPose.key = key; newPose.isNew = YES; newPose.originalTime = CMTimeGetSeconds(boundary);
    MTDurationRecord record = poses.firstObject.record;
    record.time = newPose.originalTime; record.linkID = 0; record.previousIndex = SIZE_MAX;
    newPose.record = record; [poses addObject:newPose]; MMSortPoses(poses);
  }
  for (MMLinkPose *pose in poses) { MTDurationRecord r = pose.record; r.matchEndpoints = enabled; pose.record = r; }
  if (!enabled || poses.count < 2) return YES;
  MMLinkPose *first = poses.firstObject, *last = poses.lastObject;
  BOOL useLast = matchEdit && matchIn;
  if (!matchEdit) {
    const MTDurationRecord *old = saved.bytes;
    NSUInteger n = saved.length/sizeof(*old);
    BOOL firstChanged = n && first.record.value != old[0].value;
    BOOL lastChanged = n && last.record.value != old[n-1].value;
    useLast = lastChanged && !firstChanged;
    if (firstChanged && lastChanged) useLast = MMSameTime(last.record.time, CMTimeGetSeconds(time));
  }
  double value = useLast ? last.record.value : first.record.value;
  MTDurationRecord f = first.record, l = last.record; f.value = l.value = value;
  first.record = f; last.record = l;
  if (poses.count >= 3) {
    // A new middle pose inherits the established exit timing. Explicit edits
    // to either incoming edge, or enabling from the first pose, choose that edge.
    MMLinkPose *entry = poses[1];
    BOOL useEntry = (matchEdit && !matchIn) ||
      ((parameterID == lane.durationID || parameterID == lane.availableTimeID || parameterID == lane.easingID) &&
       MMSameTime(entry.record.time, CMTimeGetSeconds(time)));
    MTDurationRecord timing = useEntry ? entry.record : last.record;
    for (MMLinkPose *pose in @[entry,last]) {
      MTDurationRecord r = pose.record; r.duration = timing.duration; r.useAvailableTime = timing.useAvailableTime; r.easing = timing.easing; pose.record = r;
    }
  }
  return YES;
}
// Timing edges form a small graph: native pair links across lanes and the two
// incoming edges of each matched lane. Updating one edge updates its component.
static void MMSpreadTiming(NSArray<MMLinkPose *> *source, NSArray<MMLinkPose *> *partner, MMLinkPose *seed) {
  if (!seed) return;
  NSMutableArray *queue = [NSMutableArray arrayWithObject:seed];
  NSMutableSet *seen = [NSMutableSet set];
  MTDurationRecord timing = seed.record;
  while (queue.count) {
    MMLinkPose *pose = queue.lastObject; [queue removeLastObject];
    if ([seen containsObject:pose]) continue;
    [seen addObject:pose];
    MTDurationRecord r = pose.record; r.duration = timing.duration; r.useAvailableTime = timing.useAvailableTime; r.easing = timing.easing; pose.record = r;
    NSArray *own = [source containsObject:pose] ? source : partner;
    NSArray *other = own == source ? partner : source;
    MMLinkPose *linked = MMPoseWithLink(other, r.linkID);
    if (linked) [queue addObject:linked];
    if (own.count >= 3 && r.matchEndpoints && (pose == own[1] || pose == own.lastObject))
      [queue addObject:pose == own[1] ? own.lastObject : own[1]];
  }
}

static BOOL MMAddNativePose(id<FxKeyframeAPI_v3> keys, id<FxParameterSettingAPI_v5> set,
                            UInt32 valueID, MMLinkPose *pose, NSError **error) {
  FxKeyframe key = pose.key;
  NSError *failure = [keys addKeyframe:&key toParameter:valueID andChannel:0];
  if (failure) { if (error) *error = failure; return NO; }
  return [set setFloatValue:pose.record.value toParameter:valueID atTime:key.time] ||
         MMLinkError(error, @"Unable to preserve a linked keyframe value");
}
static BOOL MMRestoreNativePoses(id<FxKeyframeAPI_v3> keys, id<FxParameterSettingAPI_v5> set,
                                 UInt32 valueID, NSArray<MMLinkPose *> *before) {
  if ([keys removeAllKeyframesForParameter:valueID andChannel:0]) return NO;
  for (MMLinkPose *pose in before)
    if (!MMAddNativePose(keys, set, valueID, pose, nil)) return NO;
  return YES;
}
static BOOL MMApplyNativePoses(id<PROAPIAccessing> manager, UInt32 valueID,
                               NSArray<MMLinkPose *> *before, NSArray<MMLinkPose *> *after,
                               NSError **error) {
  id<FxKeyframeAPI_v3> keys = [manager apiForProtocol:@protocol(FxKeyframeAPI_v3)];
  id<FxParameterSettingAPI_v5> set = [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!keys || !set) return MMLinkError(error, @"Host keyframe editing is unavailable");
  // Reject collisions before touching the partner. Never replace an unrelated key.
  for (NSUInteger i=0; i<after.count; ++i)
    for (NSUInteger j=i+1; j<after.count; ++j)
      if (MMSameTime(after[i].record.time, after[j].record.time))
        return MMLinkError(error, @"Linked move would overlap another keyframe; undo the move or unlink first");
  // FxPlug's remote setKeyframeIndex wrapper drops its index (confirmed in
  // Motion 6.3 and the bundled framework, September 2026). Replace moved keys
  // with public remove/add operations, preserving metadata and scalar values.
  // `before` is in native index order. Remove descending so earlier indices
  // remain valid, without depending on reads seeing our pending host writes.
  BOOL ok = YES;
  for (NSUInteger remaining=before.count; remaining>0; --remaining) {
    NSUInteger index = remaining-1;
    MMLinkPose *old = before[index];
    MMLinkPose *retained = nil;
    for (MMLinkPose *pose in after)
      if (!pose.isNew && MMSameTime(pose.originalTime, old.originalTime)) { retained = pose; break; }
    if (retained && MMSameTime(retained.record.time, old.originalTime)) continue;

    NSError *failure = [keys removeKeyframeAtIndex:index fromParameter:valueID andChannel:0];
    if (failure) { if (error) *error = failure; ok = NO; break; }
  }
  if (ok) for (MMLinkPose *pose in after) {
    if (!pose.isNew && MMSameTime(pose.originalTime, pose.record.time)) {
      MMLinkPose *old = MMPoseAtTime(before, pose.originalTime);
      if (old && old.record.value != pose.record.value &&
          ![set setFloatValue:pose.record.value toParameter:valueID atTime:pose.key.time]) {
        ok = MMLinkError(error, @"Unable to update the matched endpoint value"); break;
      }
      continue;
    }
    if (!MMAddNativePose(keys, set, valueID, pose, error)) { ok = NO; break; }
  }
  if (!ok) {
    // The initiating source edit belongs to the host. Roll back only our partner edits.
    BOOL restored = MMRestoreNativePoses(keys, set, valueID, before);
    if (!restored) MMLinkError(error, @"Linked edit failed and could not be fully restored; undo this edit");
  }
  return ok;
}

@implementation MagicMovePlugin (Links)
- (void)invalidateTimingLane:(MMTimingLane *)lane {
  @synchronized (lane) { lane.durationGeneration += 1; lane.durationSnapshot = nil; }
}

- (MMLinkEdit *)prepareLinkedLane:(MMTimingLane *)lane parameterID:(UInt32)parameterID
                 data:(NSMutableData *)data atTime:(CMTime)time error:(NSError **)error {
  id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL linkEdit = parameterID == lane.linkEditorID;
  BOOL timingEdit = parameterID == lane.durationID || parameterID == lane.availableTimeID || parameterID == lane.easingID;
  NSInteger timingIndex = MMDestinationAtTime(data, time);
  BOOL requestedLink = NO;
  NSInteger linkIndex = MMKeyposeAtTime(data, time);
  if (linkEdit) {
    if (linkIndex == NSNotFound) return nil;
    if (![get getBoolValue:&requestedLink fromParameter:lane.linkEditorID atTime:time]) return nil;
  }
  MMTimingLane *partner = self.timingLanes[lane == self.timingLanes[0] ? 1 : 0];
  NSData *saved = MMReadSavedDestinations(self.apiManager, lane.dataID, error);
  NSData *partnerSaved = MMReadSavedDestinations(self.apiManager, partner.dataID, error);
  NSData *partnerPending = partner.pendingDestinations;
  NSData *partnerData = partnerPending ? MMReadDestinationsFromPrevious(self.apiManager, partner.valueID, partnerPending, error)
                                      : MMReadDestinations(self.apiManager, partner.valueID, partner.dataID, error);

  if (!saved || !partnerSaved || !partnerData) return nil;
  NSArray<MMLinkPose *> *before = MMNativePoses(self.apiManager, partner.valueID, partnerData, error);
  NSArray<MMLinkPose *> *source = MMNativePoses(self.apiManager, lane.valueID, data, error);
  if (!before || !source) return nil;
  NSMutableArray<MMLinkPose *> *after = MMCopyPoses(before);
  NSMutableArray<MMLinkPose *> *sourceAfter = MMCopyPoses(source);
  CMTime timingTime = time;
  if (timingEdit && timingIndex != NSNotFound) {
    double arrival = ((const MTDurationRecord *)data.bytes)[timingIndex].time;
    MMLinkPose *target = MMPoseAtTime(sourceAfter, arrival);
    if (!target) return nil;
    timingTime = target.key.time;
  }
  if (!MMMatchEndpoints(self.apiManager, lane, sourceAfter, saved, parameterID, timingTime, error)) return nil;
  [data setData:MMRecordsFromPoses(sourceAfter)];
  MTDurationRecord *records = data.mutableBytes;
  NSUInteger count = data.length/sizeof(*records);
  BOOL valuesChanged = parameterID == lane.valueID;
  if (valuesChanged) {
    const MTDurationRecord *previous = saved.bytes;
    for (NSUInteger i=0; i<saved.length/sizeof(*previous); ++i) {
      if (!previous[i].linkID) continue;
      BOOL survived = NO;
      for (NSUInteger j=0; j<count; ++j) if (records[j].linkID == previous[i].linkID) { survived = YES; break; }
      if (!survived) {
        MMLinkPose *deleted = MMPoseWithLink(after, previous[i].linkID);
        if (deleted) [after removeObject:deleted];
      }
    }
  }
  for (NSUInteger i=0; i<count; ++i) {
    MMLinkPose *pose = MMPoseWithLink(after, records[i].linkID);
    BOOL selectedLink = linkEdit && linkIndex == (NSInteger)i;
    if (selectedLink && !requestedLink) {
      if (pose) { MTDurationRecord unlinked = pose.record; unlinked.linkID = 0; pose.record = unlinked; }
      records[i].linkID = 0;
      continue;
    }
    BOOL created = selectedLink && requestedLink && !pose;
    if (created) {
      pose = MMPoseAtTime(after, records[i].time);
      if (pose && pose.record.linkID) {
        MMLinkError(error, @"A new pose overlaps an existing linked pair");
        return nil;
      }
      if (!pose) {
        pose = [MMLinkPose new]; pose.isNew = YES;
        MMLinkPose *nativeSource = MMPoseAtTime(sourceAfter, records[i].time);
        if (!nativeSource) {
          MMLinkError(error, @"Unable to locate the new source keyframe");
          return nil;
        }
        FxKeyframe key; FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
        key.time = nativeSource.key.time;
        pose.key = key;
        double value = 0;
        if (![get getFloatValue:&value fromParameter:partner.valueID atTime:key.time]) return nil;
        pose.record = (MTDurationRecord){.time=records[i].time, .value=value};
        [after addObject:pose];
      }
      records[i].linkID = MMNewLinkID();
      MTDurationRecord record = pose.record; record.linkID = records[i].linkID; pose.record = record;
    }
    if (!pose) { records[i].linkID = 0; continue; }
    MTDurationRecord record = pose.record;
    if (valuesChanged && !MMSameTime(record.time, records[i].time)) {
      MMLinkPose *nativeSource = MMPoseAtTime(sourceAfter, records[i].time);
      if (!nativeSource) {
        MMLinkError(error, @"Unable to locate the moved source keyframe");
        return nil;
      }
      FxKeyframe key = pose.key; key.time = nativeSource.key.time; pose.key = key;
      record.time = records[i].time;
    }
    if ((selectedLink && requestedLink) || (!linkEdit && !valuesChanged && timingIndex == (NSInteger)i)) {
      record.duration = records[i].duration;
      record.useAvailableTime = records[i].useAvailableTime;
      record.easing = records[i].easing;
    }
    pose.record = record;
  }

  // Bring pair IDs produced above back onto the source snapshots.
  for (NSUInteger i=0; i<count; ++i) {
    MMLinkPose *pose = MMPoseAtTime(sourceAfter, records[i].time);
    if (pose) pose.record = records[i];
  }
  MMSortPoses(after);
  if (!MMMatchEndpoints(self.apiManager, partner, after, partnerSaved, 0, time, error)) return nil;
  MMLinkPose *timingSeed = nil;
  if (timingEdit || linkEdit)
    timingSeed = MMPoseAtTime(sourceAfter, CMTimeGetSeconds(timingTime));
  else if (sourceAfter.count >= 3 && sourceAfter.firstObject.record.matchEndpoints)
    timingSeed = sourceAfter.lastObject;
  if (timingSeed) MMSpreadTiming(sourceAfter, after, timingSeed);
  [data setData:MMRecordsFromPoses(sourceAfter)];
  MMLinkEdit *edit = [MMLinkEdit new];
  edit.lane = lane; edit.partner = partner;
  edit.saved = saved; edit.partnerSaved = partnerSaved;
  edit.data = [data copy]; edit.partnerData = MMRecordsFromPoses(after);
  edit.before = before; edit.after = after;
  edit.sourceBefore = source; edit.sourceAfter = sourceAfter;
  return edit;
}

- (BOOL)syncLinkedLane:(MMTimingLane *)lane parameterID:(UInt32)parameterID
                 data:(NSMutableData *)data atTime:(CMTime)time error:(NSError **)error {
  // Off-key transient link callbacks remain a no-op.
  if (parameterID == lane.linkEditorID && MMKeyposeAtTime(data, time) == NSNotFound) return YES;
  MMLinkEdit *edit = [self prepareLinkedLane:lane parameterID:parameterID data:data atTime:time error:error];
  return edit && [self applyLinkedEdit:edit error:error];
}

- (BOOL)applyLinkedEdit:(MMLinkEdit *)edit error:(NSError **)error {
  MMTimingLane *lane = edit.lane, *partner = edit.partner;
  NSData *data = edit.data, *saved = edit.saved, *partnerSaved = edit.partnerSaved;
  NSArray *before = edit.before, *after = edit.after;
  BOOL committed = NO;
  [self invalidateTimingLane:partner];
  @try {
    if (!MMApplyNativePoses(self.apiManager, lane.valueID, edit.sourceBefore, edit.sourceAfter, error)) return NO;
    if (!MMApplyNativePoses(self.apiManager, partner.valueID, before, after, error)) {
      MMRestoreNativePoses([self.apiManager apiForProtocol:@protocol(FxKeyframeAPI_v3)],
                          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)], lane.valueID, edit.sourceBefore);
      return NO;
    }
    if (MMWriteDestinations(self.apiManager, lane.dataID, data) &&
        MMWriteDestinations(self.apiManager, partner.dataID, edit.partnerData)) { committed = YES; return YES; }
    // Commit the two metadata records together with the native partner edit.
    // A failed save must not leave one half of a link committed.
    BOOL restoredNative = MMRestoreNativePoses(
        [self.apiManager apiForProtocol:@protocol(FxKeyframeAPI_v3)],
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)], partner.valueID, before);
    BOOL restoredSourceNative = MMRestoreNativePoses(
        [self.apiManager apiForProtocol:@protocol(FxKeyframeAPI_v3)],
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)], lane.valueID, edit.sourceBefore);
    BOOL restoredSource = MMWriteDestinations(self.apiManager, lane.dataID, saved);
    BOOL restoredPartner = MMWriteDestinations(self.apiManager, partner.dataID, partnerSaved);
    return MMLinkError(error, restoredNative && restoredSourceNative && restoredSource && restoredPartner ?
        @"Linked settings could not be saved; partner restored. Undo the initiating edit" :
        @"Linked edit failed and could not be fully restored; undo this edit");
  } @finally {
    [self invalidateTimingLane:lane];
    [self invalidateTimingLane:partner];
    if (committed) {
      lane.publishedDestinations = data;
      partner.publishedDestinations = edit.partnerData;
      [lane publishDurationSnapshot:data generation:lane.durationGeneration];
      [partner publishDurationSnapshot:edit.partnerData generation:partner.durationGeneration];
    }
  }
}
@end
