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
@property NSUInteger seeks;
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
- (BOOL)movePlayheadToTime:(CMTime)time error:(NSError **)error {
  (void)error;
  assert(self.actions>0);
  self.seeks++;
  self.playhead=time;
  return NO; // FCP may report failure even though the seek applied.
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
  for (NSString *key in @[@"easingMenu", @"motionMenu"]) {
    NSPopUpButton *menu=[panel valueForKey:key];
    assert(menu.controlSize==NSControlSizeRegular);
    assert([menu.font isEqual:[NSFont menuFontOfSize:0]]);
    for (NSMenuItem *item in menu.itemArray) {
      assert(item.image && item.image.isTemplate);
      assert(NSEqualSizes(item.image.size,NSMakeSize(28,16)));
      assert(item.title.length>0);
    }
  }
  ICInspectorRow *duration = [panel valueForKey:@"durationRow"];
  assert(duration.fields[0].enabled && duration.fields[0].doubleValue == 1.2);
  assert([[[panel valueForKey:@"motionLabel"] stringValue] isEqualToString:@"Scale Added Motion"]);
  [panel layoutSubtreeIfNeeded];
  NSButton *availableButton=[panel valueForKey:@"available"];
  NSButton *seedButton=[panel valueForKey:@"seedButton"];
  assert(availableButton.image && !availableButton.bordered);
  assert([availableButton.toolTip isEqualToString:@"Use all available time between keyframes."]);
  assert(fabs(NSMidX(availableButton.frame)-NSMidX(seedButton.frame))<1e-9);
  NSTextField *easingLabel=[panel valueForKey:@"easingLabel"];
  assert([easingLabel.stringValue isEqualToString:@"Easing"]);
  NSBox *separator=[panel valueForKey:@"motionSeparator"];
  assert(separator.boxType==NSBoxSeparator && NSMaxY(separator.frame)<=NSMinY(easingLabel.frame));
  NSView *preview=[panel valueForKey:@"graph"];
  assert(NSWidth(separator.frame)==48 && fabs(NSMidX(separator.frame)-NSMidX(preview.frame))<1e-9);
  assert(NSMinY(easingLabel.frame)-NSMaxY(separator.frame)>=12);
  NSTextField *motionLabel=[panel valueForKey:@"motionLabel"];
  assert(NSMinY(separator.frame)-NSMaxY(motionLabel.frame)>=12);
  NSTextField *suffix=duration.unitLabels.lastObject;
  CGFloat suffixCenter=NSMinY(duration.frame)+NSMaxY(suffix.frame)-suffix.firstBaselineOffsetFromTop+suffix.font.capHeight/2;
  assert(fabs(NSMidY(availableButton.frame)-suffixCenter)<=0.25);

  availableButton.state=NSControlStateValueOn;
  [availableButton sendAction:availableButton.action to:availableButton.target];
  assert(!duration.enabled && [availableButton.contentTintColor isEqual:ICInspectorTokens.accentMatchingHost]);
  availableButton.state=NSControlStateValueOff;
  [availableButton sendAction:availableButton.action to:availableButton.target];
  assert(duration.enabled && [availableButton.contentTintColor isEqual:ICInspectorTokens.decorationColor]);

  ICPopUpButton *motionMenu=[panel valueForKey:@"motionMenu"];
  NSInteger originalMotion=motionMenu.indexOfSelectedItem;
  // Native tracking has selected a new option, but its action has not run yet.
  [motionMenu setValue:@1 forKey:@"interactionDepth"];
  [motionMenu selectItemAtIndex:MTAddedMotionWiggle];
  [panel refresh];
  assert(motionMenu.indexOfSelectedItem==MTAddedMotionWiggle);
  [panel menuChanged:motionMenu];
  [motionMenu setValue:@0 forKey:@"interactionDepth"];
  [panel refresh];
  assert(motionMenu.indexOfSelectedItem==MTAddedMotionWiggle);
  // Outside tracking the host is authoritative again, as with undo or scrubbing.
  [motionMenu selectItemAtIndex:originalMotion];
  [panel menuChanged:motionMenu];
  [motionMenu selectItemAtIndex:MTAddedMotionWiggle];
  [panel refresh];
  assert(motionMenu.indexOfSelectedItem==originalMotion);

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
  for (ICInspectorRow *disabledRow in @[duration, [panel valueForKey:@"motionRow"]]) {
    assert([disabledRow.titleLabel.textColor isEqual:ICInspectorTokens.disabledTextColor]);
    for (NSTextField *decoration in [disabledRow.axisLabels arrayByAddingObjectsFromArray:disabledRow.unitLabels])
      assert([decoration.textColor isEqual:ICInspectorTokens.disabledTextColor]);
  }
  plugin.activeInspectorParameterID=MMCustomControls;
  [panel refresh];
  assert(plugin.activeInspectorParameterID == MMCustomControls &&
         !duration.fields[0].enabled);
  assert([[[panel valueForKey:@"motionLabel"] stringValue] isEqualToString:@"Position Added Motion"]);
  [panel removeFromSuperview];
  [window close];
}
static void testStaggeredLinkedGraph(void) {
  TimingHost *host=[TimingHost new];
  MMCombinedPoseCache *positionCache=MMCreateCombinedPoseCache();
  MMScalePoseCache *scaleCache=MMCreateScalePoseCache();
  host.staticValues[@(MMCombinedCacheToken)]=positionCache.token;
  host.staticValues[@(MMScaleCacheToken)]=scaleCache.token;
  MMCombinedPose *p0=combined(0,10,100,1,NO,MTEasingSmooth,MTAddedMotionWave,1,1);
  MMCombinedPose *p1=combined(80,50,100,1,NO,MTEasingSmooth,MTAddedMotionNone,1,1);
  MMScalePose *s0=scale(100,110,1,NO,MTEasingSmooth,MTAddedMotionWave,1,1);
  MMScalePose *s1=scale(150,160,1,NO,MTEasingSmooth,MTAddedMotionNone,1,1);
  p1=[p1 poseByReplacingTiming:[p1.timing timingByReplacingLinkID:@"shared-end"]];
  s1=[s1 poseByReplacingTiming:[s1.timing timingByReplacingLinkID:@"shared-end"]];
  addKey(host,MMCustomControls,0,p0); addKey(host,MMCustomControls,4,p1);
  addKey(host,MMScaleControls,2,s0); addKey(host,MMScaleControls,4,s1);
  host.blobs[@(MMScaleControls)]=s0; // Host returns the held value before its first key.
  MMRefreshCombinedPoseCache(host,TestTime(1)); MMRefreshScalePoseCache(host,TestTime(1));
  NSUInteger reads=host.nativeKeyReads;
  NSArray<MMInspectorGap *> *gaps=MMReadInspectorGraphGaps(host,MMScaleControls,TestTime(1));
  assert(gaps.count==2 && CMTimeCompare(MMInspectorGraphStart(gaps),TestTime(0))==0);
  NSArray *starts=MMInspectorGraphStartFractions(gaps);
  assert(([starts isEqualToArray:@[@0,@0,@0.5,@0.5]]));
  assert(MMReadInspectorGraphGaps(host,MMCustomControls,TestTime(3)).count==2);
  assert(MMReadInspectorGraphGaps(host,MMCustomControls,TestTime(4)).count==2);
  assert(MMReadInspectorGraphGaps(host,MMCustomControls,TestTime(5)).count==0);
  NSArray *points=MMInspectorCombinedGraphPoints(gaps,65,CGSizeMake(100,100));
  assert(points.count==65 && [points[0] count]==4 && host.nativeKeyReads==reads);
  // Each property retains exactly the evaluated shape, fitted independently
  // because their units differ. Includes outgoing wave + incoming easing.
  for (NSUInteger property=0;property<2;property++) {
    NSArray *raw=MMInspectorGraphComponents(gaps[property],65);
    double low=INFINITY,high=-INFINITY;
    for (NSArray *sample in raw) for (NSNumber *value in sample) { low=fmin(low,value.doubleValue); high=fmax(high,value.doubleValue); }
    for (NSUInteger i=0;i<65;i++) for (NSUInteger axis=0;axis<2;axis++)
      assert(fabs([points[i][property*2+axis] doubleValue]-([raw[i][axis] doubleValue]-low)/(high-low))<1e-9);
  }
  NSView *graph=[[NSClassFromString(@"MMGapGraph") alloc] initWithFrame:NSMakeRect(0,0,400,114)];
  [graph setValue:points forKey:@"points"]; [graph setValue:starts forKey:@"startFractions"];
  [graph performSelector:@selector(prepareCurves)];
  NSArray<NSBezierPath *> *paths=[graph valueForKey:@"curvePaths"];
  NSPoint early,late,end;
  [paths[0] elementAtIndex:0 associatedPoints:&early];
  [paths[2] elementAtIndex:0 associatedPoints:&late];
  [paths[2] elementAtIndex:paths[2].elementCount-1 associatedPoints:&end];
  assert(fabs(early.x-8)<1e-6 && fabs(late.x-200)<1e-6 && fabs(end.x-392)<1e-6);
  [NSApplication sharedApplication];
  host.playhead=TestTime(3);
  MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:host];
  plugin.activeInspectorParameterID=MMScaleControls;
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,395,256) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;
  MMTimingEditor *panel=[[MMTimingEditor alloc] initWithPlugin:plugin];
  [window.contentView addSubview:panel];
  [panel refresh];
  assert(([plugin.graphedInspectorParameters isEqualToSet:[NSSet setWithArray:@[@(MMCustomControls),@(MMScaleControls)]]]));
  [panel layoutSubtreeIfNeeded];
  NSView *scrubGraph=[panel valueForKey:@"graph"];
  NSUInteger writes=host.hostWrites, groups=host.undoGroupsStarted;
  NSEvent *(^event)(NSEventType,double)=^NSEvent *(NSEventType type,double fraction) {
    NSRect plot=NSInsetRect(scrubGraph.bounds,8,8);
    NSPoint p=[scrubGraph convertPoint:NSMakePoint(NSMinX(plot)+fraction*NSWidth(plot),NSMidY(plot)) toView:nil];
    return [NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:0
        windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
  };
  [scrubGraph mouseDown:event(NSEventTypeLeftMouseDown,0.25)];
  assert(fabs(CMTimeGetSeconds(host.playhead)-1)<1e-6);
  [panel refresh]; // selected Scale has not started, but the combined range stays fixed.
  [scrubGraph mouseDragged:event(NSEventTypeLeftMouseDragged,-1)];
  assert(CMTimeCompare(host.playhead,TestTime(0))==0);
  [panel refresh];
  [scrubGraph mouseDragged:event(NSEventTypeLeftMouseDragged,2)];
  assert(CMTimeCompare(host.playhead,TestTime(4))==0);
  [scrubGraph mouseUp:event(NSEventTypeLeftMouseUp,0.75)];
  assert(CMTimeCompare(host.playhead,TestTime(3))==0);
  assert(host.seeks==4 && host.actions==0);
  assert(host.hostWrites==writes && host.undoGroupsStarted==groups);
  host.missingProtocols=[NSSet setWithObject:NSStringFromProtocol(@protocol(FxCommandAPI_v2))];
  [scrubGraph mouseDown:event(NSEventTypeLeftMouseDown,0.5)];
  [scrubGraph mouseUp:event(NSEventTypeLeftMouseUp,0.5)];
  assert(host.seeks==4 && host.actions==0);
  host.missingProtocols=[NSSet set];
  s1=[s1 poseByReplacingTiming:[s1.timing timingByReplacingLinkID:@""]];
  [host lane:MMScaleControls][1][@"value"]=s1;
  MMRefreshScalePoseCache(host,TestTime(3));
  assert(MMReadInspectorGraphGaps(host,MMCustomControls,TestTime(3)).count==1);
  [panel refresh];
  assert([plugin.graphedInspectorParameters isEqualToSet:[NSSet setWithObject:@(MMScaleControls)]]);
  [panel removeFromSuperview];
  assert(plugin.graphedInspectorParameters.count==0);
  [window close];
}

