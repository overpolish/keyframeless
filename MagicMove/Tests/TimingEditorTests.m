/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "MMCombinedPose.h"
#import "MMScalePose.h"
#import "MMTimingEditor.h"
#import "MMTimingEditorModel.h"
#import "MMInspectorColors.h"
#import "MockHost.h"
@import InspectorControls;
#import <assert.h>
#import <math.h>

@interface TimingHost : MockHost <FxCustomParameterActionAPI_v4>
@property CMTime playhead;
@property NSUInteger actions;
@property(nonatomic,copy) void (^readHook)(void);
@end
@interface MMTimingEditor (Tests)
- (void)refresh;
- (void)menuChanged:(NSPopUpButton *)menu;
@end
@implementation TimingHost
- (void)startAction:(id)sender {
  self.actions++;
}
- (void)endAction:(id)sender {
  assert(self.actions);
  self.actions--;
}
- (CMTime)currentTime {
  return self.playhead;
}
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding, NSCopying> **)value
                  fromParameter:(UInt32)p
                         atTime:(CMTime)t {
  if(self.readHook) { void (^hook)(void)=self.readHook; self.readHook=nil; hook(); }
  if (self.failReadParameter == p)
    return NO;
  for (NSDictionary *entry in [self lane:p])
    if (fabs([entry[@"time"] doubleValue] - CMTimeGetSeconds(t)) < 1e-6) {
      *value = entry[@"value"];
      return YES;
    }
  *value = self.blobs[@(p)];
  return *value != nil;
}
- (BOOL)setCustomParameterValue:(id)value
                    toParameter:(UInt32)p
                         atTime:(CMTime)t {
  if (self.failBlobOnce==p)
    return [super setCustomParameterValue:value toParameter:p atTime:t];
  for (NSMutableDictionary *entry in [self lane:p])
    if (fabs([entry[@"time"] doubleValue] - CMTimeGetSeconds(t)) < 1e-6)
      entry[@"value"] = value;
  return [super setCustomParameterValue:value toParameter:p atTime:t];
}
@end

static void addKey(TimingHost *h, UInt32 p, double time, id value) {
  FxKeyframe key;
  FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
  key.time = TestTime(time);
  [[h lane:p] addObject:[@{
                @"time" : @(time),
                @"value" : value,
                @"key" : [NSValue valueWithBytes:&key
                                        objCType:@encode(FxKeyframe)]
              } mutableCopy]];
}
static MMCombinedPose *combined(double x, double y, double scale,
                                double duration, BOOL available,
                                MTEasing easing, MTAddedMotion motion,
                                double amount, double speed) {
  MMCombinedPose *p = [[MMCombinedPose alloc] initWithPositionX:x
                                                      positionY:y
                                                          scale:scale
                                                       authored:YES
                                                         easing:easing
                                                    addedMotion:motion];
  return
      [p poseByReplacingTiming:[[MMPoseTiming alloc] initWithDuration:duration
                                                            available:available
                                                               amount:amount
                                                                speed:speed]];
}
static MMScalePose *scale(double x, double y, double duration, BOOL available,
                          MTEasing easing, MTAddedMotion motion, double amount,
                          double speed) {
  MMScalePose *p = [[MMScalePose alloc] initWithX:x
                                                y:y
                                         authored:YES
                                           easing:easing
                                      addedMotion:motion];
  return
      [p poseByReplacingTiming:[[MMPoseTiming alloc] initWithDuration:duration
                                                            available:available
                                                               amount:amount
                                                                speed:speed]];
}
static void assertTiming(MMPoseTiming *t, double d, BOOL a, double amount,
                         double speed) {
  assert(t.duration == d && t.available == a && t.amount == amount &&
         t.speed == speed);
}

static void testTimingCoding(void) {
  MMPoseTiming *timing = [[MMPoseTiming alloc] initWithDuration:2.5
                                                      available:YES
                                                         amount:1.7
                                                          speed:2.2];
  NSError *error = nil;
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:timing
                                       requiringSecureCoding:YES
                                                       error:&error];
  MMPoseTiming *decoded =
      [NSKeyedUnarchiver unarchivedObjectOfClass:MMPoseTiming.class
                                        fromData:data
                                           error:&error];
  assert(data && !error && [decoded isEqual:timing]);
  assertTiming(decoded, 2.5, YES, 1.7, 2.2);
  for (id pose in @[
         [combined(1, 2, 100, 2.5, YES, MTEasingLinear, MTAddedMotionWave, 1.7,
                   2.2) copy],
         [scale(100, 80, 2.5, YES, MTEasingLinear, MTAddedMotionWave, 1.7, 2.2)
             copy]
       ]) {
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:pose
                                            requiringSecureCoding:YES
                                                            error:&error];
    id restored = [NSKeyedUnarchiver unarchivedObjectOfClass:[pose class]
                                                    fromData:archive
                                                       error:&error];
    assert(restored && !error && [restored isEqual:pose]);
    assertTiming([restored timing], 2.5, YES, 1.7, 2.2);
  }
  assertTiming([MMPoseTiming new], 1.2, NO, 1, 1);
  assert(![[MMPoseTiming alloc] initWithDuration:1
                                       available:NO
                                          amount:-1
                                           speed:1]);
  assert(![[MMPoseTiming alloc] initWithDuration:1
                                       available:NO
                                          amount:1
                                           speed:0]);
}

