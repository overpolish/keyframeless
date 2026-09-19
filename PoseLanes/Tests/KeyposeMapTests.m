/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "TestLanes.h"
#import "KFKeyposeEdits.h"
#import "KFKeyposeMap.h"
#import "KFNativeEdits.h"
#import "KFNativeLinks.h"
#import "KFTimingEditorModel.h"
@import InspectorControls;
#import <assert.h>
#import <math.h>

@interface KFTimingEditor (Tests)
- (void)refresh;
@end

@interface MapHost : MockHost <FxCustomParameterActionAPI_v4>
@property CMTime playhead;
@property NSUInteger actions;
@property NSUInteger seeks;
// Ordered record of what one lane received, so a test can see the state the
// host's undo journal was given before a key went away.
@property(nonatomic, strong) NSMutableArray<NSString *> *log;
@end
@implementation MapHost
- (void)startAction:(id)sender { (void)sender; self.actions++; }
- (void)endAction:(id)sender {
  (void)sender;
  assert(self.actions);
  self.actions--;
}
- (BOOL)movePlayheadToTime:(CMTime)time error:(NSError **)error {
  (void)error;
  assert(self.actions > 0);
  self.seeks++;
  self.playhead = time;
  return NO; // FCP may report failure even though the seek applied.
}
- (CMTime)currentTime { return self.playhead; }
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding, NSCopying> **)value
                  fromParameter:(UInt32)parameter
                         atTime:(CMTime)time {
  for (NSDictionary *entry in [self lane:parameter])
    if (fabs([entry[@"time"] doubleValue] - CMTimeGetSeconds(time)) < 1e-6) {
      *value = entry[@"value"];
      return YES;
    }
  *value = self.blobs[@(parameter)];
  return *value != nil;
}
- (BOOL)setCustomParameterValue:(id)value
                    toParameter:(UInt32)parameter
                         atTime:(CMTime)time {
  BOOL result = [super setCustomParameterValue:value toParameter:parameter atTime:time];
  if (result && parameter != KFTestHostRefreshToken) {
    [self.log addObject:[NSString stringWithFormat:@"set %u %.3f", (unsigned)parameter,
                                                   CMTimeGetSeconds(time)]];
    for (NSMutableDictionary *record in [self lane:parameter])
      if (fabs([record[@"time"] doubleValue] - CMTimeGetSeconds(time)) < 1e-6)
        record[@"value"] = value;
  }
  return result;
}
- (NSMutableArray<NSString *> *)log {
  if (!_log) _log = [NSMutableArray new];
  return _log;
}
- (NSError *)removeKeyframeAtIndex:(NSUInteger)index
                     fromParameter:(NSUInteger)parameter
                        andChannel:(NSUInteger)channel {
  [self.log addObject:[NSString stringWithFormat:@"remove %u %.3f", (unsigned)parameter,
                                                 [[self lane:parameter][index][@"time"] doubleValue]]];
  return [super removeKeyframeAtIndex:index fromParameter:parameter andChannel:channel];
}
@end

