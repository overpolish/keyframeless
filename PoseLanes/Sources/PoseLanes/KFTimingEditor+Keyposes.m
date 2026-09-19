/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFTimingEditor+Keyposes.h"
#import "KFTimingEditor+Refresh.h"
#import "KFTimingEditor_Private.h"
#import "KFKeyposeEdits.h"
#import "KFNativeEdits.h"
#import "KFNativeLinks.h"
#import "KFPropertyMenu.h"

@interface KFTimingEditor (KeyposesInternal)
- (void)cacheFrameGrid;
- (CMTime)snappedTime:(CMTime)time;
- (CMTime)retimeTargetForIndex:(NSInteger)index proposed:(CMTime)proposed;
- (void)applyKeyposeEdit:(NSValue *)boxed delete:(BOOL)deleting menu:(NSMenu *)menu;
@end

static CMTime KFKeyposeTimeLerp(CMTime from, CMTime to, double fraction) {
  if (fraction <= 0) return from;
  if (fraction >= 1) return to;
  return CMTimeAdd(from,
                   CMTimeMultiplyByFloat64(CMTimeSubtract(to, from), fraction));
}

@implementation KFTimingEditor (Keyposes)
// Read once and kept: the panel serves one document, whose frame rate does not
// change under it, and the drag path would otherwise pay a host read per event.
- (void)cacheFrameGrid {
  if (CMTIME_IS_NUMERIC(self.frameDuration)) return;
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return;
  [action startAction:self];
  @try {
    id<FxTimingAPI_v4> timing =
        [self.manager apiForProtocol:@protocol(FxTimingAPI_v4)];
    if (!timing) return;
    CMTime frame = kCMTimeInvalid, start = kCMTimeInvalid;
    [timing frameDuration:&frame];
    [timing startTimeForEffect:&start];
    if (!CMTIME_IS_NUMERIC(frame) || CMTimeCompare(frame, kCMTimeZero) <= 0)
      return;
    self.effectStart = CMTIME_IS_NUMERIC(start) ? start : kCMTimeZero;
    self.frameDuration = frame;
  } @finally {
    [action endAction:self];
  }
}

// Keypose times are host frames: the playhead can only stand on one, so a time
// the map proposes is rounded to the grid before anything is written.
- (CMTime)snappedTime:(CMTime)time {
  CMTime frame = self.frameDuration;
  if (!CMTIME_IS_NUMERIC(time) || !CMTIME_IS_NUMERIC(frame) ||
      CMTimeCompare(frame, kCMTimeZero) <= 0)
    return time;
  double frames = round(CMTimeGetSeconds(CMTimeSubtract(time, self.effectStart)) /
                        CMTimeGetSeconds(frame));
  return CMTimeAdd(self.effectStart, CMTimeMultiplyByFloat64(frame, frames));
}

// The time a retime would really write: on the frame grid, and never within a
// frame of a neighbour, since two keyposes cannot share one.
- (CMTime)retimeTargetForIndex:(NSInteger)index proposed:(CMTime)proposed {
  NSArray<KFKeyposeStop *> *stops = self.map.stops;
  NSInteger last = (NSInteger)stops.count - 1;
  if (index < 0 || index > last || !CMTIME_IS_NUMERIC(proposed))
    return kCMTimeInvalid;
  CMTime frame = self.frameDuration, target = [self snappedTime:proposed];
  BOOL gridded = CMTIME_IS_NUMERIC(frame) && CMTimeCompare(frame, kCMTimeZero) > 0;
  CMTime clearance = gridded ? frame : CMTimeMake(1, 600);
  if (index > 0) {
    CMTime low = CMTimeAdd(stops[index - 1].time, clearance);
    if (CMTimeCompare(target, low) < 0) target = low;
  }
  if (index < last) {
    CMTime high = CMTimeSubtract(stops[index + 1].time, clearance);
    if (CMTimeCompare(target, high) > 0) target = high;
  }
  // A corridor narrower than two frames has nowhere to put the keypose.
  if ((index > 0 && CMTimeCompare(target, stops[index - 1].time) <= 0) ||
      (index < last && CMTimeCompare(target, stops[index + 1].time) >= 0))
    return stops[index].time;
  return target;
}

- (void)scrubMapToFraction:(double)fraction {
  if (!self.window || self.hiddenOrHasHiddenAncestor || !isfinite(fraction))
    return;
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return;
  [action startAction:self];
  @try {
    NSArray<KFInspectorGap *> *gaps =
        KFReadInspectorLaneGaps(self.manager, self.displayedParameter);
    if (!gaps.count) return;
    double position = fmax(0, fmin(1, fraction)) * gaps.count;
    NSUInteger index = (NSUInteger)fmin(gaps.count - 1, floor(position));
    KFInspectorGap *gap = gaps[index];
    CMTime target = KFKeyposeTimeLerp(gap.sourceTime, gap.destinationTime,
                                      position - (double)index);
    id<FxCommandAPI_v2> command =
        [self.manager apiForProtocol:@protocol(FxCommandAPI_v2)];
    if (!command) return;
    // Key times already use the host clock, and FCP can return NO even when
    // the seek succeeds.
    [command movePlayheadToTime:target error:nil];
    // The refresh clock does not tick inside a drag, so the marker follows the
    // pointer from here rather than lagging a whole scrub behind.
    self.map.playheadFraction = fmax(0, fmin(1, fraction));
  } @finally {
    [action endAction:self];
  }
}