static void testEditorModel(void) {
  TimingHost *host = [TimingHost new];
  MMCombinedPose *c0 =
      combined(0, 10, 100, 1.5, NO, MTEasingSmooth, MTAddedMotionWave, .8, 1.1);
  MMCombinedPose *c1 =
      combined(100, 50, 200, 2.0, YES, MTEasingEaseIn, MTAddedMotionNone, 1, 1);
  MMScalePose *s0 =
      scale(100, 100, 1.0, NO, MTEasingSmooth, MTAddedMotionNone, 1, 1);
  MMScalePose *s1 =
      scale(200, 150, 3.0, NO, MTEasingEaseOut, MTAddedMotionWiggle, 1.4, 1.8);
  addKey(host, MMCustomControls, 0, c0);
  addKey(host, MMCustomControls, 4, c1);
  addKey(host, MMScaleControls, 0, s0);
  addKey(host, MMScaleControls, 4, s1);
  host.blobs[@(MMCustomControls)] = c0;
  host.blobs[@(MMScaleControls)] = s0;
  MMCombinedPoseCache *cc = MMCreateCombinedPoseCache();
  MMScalePoseCache *sc = MMCreateScalePoseCache();
  host.staticValues[@(MMCombinedCacheToken)] = cc.token;
  host.staticValues[@(MMScaleCacheToken)] = sc.token;
  MMRefreshCombinedPoseCache(host, TestTime(2));
  MMRefreshScalePoseCache(host, TestTime(2));

  MMInspectorGap *gap = MMReadInspectorGap(host, MMCustomControls, TestTime(2));
  assert(gap && gap.destinationIndex == 1);
  NSUInteger editReads=host.nativeKeyReads;
  assert(MMWriteInspectorSetting(host, MMCustomControls, TestTime(2),
                                 MMInspectorDuration, 2.75));
  MMCombinedPose *editedCombined = [host lane:MMCustomControls][1][@"value"];
  assertTiming(editedCombined.timing, 2.75, YES, 1, 1);
  assert(MMWriteInspectorSetting(host, MMCustomControls, TestTime(2),
                                 MMInspectorAvailable, 0));
  editedCombined = [host lane:MMCustomControls][1][@"value"];
  assert(!editedCombined.timing.available);
  assert(MMWriteInspectorSetting(host, MMCustomControls, TestTime(2),
                                 MMInspectorEasing, MTEasingEaseOut));
  editedCombined = [host lane:MMCustomControls][1][@"value"];
  assert(editedCombined.easing == MTEasingEaseOut);
  assert(MMWriteInspectorSetting(host, MMCustomControls, TestTime(2),
                                 MMInspectorMotion, MTAddedMotionHandheld));
  editedCombined = [host lane:MMCustomControls][0][@"value"];
  assert(editedCombined.addedMotion == MTAddedMotionHandheld);
  assert(MMWriteInspectorSetting(host, MMCustomControls, TestTime(2),
                                 MMInspectorAmount, 2.2));
  assert(MMWriteInspectorSetting(host, MMCustomControls, TestTime(2),
                                 MMInspectorSpeed, 3.3));
  MMCombinedPose *out = [host lane:MMCustomControls][0][@"value"];
  assertTiming(out.timing, 1.5, NO, 2.2, 3.3);

  // Position and scale lanes retain independent timing metadata.
  assert(MMWriteInspectorSetting(host, MMScaleControls, TestTime(2),
                                 MMInspectorDuration, 4.5));
  MMScalePose *editedScale = [host lane:MMScaleControls][1][@"value"];
  assertTiming(editedScale.timing, 4.5, NO, 1.4, 1.8);
  assert(host.nativeKeyReads==editReads);
  assert([[MMReadInspectorGap(host,MMScaleControls,TestTime(2)).destinationPose timing] duration]==4.5);
  assert([[MMReadInspectorGap(host,MMCustomControls,TestTime(2)).sourcePose timing] speed]==3.3);
  NSArray *beforeFailure=sc.snapshotEntries;
  host.failBlobOnce=MMScaleControls;
  assert(!MMWriteInspectorSetting(host,MMScaleControls,TestTime(2),MMInspectorDuration,8));
  assert(sc.snapshotEntries==beforeFailure && host.nativeKeyReads==editReads);
  editedCombined = [host lane:MMCustomControls][0][@"value"];
  assertTiming(editedCombined.timing, 1.5, NO, 2.2, 3.3);
  assert(MMWriteCombinedComponent(host, cc, MMPositionX, 125, TestTime(4)));
  editedCombined = [host lane:MMCustomControls][1][@"value"];
  assert(editedCombined.positionX == 125);
  assertTiming(editedCombined.timing, 2.75, NO, 1, 1);
  assert(MMWriteScaleComponent(host, sc, MMScaleX, 240, TestTime(4)));
  editedScale = [host lane:MMScaleControls][1][@"value"];
  assert(editedScale.x == 240);
  assertTiming(editedScale.timing, 4.5, NO, 1.4, 1.8);

  NSUInteger reads = host.nativeKeyReads;
  gap = MMReadInspectorGap(host, MMCustomControls, TestTime(2));
  NSArray *graph = MMInspectorGraphSamples(gap, 9);
  assert(graph.count == 9 && host.nativeKeyReads == reads);
  for (NSUInteger i = 0; i < graph.count; i++) {
    NSPoint point = [graph[i] pointValue];
    MMCombinedPose *sample = [cc sampleAtTime:TestTime(i * .5)];
    assert(fabs(point.x - sample.positionX) < 1e-6 &&
           fabs(point.y - sample.positionY) < 1e-6);
  }
  assert(!MMWriteInspectorSetting(host, MMCustomControls, TestTime(-1),
                                  MMInspectorAmount, 2));
  assert(!MMWriteInspectorSetting(host, MMCustomControls, TestTime(5),
                                  MMInspectorAmount, 2));
}