static void addKey(MapHost *host, UInt32 parameter, double time, id value) {
  FxKeyframe key;
  FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
  key.time = TestTime(time);
  [[host lane:parameter] addObject:[@{
    @"time" : @(time),
    @"value" : value,
    @"key" : [NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]
  } mutableCopy]];
}
static id<KFPropertyPose> pose(KFPropertyLane *lane, NSArray<NSNumber *> *values,
                               double duration, BOOL available, NSString *link) {
  KFPoseTiming *timing = [[KFPoseTiming alloc] initWithDuration:duration
                                                      available:available
                                                         amount:1
                                                          speed:1];
  if (link) timing = [timing timingByReplacingLinkID:link];
  return [lane.defaultPose poseByReplacingValues:values
                                        authored:YES
                                          easing:MTEasingSmooth
                                     addedMotion:MTAddedMotionNone
                                          timing:timing];
}
static void publish(MapHost *host, KFPropertyLane *lane, UInt32 token) {
  KFPropertyPoseCache *cache = [lane createCache];
  host.staticValues[@(token)] = cache.token;
  [lane refreshCacheForManager:host time:host.playhead];
}
// Geometry is read back through the view's own hit testing so the tests never
// restate its layout arithmetic.
static NSPoint pointForIndex(KFKeyposeMap *map, NSInteger index) {
  for (CGFloat y = 0; y < NSHeight(map.bounds); y += 0.5)
    for (CGFloat x = 0; x < NSWidth(map.bounds); x += 0.5)
      if ([map indexAtPoint:NSMakePoint(x, y)] == index) return NSMakePoint(x, y);
  return NSMakePoint(-1, -1);
}
// The bead's centre, averaged over the hit region the view reports, so the
// tests address positions between keyposes without restating the layout.
static CGFloat centerForIndex(KFKeyposeMap *map, NSInteger index) {
  NSPoint probe = pointForIndex(map, index);
  CGFloat first = -1, last = -1;
  for (CGFloat x = 0; x < NSWidth(map.bounds); x += 0.5)
    if ([map indexAtPoint:NSMakePoint(x, probe.y)] == index) {
      if (first < 0) first = x;
      last = x;
    }
  return (first + last) / 2;
}
static NSEvent *mouseEvent(KFKeyposeMap *map, NSWindow *window, NSEventType type,
                           CGFloat x, CGFloat y) {
  return [NSEvent mouseEventWithType:type
                            location:[map convertPoint:NSMakePoint(x, y) toView:nil]
                       modifierFlags:0
                           timestamp:0
                        windowNumber:window.windowNumber
                             context:nil
                         eventNumber:0
                          clickCount:1
                            pressure:1];
}
static double keyTime(MapHost *host, UInt32 parameter, NSUInteger index) {
  return [[host lane:parameter][index][@"time"] doubleValue];
}
static NSMenu *menuAt(KFKeyposeMap *map, NSWindow *window, CGFloat x, CGFloat y) {
  return [map menuForEvent:mouseEvent(map, window, NSEventTypeRightMouseDown, x, y)];
}


// Six keyposes whose gaps run 1, 0.2, 1.8, 0.2 and 0.8 seconds, so a
// proportional layout and an ordinal one cannot be confused.
static MapHost *scaleLaneHost(double playhead) {
  MapHost *host = [MapHost new];
  host.playhead = TestTime(playhead);
  KFPropertyLane *lane = KFTestScaleLane();
  addKey(host, KFTestScale, 0, pose(lane, @[ @100, @100 ], 1.2, NO, nil));
  addKey(host, KFTestScale, 1, pose(lane, @[ @120, @120 ], 0.5, NO, nil));
  addKey(host, KFTestScale, 1.2, pose(lane, @[ @140, @140 ], 5, NO, nil));
  addKey(host, KFTestScale, 3, pose(lane, @[ @160, @160 ], 0.3, YES, nil));
  addKey(host, KFTestScale, 3.2, pose(lane, @[ @180, @180 ], 0.1, NO, nil));
  addKey(host, KFTestScale, 4, pose(lane, @[ @200, @200 ], 0.4, NO, nil));
  host.blobs[@(KFTestScale)] = [host lane:KFTestScale][0][@"value"];
  publish(host, lane, KFTestScaleCacheToken);
  return host;
}
// The panel holds its effect weakly, as it does in the host, so the caller has
// to keep it alive for as long as it refreshes.
static KFTimingEditor *attach(MapHost *host, NSWindow **window, KFTestEffect **effect) {
  [NSApplication sharedApplication];
  KFTestEffect *plugin = [[KFTestEffect alloc] initWithAPIManager:host];
  plugin.activeInspectorParameterID = KFTestScale;
  *effect = plugin;
  *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 395, 284)
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  (*window).releasedWhenClosed = NO;
  KFTimingEditor *panel = [[KFTimingEditor alloc] initWithEffect:plugin];
  panel.frame = NSMakeRect(0, 0, 395, panel.intrinsicContentSize.height);
  [(*window).contentView addSubview:panel];
  [panel refresh];
  [panel layoutSubtreeIfNeeded];
  return panel;
}

static void testLaneGaps(void) {
  MapHost *host = scaleLaneHost(1.1);
  NSArray<KFInspectorGap *> *gaps = KFReadInspectorLaneGaps(host, KFTestScale);
  assert(gaps.count == 5);
  for (NSUInteger i = 0; i < gaps.count; i++) assert(gaps[i].destinationIndex == i + 1);
  assert(CMTimeCompare(gaps.firstObject.sourceTime, TestTime(0)) == 0);
  assert(fabs(CMTimeGetSeconds(gaps.lastObject.destinationTime) - 4) < 1e-6);
  // Every gap shares one entry snapshot, so the map costs one cache read.
  assert(gaps.firstObject.entries == gaps.lastObject.entries);

  // A lane the host has not keyed has no gaps, and neither has a single key.
  assert(KFReadInspectorLaneGaps(host, KFTestBlur).count == 0);
  KFPropertyLane *blur = KFTestBlurLane();
  addKey(host, KFTestBlur, 1, pose(blur, @[ @10 ], 0.5, NO, nil));
  publish(host, blur, KFTestBlurCacheToken);
  assert(KFReadInspectorLaneGaps(host, KFTestBlur).count == 0);
}