static void testMotionOptionsAndReset(void) {
  // Position's internal storage is X, legacy scale, Y. UI masks refer to X/Y.
  MMCombinedPose *p0=combined(100,100,100,1.2,NO,MTEasingSmooth,MTAddedMotionWave,2,1);
  p0=[p0 poseByReplacingTiming:[p0.timing timingByReplacingMotionSeed:17 linked:NO componentMask:2]];
  MMCombinedPose *p1=combined(100,100,100,1.2,NO,MTEasingSmooth,MTAddedMotionNone,1,1);
  NSArray *positionEntries=@[@{@"time":@0,@"pose":p0},@{@"time":@4,@"pose":p1}];
  MMCombinedPose *sample=MMSampleCombinedSnapshot(positionEntries,TestTime(0.73));
  assert(fabs(sample.positionX-100)<1e-9 && fabs(sample.scale-100)<1e-9 && fabs(sample.positionY-100)>1e-6);
  MMPoseTiming *quiet=[[[MMPoseTiming alloc] initWithDuration:1.2 available:NO amount:0 speed:1] timingByCopyingMotionOptionsFrom:p0.timing];
  positionEntries=@[@{@"time":@0,@"pose":[p0 poseByReplacingTiming:quiet]},@{@"time":@4,@"pose":p1}];
  sample=MMSampleCombinedSnapshot(positionEntries,TestTime(0.73));
  assert(fabs(sample.positionY-100)<1e-9);

  TimingHost *host=[TimingHost new]; host.playhead=TestTime(2);
  MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:host]; host.plugin=plugin;
  assert([plugin addParametersWithError:nil]);
  addKey(host,MMScaleControls,0,scale(100,100,1.2,NO,MTEasingSmooth,MTAddedMotionWave,2,3));
  addKey(host,MMScaleControls,4,scale(200,200,1.2,NO,MTEasingSmooth,MTAddedMotionNone,1,1));
  MMScalePoseCache *cache=MMCreateScalePoseCache(); host.staticValues[@(MMScaleCacheToken)]=cache.token;
  MMRefreshScalePoseCache(host,host.playhead);
  assert(MMWriteInspectorSetting(host,MMScaleControls,host.playhead,MMInspectorMotionSeed,123));
  assert(MMWriteInspectorSetting(host,MMScaleControls,host.playhead,MMInspectorMotionLinked,0));
  assert(MMWriteInspectorSetting(host,MMScaleControls,host.playhead,MMInspectorMotionMask,1));
  assert(MMWriteInspectorSetting(host,MMScaleControls,host.playhead,MMInspectorDuration,2));
  MMScalePose *source=[host lane:MMScaleControls][0][@"value"];
  assert(source.timing.motionSeed==123 && !source.timing.motionLinked && source.timing.motionComponentMask==1);
  assert(source.timing.amount==2 && source.timing.speed==3);
  assert(MMWriteInspectorSetting(host,MMScaleControls,host.playhead,MMInspectorResetMotionControls,0));
  source=[host lane:MMScaleControls][0][@"value"];
  assert(source.timing.amount==1 && source.timing.speed==1);
  assert(source.timing.motionSeed==123 && !source.timing.motionLinked && source.timing.motionComponentMask==1);
  assert(source.addedMotion==MTAddedMotionWave && [host lane:MMScaleControls].count==2);
  host.failBlobOnce=MMScaleControls;
  assert(!MMWriteInspectorSetting(host,MMScaleControls,host.playhead,MMInspectorMotionSeed,999));
  assert([(MMScalePose *)[host lane:MMScaleControls][0][@"value"] timing].motionSeed==123);
  assert(!MMWriteInspectorSetting(host,MMScaleControls,host.playhead,MMInspectorMotionMask,-1));
  assert(!MMWriteInspectorSetting(host,MMScaleControls,host.playhead,MMInspectorMotionSeed,4294967296.0));
  plugin.activeInspectorParameterID=MMScaleControls;
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,395,256) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;
  MMTimingEditor *panel=[[MMTimingEditor alloc] initWithPlugin:plugin]; [window.contentView addSubview:panel]; [panel refresh];
  ICInspectorRow *row=[panel valueForKey:@"motionRow"];
  NSMenu *reset=row.titleMenuProvider();
  assert([reset.itemArray[0].title isEqualToString:@"Reset Parameter"] && reset.itemArray[0].enabled);
  ICMenuTextField *label=[panel valueForKey:@"motionLabel"];
  NSMenu *menu=label.menuProvider();
  assert([menu.itemArray[0].title isEqualToString:@"Independent Motion"]);
  assert(menu.itemArray[0].state==NSControlStateValueOn);
  assert(menu.numberOfItems==5 && [menu.itemArray[2].title isEqualToString:@"PARAMETERS"]);
  assert(menu.itemArray[3].state==NSControlStateValueOn && menu.itemArray[4].state==NSControlStateValueOff);
  for (NSMenuItem *item in menu.itemArray) assert(!item.submenu);
  assert(menu.itemArray[3].indentationLevel==1 && menu.itemArray[4].indentationLevel==1);
  NSUInteger menuGroups=host.undoGroupsStarted;
  NSMenuItem *link=menu.itemArray[0]; [NSApp sendAction:link.action to:link.target from:link];
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  source=[host lane:MMScaleControls][0][@"value"];
  assert(source.timing.motionLinked && host.undoGroupsStarted==menuGroups+1 && host.undoDepth==0);
  assert(label.menuProvider().itemArray[0].state==NSControlStateValueOff);
  assert(host.blobs[@(MMHostRefreshToken)]);
  assert(MMWriteInspectorSetting(host,MMScaleControls,host.playhead,MMInspectorAmount,2));
  assert(MMWriteInspectorSetting(host,MMScaleControls,host.playhead,MMInspectorSpeed,3));
  NSMenuItem *resetItem=reset.itemArray[0]; [NSApp sendAction:resetItem.action to:resetItem.target from:resetItem];
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  source=[host lane:MMScaleControls][0][@"value"];
  assert(source.timing.amount==1 && source.timing.speed==1 && source.timing.motionSeed==123 && source.timing.motionComponentMask==1);
  assert(host.undoGroupsStarted==menuGroups+2 && host.undoDepth==0);
  NSUInteger groups=host.undoGroupsStarted;
  NSButton *dice=[panel valueForKey:@"seedButton"]; assert(dice.enabled);
  [dice sendAction:dice.action to:dice.target];
  assert(host.undoGroupsStarted==groups+1 && host.undoDepth==0 && host.actions==0);
  source=[host lane:MMScaleControls][0][@"value"]; assert(source.timing.motionSeed!=123);
  [panel removeFromSuperview]; [window close];
}

int main(void) {
  @autoreleasepool {
    testStaggeredLinkedGraph();
    testTimingCoding();
    testMotionOptionsAndReset();
    testEditorModel();
    testCachePublication();
    testDurationEvaluation();
    testEditorActions();
  }
  puts("TimingEditor: secure timing metadata, cached graph sampling, "
       "independent lanes and bounded writes passed");
}
