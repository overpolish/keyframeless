/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Plugin_Private.h"
#import "Constants.h"
#import "MMCombinedPose.h"
#import <Cocoa/Cocoa.h>

// KKPlugin implements the view host in a private category.
@interface KKPlugin (MMCustomRowHost)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
@end

// Capability test: one view attached to a separate custom parameter edits
// one combined pose. Host keyframe controls remain entirely host-provided.
@interface MMCustomRow : NSView
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, copy) NSArray<NSTextField *> *fields;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, strong) MMCombinedPoseCache *poseCache;
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager;
@end

@implementation MMCustomRow
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager {
  self = [super initWithFrame:NSMakeRect(0, 0, 220, 54)];
  if (!self) return nil;
  _manager = manager;
  NSMutableArray *fields = [NSMutableArray array];
  for (NSUInteger i=0; i<2; ++i) {
    NSTextField *label = [NSTextField labelWithString:i == 0 ? @"Position X" : @"Scale"];
    label.frame = NSMakeRect(0, 28-i*26, 80, 22);
    label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [self addSubview:label];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(84, 28-i*26, 130, 22)];
    field.autoresizingMask = NSViewWidthSizable;
    field.tag = i == 0 ? MMPositionX : MMScale;
    field.doubleValue = i == 0 ? 0 : 100;
    field.target = self; field.action = @selector(commitValue:);
    field.accessibilityLabel = label.stringValue;
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO;
    formatter.maximumFractionDigits = 4;
    formatter.minimum = i == 0 ? @(-200) : @0;
    formatter.maximum = i == 0 ? @200 : @400;
    field.formatter = formatter;
    [self addSubview:field]; [fields addObject:field];
  }
  _fields = fields;
  _poseCache = MMCreateCombinedPoseCache();
  id<FxCustomParameterActionAPI_v4> action = [manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (action) {
    [action startAction:self];
    @try {
      id<FxParameterSettingAPI_v5> set = [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [set setStringParameterValue:_poseCache.token toParameter:MMCombinedCacheToken];
    } @finally { [action endAction:self]; }
  }
  return self;
}
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 54); }
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self.refreshTimer invalidate]; self.refreshTimer = nil;
  if (!self.window) return;
  __weak MMCustomRow *weakSelf = self;
  self.refreshTimer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
    MMCustomRow *view = weakSelf;
    if (!view) { [timer invalidate]; return; }
    [view refreshValues];
  }];
  [[NSRunLoop mainRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}
- (void)dealloc { [_refreshTimer invalidate]; }
- (void)refreshValues {
  // Cached sampling is read-only and may run while the host playhead is dragged.
  // Native linked-key writes still retain their separate mouse-up guard.
  if (!self.window || self.hiddenOrHasHiddenAncestor) return;
  for (NSTextField *field in self.fields) if (field.currentEditor) return;
  id<FxCustomParameterActionAPI_v4> action = [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return;
  [action startAction:self];
  @try {
    CMTime time = [action currentTime];
    MMCombinedPose *pose = [self.poseCache sampleAtTime:time];
    id<FxParameterRetrievalAPI_v6> get = [self.manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    BOOL explicit = NO;
    if (![get getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:time]) return;
    if (explicit) {
      CMTime target;
      pose = [self.poseCache valueTargetAtTime:time targetTime:&target] ? [self.poseCache sampleAtTime:target] : nil;
    }
    for (NSTextField *field in self.fields) field.enabled = pose != nil;
    if (!pose) return;
    for (NSTextField *field in self.fields) {
      double value = field.tag == MMPositionX ? pose.positionX : pose.scale;
      if (field.doubleValue != value) field.doubleValue = value;
    }
  } @finally { [action endAction:self]; }
}
- (void)commitValue:(NSTextField *)field {
  id<FxCustomParameterActionAPI_v4> action = [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) { NSBeep(); return; }
  [action startAction:self];
  @try {
    if (!MMWriteCombinedComponent(self.manager,self.poseCache,(UInt32)field.tag,
                                  field.doubleValue,[action currentTime])) NSBeep();
  } @finally {
    [action endAction:self];
  }
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (CustomRow)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == MMCustomControls) return [[MMCustomRow alloc] initWithManager:self.apiManager];
  return [super createViewForParameterID:parameterID];
}
@end

#pragma clang diagnostic pop