static void testMapContents(void) {
  MapHost *host = scaleLaneHost(1.1);
  NSWindow *window = nil;
  KFTestEffect *effect = nil;
  KFTimingEditor *panel = attach(host, &window, &effect);
  KFKeyposeMap *map = [panel valueForKey:@"map"];
  assert(map.stops.count == 6);
  // The playhead sits inside the 1 → 1.2 gap, whose arrival is keypose 2, and
  // it is not standing on a keypose of its own.
  assert(map.activeIndex == 2 && map.playheadIndex == -1);

  // A duration is a request clamped to its gap, and Use Available fills it.
  assert(map.stops[0].transitionFraction == 0);
  assert(fabs(map.stops[1].transitionFraction - 0.5) < 1e-6);
  assert(map.stops[2].transitionFraction == 1);
  assert(map.stops[3].transitionFraction == 1);
  assert(fabs(map.stops[4].transitionFraction - 0.5) < 1e-6);

  // Ends plus the active gap carry timecodes; the rest would collide.
  assert(map.stops[0].label && map.stops[1].label && map.stops[2].label && map.stops[5].label);
  assert(!map.stops[3].label && !map.stops[4].label);
  assert([map.stops[1].label isEqualToString:@"1"]);
  assert([map.stops[2].label isEqualToString:@"1.2"]);

  // The marker keeps the segment it is really in and travels at that gap's rate.
  assert(fabs(map.playheadFraction - 0.3) < 1e-6);
  // Mid-gap the arrival is the pose being edited.
  assert([map isFilledIndex:2] && ![map isFilledIndex:1]);

  // Standing on the first keypose, the gap ahead is still the editable one, but
  // the pose being edited is the one under the playhead. Only its transition
  // carries the highlight; its arrival stays unfilled.
  host.playhead = TestTime(0);
  [panel refresh];
  assert(map.activeIndex == 1 && map.playheadIndex == 0);
  assert(map.playheadFraction == 0);
  assert([map isFilledIndex:0] && ![map isFilledIndex:1]);
  // Every later keypose is its own gap's arrival, so both agree and it fills.
  host.playhead = TestTime(3);
  [panel refresh];
  assert(map.activeIndex == 3 && map.playheadIndex == 3 && [map isFilledIndex:3]);
  host.playhead = TestTime(4);
  [panel refresh];
  assert(map.activeIndex == 5 && map.playheadIndex == 5 && [map isFilledIndex:5]);

  host.playhead = TestTime(5);
  [panel refresh];
  assert(map.playheadFraction < 0 && map.activeIndex == -1 && map.playheadIndex == -1);

  [panel removeFromSuperview];
  [window close];
}

static void testOrdinalLayoutAndSelection(void) {
  MapHost *host = scaleLaneHost(1.1);
  NSWindow *window = nil;
  KFTestEffect *effect = nil;
  KFTimingEditor *panel = attach(host, &window, &effect);
  KFKeyposeMap *map = [panel valueForKey:@"map"];

  CGFloat previous = -1, spacing = -1;
  for (NSInteger i = 1; i < 6; i++) {
    NSPoint point = pointForIndex(map, i);
    assert(point.x >= 0);
    if (previous >= 0) {
      CGFloat delta = point.x - previous;
      // Equal width per gap: the real gaps differ ninefold, so a proportional
      // axis could not produce a constant step.
      if (spacing >= 0) assert(fabs(delta - spacing) < 1);
      spacing = delta;
    }
    previous = point.x;
  }

  NSUInteger seeks = host.seeks;
  NSPoint bead = pointForIndex(map, 4);
  NSEvent *(^click)(NSPoint) = ^NSEvent *(NSPoint local) {
    return [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                              location:[map convertPoint:local toView:nil]
                         modifierFlags:0
                             timestamp:0
                          windowNumber:window.windowNumber
                               context:nil
                            eventNumber:0
                            clickCount:1
                              pressure:1];
  };
  [map mouseDown:click(bead)];
  assert(host.seeks == seeks + 1 && host.actions == 0);
  assert(fabs(CMTimeGetSeconds(host.playhead) - 3.2) < 1e-6);
  // The seek is the only host traffic: selecting a keypose writes nothing.
  assert(host.hostWrites == 0);

  // The label band is not a target, so a stray click cannot move the playhead.
  assert([map indexAtPoint:NSMakePoint(bead.x, 2)] == -1);
  [map mouseDown:click(NSMakePoint(bead.x, 2))];
  assert(host.seeks == seeks + 1);

  [panel removeFromSuperview];
  [window close];
}