- (NSString *)retimeLabelForIndex:(NSInteger)index proposed:(CMTime)proposed {
  [self cacheFrameGrid];
  CMTime target = [self retimeTargetForIndex:index proposed:proposed];
  if (!CMTIME_IS_NUMERIC(target)) return nil;
  return [self.gapTimeFormatter
      stringFromNumber:@(CMTimeGetSeconds(target))];
}

- (void)commitRetimeIndex:(NSInteger)index proposed:(CMTime)proposed {
  NSArray<KFKeyposeStop *> *stops = self.map.stops;
  if (index < 0 || index >= (NSInteger)stops.count) return;
  CMTime from = stops[index].time;
  CMTime to = [self retimeTargetForIndex:index proposed:proposed];
  if (!CMTIME_IS_NUMERIC(to) || KFSame(from, to)) return;
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return;
  self.writingSetting = YES;
  [action startAction:self];
  @try {
    id<FxUndoAPI> undo = [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    BOOL grouped = [undo startUndoGroup:@"Move Keypose"];
    @try {
      if (!KFMoveKeypose(self.manager, self.displayedParameter, from, to, NULL)) {
        NSBeep();
        return;
      }
      // The press that started the drag selected this keypose, so the panel
      // follows it rather than editing whatever now sits under the playhead.
      id<FxCommandAPI_v2> command =
          [self.manager apiForProtocol:@protocol(FxCommandAPI_v2)];
      [command movePlayheadToTime:to error:nil];
    } @finally {
      if (grouped) [undo endUndoGroup];
    }
  } @finally {
    [action endAction:self];
    self.writingSetting = NO;
    [self refresh];
  }
}
// Where a right-click would add a keypose: the frame under the pointer, or the
// playhead when the lane holds too few keyposes for the axis to place one.
// Invalid when that frame already carries a keypose.
- (CMTime)addTimeForPointer:(CMTime)pointer {
  [self cacheFrameGrid];
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return kCMTimeInvalid;
  [action startAction:self];
  @try {
    CMTime target = CMTIME_IS_NUMERIC(pointer) ? [self snappedTime:pointer]
                                               : [action currentTime];
    if (!CMTIME_IS_NUMERIC(target)) return kCMTimeInvalid;
    return KFAt(KFEntries(self.manager, self.displayedParameter), target)
               ? kCMTimeInvalid
               : target;
  } @finally {
    [action endAction:self];
  }
}

- (NSMenu *)keyposeMenuForIndex:(NSInteger)index time:(CMTime)time {
  NSMenu *menu =
      KFNativePropertyMenu(self.manager, self, self.displayedParameter);
  if (!menu) return nil;
  NSMenuItem *item;
  if (index >= 0 && index < (NSInteger)self.map.stops.count) {
    item = [[NSMenuItem alloc] initWithTitle:@"Delete Keypose"
                                      action:@selector(deleteKeypose:)
                               keyEquivalent:@""];
    CMTime keypose = self.map.stops[index].time;
    item.representedObject = [NSValue valueWithBytes:&keypose
                                            objCType:@encode(CMTime)];
    // The last keypose stays: emptying a lane is Reset Parameter's job.
    item.enabled = self.map.stops.count > 1;
  } else {
    CMTime target = [self addTimeForPointer:time];
    item = [[NSMenuItem alloc] initWithTitle:@"Add Keypose"
                                      action:@selector(addKeypose:)
                               keyEquivalent:@""];
    if (CMTIME_IS_NUMERIC(target))
      item.representedObject = [NSValue valueWithBytes:&target
                                              objCType:@encode(CMTime)];
    // Only a frame that already carries a keypose has nothing to add.
    item.enabled = CMTIME_IS_NUMERIC(target);
  }
  item.target = self;
  [menu insertItem:item atIndex:0];
  [menu insertItem:NSMenuItem.separatorItem atIndex:1];
  return menu;
}

- (void)addKeypose:(NSMenuItem *)sender {
  NSMenu *menu = sender.menu;
  NSValue *time = sender.representedObject;
  KFPropertyMenuActionScheduled(menu);
  // Return the ViewBridge button callback before asking the host for keyframes.
  dispatch_async(dispatch_get_main_queue(), ^{
    [self applyKeyposeEdit:time delete:NO menu:menu];
  });
}
- (void)deleteKeypose:(NSMenuItem *)sender {
  NSMenu *menu = sender.menu;
  NSValue *time = sender.representedObject;
  KFPropertyMenuActionScheduled(menu);
  dispatch_async(dispatch_get_main_queue(), ^{
    [self applyKeyposeEdit:time delete:YES menu:menu];
  });
}
// The menu resolved the time when it was built, so the edit uses that frame
// rather than wherever the playhead has since landed.
- (void)applyKeyposeEdit:(NSValue *)boxed delete:(BOOL)deleting menu:(NSMenu *)menu {
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) {
    KFPropertyMenuActionFinished(menu, NO);
    return;
  }
  BOOL ok = NO;
  self.writingSetting = YES;
  [action startAction:self];
  @try {
    id<FxUndoAPI> undo = [self.manager apiForProtocol:@protocol(FxUndoAPI)];
    if (![undo startUndoGroup:deleting ? @"Delete Keypose" : @"Add Keypose"])
      return;
    @try {
      CMTime time = [action currentTime];
      if (boxed) [boxed getValue:&time];
      ok = deleting ? KFDeleteKeypose(self.manager, self.displayedParameter,
                                      time, NULL)
                    : KFAddKeypose(self.manager, self.displayedParameter, time,
                                   NULL);
      if (!ok) NSBeep();
    } @finally {
      [undo endUndoGroup];
    }
  } @finally {
    [action endAction:self];
    self.writingSetting = NO;
    KFPropertyMenuActionFinished(menu, ok);
    [self refresh];
  }
}
@end