static void testCachePublication(void) {
  for(NSNumber *parameter in @[@(MMCustomControls),@(MMScaleControls)]) {
    BOOL isScale=parameter.unsignedIntValue==MMScaleControls;
    TimingHost *host=[TimingHost new];
    id a=isScale ? (id)scale(100,100,1,NO,MTEasingSmooth,MTAddedMotionNone,1,1) : combined(0,0,100,1,NO,MTEasingSmooth,MTAddedMotionNone,1,1);
    id b=isScale ? (id)scale(200,200,1,NO,MTEasingSmooth,MTAddedMotionNone,1,1) : combined(50,50,100,1,NO,MTEasingSmooth,MTAddedMotionNone,1,1);
    addKey(host,parameter.unsignedIntValue,0,a); addKey(host,parameter.unsignedIntValue,4,b);
    host.blobs[parameter]=a;
    id cache=isScale ? (id)MMCreateScalePoseCache():MMCreateCombinedPoseCache();
    host.staticValues[@(isScale ? MMScaleCacheToken:MMCombinedCacheToken)]=[cache token];
    if(isScale) MMRefreshScalePoseCache(host,TestTime(2)); else MMRefreshCombinedPoseCache(host,TestTime(2));
    NSArray *snapshot=[cache snapshotEntries];
    MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:host];
    plugin.activeInspectorParameterID=parameter.unsignedIntValue;
    host.playhead=TestTime(2);
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,395,256) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    MMTimingEditor *panel=[[MMTimingEditor alloc] initWithPlugin:plugin];
    [window.contentView addSubview:panel];
    ICInspectorRow *duration=[panel valueForKey:@"durationRow"];
    NSArray *points=[panel valueForKeyPath:@"graph.points"];
    assert(duration.fields[0].enabled && points.count);
    // Observe the actual UI in the middle of the host read. It must not see a
    // false empty gap, clear its graph, or disable its controls.
    host.readHook=^{
      assert([cache snapshotEntries]==snapshot);
      [panel refresh];
      assert(duration.fields[0].enabled);
      assert([panel valueForKeyPath:@"graph.points"]==points);
    };
    if(isScale) MMRefreshScalePoseCache(host,host.playhead); else MMRefreshCombinedPoseCache(host,host.playhead);
    assert(!host.readHook);
    [panel refresh];
    assert(duration.fields[0].enabled && [panel valueForKeyPath:@"graph.points"]==points);
    // A completed failure still invalidates the snapshot, unlike an in-flight read.
    host.failReadParameter=parameter.unsignedIntValue;
    if(isScale) MMRefreshScalePoseCache(host,host.playhead); else MMRefreshCombinedPoseCache(host,host.playhead);
    [panel refresh];
    assert(![cache snapshotEntries] && !duration.fields[0].enabled);
    assert([[panel valueForKeyPath:@"graph.points"] count]==0);
    host.failReadParameter=0;
    if(isScale) MMRefreshScalePoseCache(host,host.playhead); else MMRefreshCombinedPoseCache(host,host.playhead);
    [panel refresh]; assert(duration.fields[0].enabled);
    [panel removeFromSuperview]; [window close];
    snapshot=[cache snapshotEntries];
    NSUInteger reads=host.nativeKeyReads;
    id changed=[b poseByReplacingTiming:[[MMPoseTiming alloc] initWithDuration:3 available:NO amount:1 speed:1]];
    // Recover an unavailable cache from a known successful write snapshot.
    [cache setValue:nil forKey:@"entries"];
    NSUInteger generation=[[cache valueForKey:@"generation"] unsignedIntegerValue];
    [cache publishPose:changed atTime:TestTime(4) inSnapshot:snapshot];
    assert([[cache valueForKey:@"generation"] unsignedIntegerValue]>generation);
    assert([cache snapshotEntries].count==2);
    assert([[cache snapshotEntries][1][@"pose"] isEqual:changed]);
    assert([snapshot[1][@"pose"] isEqual:b]); // retained immutable snapshot
    // A completed newer snapshot removed the key. Do not restore the old one.
    [cache setValue:@[] forKey:@"entries"];
    [cache publishPose:changed atTime:TestTime(4) inSnapshot:snapshot];
    assert([cache snapshotEntries].count==0 && host.nativeKeyReads==reads);
  }
}
static void testDurationEvaluation(void) {
  MMCombinedPose *a =
      combined(0, 0, 100, 1.2, NO, MTEasingSmooth, MTAddedMotionNone, 1, 1);
  MMCombinedPose *b =
      combined(100, 50, 100, 1, NO, MTEasingSmooth, MTAddedMotionNone, 1, 1);
  NSArray *entries = @[
    @{@"time" : @0,
      @"pose" : a},
    @{@"time" : @4,
      @"pose" : b}
  ];
  assert(MMSampleCombinedSnapshot(entries, TestTime(2)).positionX == 0);
  assert(fabs(MMSampleCombinedSnapshot(entries, TestTime(3.5)).positionX - 50) <
         1e-6);
  b = [b poseByReplacingTiming:[[MMPoseTiming alloc] initWithDuration:1
                                                            available:YES
                                                               amount:1
                                                                speed:1]];
  entries = @[ @{@"time" : @0, @"pose" : a}, @{@"time" : @4, @"pose" : b} ];
  assert(fabs(MMSampleCombinedSnapshot(entries, TestTime(2)).positionX - 50) <
         1e-6);
  assert(MMSampleCombinedSnapshot(entries, TestTime(4)).positionX == 100);
  MMScalePose *s0 =
      scale(100, 50, 1.2, NO, MTEasingSmooth, MTAddedMotionNone, 1, 1);
  MMScalePose *s1 =
      scale(200, 100, 1, YES, MTEasingLinear, MTAddedMotionNone, 1, 1);
  entries = @[ @{@"time" : @0, @"pose" : s0}, @{@"time" : @4, @"pose" : s1} ];
  assert(fabs(MMSampleScaleSnapshot(entries, TestTime(1)).x - 125) < 1e-6);
}
static void testEditorActions(void) {
  [NSApplication sharedApplication];
  TimingHost *host = [TimingHost new];
  host.playhead = TestTime(2);
  MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:host];
  host.plugin = plugin;
  assert([plugin addParametersWithError:nil]);
  addKey(host, MMScaleControls, 0,
         scale(100, 100, 1.2, NO, MTEasingSmooth, MTAddedMotionWave, 1, 1));
  addKey(host, MMScaleControls, 4,
         scale(200, 200, 1.2, NO, MTEasingSmooth, MTAddedMotionNone, 1, 1));
  MMScalePoseCache *cache = MMCreateScalePoseCache();
  host.staticValues[@(MMScaleCacheToken)] = cache.token;
  MMRefreshScalePoseCache(host, host.playhead);
  plugin.activeInspectorParameterID = MMScaleControls;
  NSWindow *window =
      [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 395, 256)
                                  styleMask:NSWindowStyleMaskBorderless
                                    backing:NSBackingStoreBuffered
                                      defer:NO];
  window.releasedWhenClosed = NO;
  MMTimingEditor *panel = [[MMTimingEditor alloc] initWithPlugin:plugin];
  [window.contentView addSubview:panel];
  ICInspectorRow *duration = [panel valueForKey:@"durationRow"];
  assert(duration.fields[0].enabled && duration.fields[0].doubleValue == 1.2);
  assert([[[panel valueForKey:@"gapLabel"] stringValue] isEqualToString:@"0s → 4s"]);
  for(NSView *view in panel.subviews)
    if([view isKindOfClass:NSTextField.class])
      assert(![[(NSTextField *)view stringValue] isEqualToString:@"X —   Y ···"]);
  for(NSNumber *parameter in @[@(MMCustomControls),@(MMOpacityControls),@(MMScaleControls)]) {
    plugin.activeInspectorParameterID=parameter.unsignedIntValue;
    [panel refresh];
    assert([[panel valueForKeyPath:@"graph.componentColors"] isEqualToArray:MMInspectorColors(parameter.unsignedIntValue)]);
  }
  NSUInteger groups = host.undoGroupsStarted, reads = host.nativeKeyReads;
  NSArray *plotted = [panel valueForKeyPath:@"graph.points"];
  [panel refresh];
  assert([panel valueForKeyPath:@"graph.points"] == plotted);
  assert(host.nativeKeyReads == reads && !host.actions);
  // Real render callbacks publish fresh arrays even when animation is
  // unchanged. Recreate pose objects too: identity equality would miss this
  // case.
  NSView *graph = [panel valueForKey:@"graph"];
  graph.frame = NSMakeRect(0, 0, 350, 100);
  [graph performSelector:@selector(prepareCurves)];
  NSArray *paths = [graph valueForKey:@"curvePaths"];
  for (NSUInteger i = 0; i < 12; i++) {
    for (NSMutableDictionary *entry in [host lane:MMScaleControls]) {
      NSData *data = [NSKeyedArchiver archivedDataWithRootObject:entry[@"value"]
                                           requiringSecureCoding:YES
                                                           error:nil];
      entry[@"value"] =
          [NSKeyedUnarchiver unarchivedObjectOfClass:MMScalePose.class
                                            fromData:data
                                               error:nil];
    }
    host.playhead = TestTime(0.2 + i * 0.2);
    CMTime renderTime = host.playhead;
    NSValue *time = [NSValue valueWithBytes:&renderTime
                                   objCType:@encode(CMTime)];
    BOOL active = NO;
    assert(MMReadScalePoseSamples(host, @[ time ], &active, nil) && active);
    NSUInteger afterRender = host.nativeKeyReads;
    [panel refresh];
    assert([panel valueForKeyPath:@"graph.points"] == plotted);
    assert(fabs([[graph valueForKey:@"progress"] doubleValue] -
                CMTimeGetSeconds(host.playhead) / 4) < 1e-6);
    [graph performSelector:@selector(prepareCurves)];
    assert([graph valueForKey:@"curvePaths"] == paths);
    assert(host.nativeKeyReads == afterRender && !host.actions);
  }
  graph.frame = NSMakeRect(0, 0, 400, 100);
  [graph performSelector:@selector(prepareCurves)];
  assert([graph valueForKey:@"curvePaths"] != paths);
  duration.fields[0].doubleValue = 2;
  duration.onValueCommit(duration.fields[0]);
  assert([panel valueForKeyPath:@"graph.points"] != plotted);
  assert(host.undoGroupsStarted == groups + 1 && host.undoDepth == 0 &&
         !host.actions);
  groups = host.undoGroupsStarted;
  duration.onScrubBegin();
  duration.fields[0].doubleValue = 2.5;
  duration.onValueCommit(duration.fields[0]);
  duration.fields[0].doubleValue = 3;
  duration.onValueCommit(duration.fields[0]);
  duration.onScrubEnd();
  assert(host.undoGroupsStarted == groups + 1 && host.undoDepth == 0 &&
         !host.actions);
  assertTiming([[host lane:MMScaleControls][1][@"value"] timing], 3, NO, 1, 1);
  host.playhead = TestTime(5);
  [panel refresh];
  assert(!duration.fields[0].enabled);
  plugin.activeInspectorParameterID=MMCustomControls;
  [panel refresh];
  assert(plugin.activeInspectorParameterID == MMCustomControls &&
         !duration.fields[0].enabled);
  [panel removeFromSuperview];
  [window close];
}
int main(void) {
  @autoreleasepool {
    testTimingCoding();
    testEditorModel();
    testCachePublication();
    testDurationEvaluation();
    testEditorActions();
  }
  puts("TimingEditor: secure timing metadata, cached graph sampling, "
       "independent lanes and bounded writes passed");
}