static void testLinkTintAndMotionSource(void) {
  MapHost *host = scaleLaneHost(1.1);
  KFPropertyLane *rotation = KFTestRotationLane();
  // A single key carrying an identifier is not a group.
  assert(!KFLinkGroupColor(host, @"solo"));
  assert(!KFLinkGroupColor(host, @""));

  [[host lane:KFTestScale][1] setObject:pose(KFTestScaleLane(), @[ @120, @120 ], 0.5, NO, @"g1")
                                 forKey:@"value"];
  addKey(host, KFTestRotation, 0, pose(rotation, @[ @0, @0, @0 ], 0.5, NO, nil));
  addKey(host, KFTestRotation, 1, pose(rotation, @[ @0, @0, @90 ], 0.5, NO, @"g1"));
  host.blobs[@(KFTestRotation)] = [host lane:KFTestRotation][0][@"value"];
  publish(host, rotation, KFTestRotationCacheToken);
  publish(host, KFTestScaleLane(), KFTestScaleCacheToken);

  NSColor *group = KFLinkGroupColor(host, @"g1");
  assert(group);
  // The map and the row gutter must not drift apart: one resolver, one tint.
  assert([group isEqual:KFNativePropertyLinkColor(host, KFTestScale, TestTime(1))]);
  assert([group isEqual:KFLinkGroupColor(host, @"g1")]);

  NSWindow *window = nil;
  KFTestEffect *effect = nil;
  KFTimingEditor *panel = attach(host, &window, &effect);
  KFKeyposeMap *map = [panel valueForKey:@"map"];
  assert([map.stops[1].linkColor isEqual:group]);
  assert(!map.stops[0].linkColor && !map.stops[2].linkColor);

  // Added Motion is written to the gap's source pose, so that keypose joins the
  // highlight only while those controls are in use.
  assert(!map.sourceHighlighted);
  [panel setValue:@YES forKey:@"motionHovered"];
  [panel refresh];
  assert(map.sourceHighlighted);
  [panel setValue:@NO forKey:@"motionHovered"];
  [panel refresh];
  assert(!map.sourceHighlighted);

  [panel removeFromSuperview];
  [window close];
}

static void testEmptyState(void) {
  MapHost *host = [MapHost new];
  host.playhead = TestTime(1);
  KFPropertyLane *lane = KFTestScaleLane();
  addKey(host, KFTestScale, 1, pose(lane, @[ @100, @100 ], 0.5, NO, nil));
  host.blobs[@(KFTestScale)] = [host lane:KFTestScale][0][@"value"];
  publish(host, lane, KFTestScaleCacheToken);
  NSWindow *window = nil;
  KFTestEffect *effect = nil;
  KFTimingEditor *panel = attach(host, &window, &effect);
  KFKeyposeMap *map = [panel valueForKey:@"map"];
  // Not hidden: the bare rail stands in, so the panel keeps its shape and the
  // map reads as empty rather than missing. Nothing is selectable.
  assert(!map.hidden && map.stops.count == 0);
  assert(map.activeIndex == -1 && map.playheadIndex == -1);
  assert([map indexAtPoint:NSMakePoint(8, 22)] == -1);

  // A bare rail still takes a second keypose, which is how a lane with one key
  // gets one. With no stops the axis cannot place a click, so the playhead
  // decides, and standing on that key there is nothing to add.
  assert(!menuAt(map, window, 40, 22).itemArray[0].enabled);
  host.playhead = TestTime(2);
  [panel refresh];
  NSMenuItem *add = menuAt(map, window, 40, 22).itemArray[0];
  assert([add.title isEqualToString:@"Add Keypose"] && add.enabled);
  [NSApp sendAction:add.action to:add.target from:add];
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  assert([host lane:KFTestScale].count == 2 && map.stops.count == 2);
  assert(host.undoDepth == 0);
  [panel removeFromSuperview];
  [window close];
}

static void testRailScrubbing(void) {
  MapHost *host = scaleLaneHost(1.1);
  NSWindow *window = nil;
  KFTestEffect *effect = nil;
  KFTimingEditor *panel = attach(host, &window, &effect);
  KFKeyposeMap *map = [panel valueForKey:@"map"];
  CGFloat y = pointForIndex(map, 2).y;
  CGFloat rail = (centerForIndex(map, 2) + centerForIndex(map, 3)) / 2;
  assert([map indexAtPoint:NSMakePoint(rail, y)] == -1);

  NSUInteger seeks = host.seeks;
  [map mouseDown:mouseEvent(map, window, NSEventTypeLeftMouseDown, rail, y)];
  // Halfway across an ordinal map of five gaps is the middle of the third,
  // which really runs 1.2 → 3 s. Positions come from the view's hit regions,
  // so the times they resolve to carry that half-point of slack.
  assert(host.seeks == seeks + 1);
  assert(fabs(CMTimeGetSeconds(host.playhead) - 2.1) < 0.01);
  // The marker follows the pointer, since no refresh tick runs inside a drag.
  assert(fabs(map.playheadFraction - 0.5) < 0.005);

  CGFloat lastGap = centerForIndex(map, 4);
  lastGap += (centerForIndex(map, 5) - lastGap) / 4;
  [map mouseDragged:mouseEvent(map, window, NSEventTypeLeftMouseDragged, lastGap, y)];
  // A quarter into the 3.2 → 4 s gap, at that gap's own rate.
  assert(fabs(CMTimeGetSeconds(host.playhead) - 3.4) < 0.01);
  [map mouseUp:mouseEvent(map, window, NSEventTypeLeftMouseUp,
                          NSWidth(map.bounds), y)];
  assert(fabs(CMTimeGetSeconds(host.playhead) - 4) < 1e-6);
  // Scrubbing is navigation: it writes nothing and keeps no action open.
  assert(host.actions == 0 && host.hostWrites == 0 && host.mutations == 0);

  // The label band is not a rail, so a stray press there cannot drag anything.
  seeks = host.seeks;
  [map mouseDown:mouseEvent(map, window, NSEventTypeLeftMouseDown, rail, 2)];
  [map mouseDragged:mouseEvent(map, window, NSEventTypeLeftMouseDragged, rail, 2)];
  assert(host.seeks == seeks);

  [panel removeFromSuperview];
  [window close];
}

static void testRetimeDrag(void) {
  MapHost *host = scaleLaneHost(1.1);
  NSWindow *window = nil;
  KFTestEffect *effect = nil;
  KFTimingEditor *panel = attach(host, &window, &effect);
  KFKeyposeMap *map = [panel valueForKey:@"map"];
  CGFloat y = pointForIndex(map, 1).y;
  CGFloat first = centerForIndex(map, 1), second = centerForIndex(map, 2);
  NSUInteger groups = host.undoGroupsStarted;

  [map mouseDown:mouseEvent(map, window, NSEventTypeLeftMouseDown, first, y)];
  // The press selects, as a click on a keypose always has.
  assert(fabs(CMTimeGetSeconds(host.playhead) - 1) < 1e-6);
  // Under the drag threshold nothing is being retimed yet.
  [map mouseDragged:mouseEvent(map, window, NSEventTypeLeftMouseDragged, first + 2, y)];
  assert(![map valueForKey:@"dragLabel"]);

  CGFloat quarter = first + (second - first) / 4;
  [map mouseDragged:mouseEvent(map, window, NSEventTypeLeftMouseDragged, quarter, y)];
  // Each half of the corridor carries its own gap: a quarter into the 1 → 1.2 s
  // gap is 1.05 s, which the host's 30 fps grid rounds to frame 32.
  assert([[map valueForKey:@"dragLabel"] isEqualToString:@"1.07"]);
  // A drag previews; the host sees one structural edit, on release.
  assert(host.mutations == 0 && host.undoGroupsStarted == groups);

  [map mouseUp:mouseEvent(map, window, NSEventTypeLeftMouseUp, quarter, y)];
  assert(host.undoGroupsStarted == groups + 1 && host.undoDepth == 0);
  assert(![map valueForKey:@"dragLabel"]);
  assert([host lane:KFTestScale].count == 6);
  assert(fabs(keyTime(host, KFTestScale, 1) - 32.0 / 30) < 1e-6);
  // The pose travels with its keypose, and the playhead stays on it so the
  // panel keeps editing the pose that moved.
  id<KFPropertyPose> moved = [host lane:KFTestScale][1][@"value"];
  assert(moved.values[0].doubleValue == 120);
  assert(fabs(CMTimeGetSeconds(host.playhead) - 32.0 / 30) < 1e-6);
  assert(fabs(CMTimeGetSeconds(map.stops[1].time) - 32.0 / 30) < 1e-6);

  [panel removeFromSuperview];
  [window close];
}

static void testRetimeStopsAtNeighbours(void) {
  MapHost *host = scaleLaneHost(1.1);
  NSWindow *window = nil;
  KFTestEffect *effect = nil;
  KFTimingEditor *panel = attach(host, &window, &effect);
  KFKeyposeMap *map = [panel valueForKey:@"map"];
  CGFloat y = pointForIndex(map, 1).y;

  [map mouseDown:mouseEvent(map, window, NSEventTypeLeftMouseDown,
                            centerForIndex(map, 1), y)];
  [map mouseDragged:mouseEvent(map, window, NSEventTypeLeftMouseDragged,
                               centerForIndex(map, 3), y)];
  // The corridor ends at the next keypose, one frame short of landing on it.
  assert([[map valueForKey:@"dragLabel"] isEqualToString:@"1.17"]);
  [map mouseUp:mouseEvent(map, window, NSEventTypeLeftMouseUp,
                          centerForIndex(map, 3), y)];
  assert([host lane:KFTestScale].count == 6);
  assert(fabs(keyTime(host, KFTestScale, 1) - (1.2 - 1.0 / 30)) < 1e-6);
  assert(fabs(keyTime(host, KFTestScale, 2) - 1.2) < 1e-6);

  // The first keypose has a corridor on one side only: there is no rail to its
  // left, so dragging that way cannot pull it off the start of the lane.
  NSUInteger mutations = host.mutations;
  [map mouseDown:mouseEvent(map, window, NSEventTypeLeftMouseDown,
                            centerForIndex(map, 0), y)];
  [map mouseDragged:mouseEvent(map, window, NSEventTypeLeftMouseDragged, -40, y)];
  [map mouseUp:mouseEvent(map, window, NSEventTypeLeftMouseUp, -40, y)];
  assert(host.mutations == mutations && keyTime(host, KFTestScale, 0) == 0);

  [panel removeFromSuperview];
  [window close];
}

static void testKeyposeMenu(void) {
  MapHost *host = scaleLaneHost(2);
  NSWindow *window = nil;
  KFTestEffect *effect = nil;
  KFTimingEditor *panel = attach(host, &window, &effect);
  KFKeyposeMap *map = [panel valueForKey:@"map"];
  CGFloat y = pointForIndex(map, 2).y;
  CGFloat rail = (centerForIndex(map, 2) + centerForIndex(map, 3)) / 2;

  NSMenu *onKeypose = menuAt(map, window, centerForIndex(map, 2), y);
  assert([onKeypose.itemArray[0].title isEqualToString:@"Delete Keypose"]);
  assert(onKeypose.itemArray[0].enabled && onKeypose.itemArray[1].isSeparatorItem);

  // The click decides where a keypose lands, so standing on some other
  // keypose cannot disable it.
  host.playhead = TestTime(3);
  [panel refresh];
  NSMenuItem *add = menuAt(map, window, rail, y).itemArray[0];
  assert(add.enabled && [add.title isEqualToString:@"Add Keypose"]);

  id<KFPropertyPose> before = [KFTestScaleLane() sampleEntries:KFEntries(host, KFTestScale)
                                                          time:TestTime(2.1)];
  NSUInteger groups = host.undoGroupsStarted;
  [NSApp sendAction:add.action to:add.target from:add];
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  assert([host lane:KFTestScale].count == 7);
  // Halfway along the 1.2 → 3 s gap, rounded onto the host's 30 fps grid.
  double created = keyTime(host, KFTestScale, 3);
  assert(fabs(created - 2.1) < 0.02 && fabs(created * 30 - round(created * 30)) < 1e-6);
  assert(host.undoGroupsStarted == groups + 1 && host.undoDepth == 0);
  // The new keypose holds the value the curve already had there.
  id<KFPropertyPose> pose = [host lane:KFTestScale][3][@"value"];
  assert(fabs(pose.values[0].doubleValue - before.values[0].doubleValue) < 0.5);
  assert(map.stops.count == 7);

  NSMenuItem *remove = menuAt(map, window, centerForIndex(map, 3), y).itemArray[0];
  assert([remove.title isEqualToString:@"Delete Keypose"]);
  [host.log removeAllObjects];
  [NSApp sendAction:remove.action to:remove.target from:remove];
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  // The host journals a parameter when its value is written, so the doomed
  // keypose is written once more before the key goes; without that, undoing
  // the deletion has nothing to put back.
  NSString *wrote = [NSString stringWithFormat:@"set %u %.3f", (unsigned)KFTestScale, created];
  NSString *removed = [NSString stringWithFormat:@"remove %u %.3f", (unsigned)KFTestScale, created];
  assert([host.log containsObject:wrote] && [host.log containsObject:removed]);
  assert([host.log indexOfObject:wrote] < [host.log indexOfObject:removed]);
  assert([host lane:KFTestScale].count == 6 && host.undoGroupsStarted == groups + 2);
  assert(!KFAt(KFEntries(host, KFTestScale), TestTime(created)));
  assert(map.stops.count == 6);

  [panel removeFromSuperview];
  [window close];
}

static void testKeyposeEditRules(void) {
  MapHost *host = scaleLaneHost(1.1);
  KFPropertyLane *rotation = KFTestRotationLane();
  [[host lane:KFTestScale][1] setObject:pose(KFTestScaleLane(), @[ @120, @120 ], 0.5, NO, @"g1")
                                 forKey:@"value"];
  addKey(host, KFTestRotation, 0, pose(rotation, @[ @0, @0, @0 ], 0.5, NO, nil));
  addKey(host, KFTestRotation, 1, pose(rotation, @[ @0, @0, @90 ], 0.5, NO, @"g1"));
  host.blobs[@(KFTestRotation)] = [host lane:KFTestRotation][0][@"value"];
  publish(host, rotation, KFTestRotationCacheToken);
  publish(host, KFTestScaleLane(), KFTestScaleCacheToken);

  // A linked keypose takes its partners with it, as a native host drag does.
  assert(KFMoveKeypose(host, KFTestScale, TestTime(1), TestTime(1.1), NULL));
  assert(fabs(keyTime(host, KFTestScale, 1) - 1.1) < 1e-6);
  assert(fabs(keyTime(host, KFTestRotation, 1) - 1.1) < 1e-6);

  // Landing on an existing keypose is refused rather than merged.
  NSError *error = nil;
  assert(!KFMoveKeypose(host, KFTestScale, TestTime(1.1), TestTime(1.2), &error));
  assert(error && fabs(keyTime(host, KFTestScale, 1) - 1.1) < 1e-6);

  // A lane keeps its last keypose: emptying it is Reset Parameter's job.
  KFPropertyLane *blur = KFTestBlurLane();
  addKey(host, KFTestBlur, 1, pose(blur, @[ @10 ], 0.5, NO, nil));
  host.blobs[@(KFTestBlur)] = [host lane:KFTestBlur][0][@"value"];
  publish(host, blur, KFTestBlurCacheToken);
  error = nil;
  assert(!KFDeleteKeypose(host, KFTestBlur, TestTime(1), &error));
  assert(error && [host lane:KFTestBlur].count == 1);

  // A second keypose cannot be added where one already is.
  assert(!KFAddKeypose(host, KFTestBlur, TestTime(1), NULL));
  assert(KFAddKeypose(host, KFTestBlur, TestTime(2), NULL));
  assert([host lane:KFTestBlur].count == 2);
}

int main(void) {
  @autoreleasepool {
    KFTestRegisterLanes();
    testLaneGaps();
    testMapContents();
    testOrdinalLayoutAndSelection();
    testLinkTintAndMotionSource();
    testEmptyState();
    testRailScrubbing();
    testRetimeDrag();
    testRetimeStopsAtNeighbours();
    testKeyposeMenu();
    testKeyposeEditRules();
  }
  puts("KeyposeMap: lane gaps, ordinal layout, clamped transitions, link tints, "
       "playhead selection, rail scrubbing, keypose retiming and the add/delete "
       "menu passed");
}
