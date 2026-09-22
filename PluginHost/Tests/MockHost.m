/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import <float.h>

@implementation MockHost
- (instancetype)init {
  if ((self = [super init])) {
    _lanes = [NSMutableDictionary new];
    _blobs = [NSMutableDictionary new];
    _editors = [NSMutableDictionary new];
    _pendingCallbacks = [NSMutableArray new];
    _definitions = [NSMutableDictionary new];
    _registrationOrder = [NSMutableArray new];
    _flags = [NSMutableDictionary new];
    _staticValues = [NSMutableDictionary new];
    _effectStart = TestTime(0);
    _effectDuration = TestTime(10);
    _frameDuration = TestTime(1.0 / 30.0);
  }
  return self;
}
- (void)startTimeForEffect:(CMTime *)startTime { *startTime = self.effectStart; }
- (void)durationTimeForEffect:(CMTime *)duration { *duration = self.effectDuration; }
- (void)frameDuration:(CMTime *)duration { *duration = self.frameDuration; }
- (void)notifyParameter:(UInt32)p atTime:(CMTime)t {
  if (!self.plugin)
    return;
  if (self.deferCallbacks)
    [self.pendingCallbacks addObject:@[
      @(p), [NSValue valueWithBytes:&t objCType:@encode(CMTime)]
    ]];
  else
    [self.plugin parameterChanged:p atTime:t error:nil];
}
- (BOOL)drainCallbacks {
  // A bounded queue detects feedback without hanging the test runner.
  for (NSUInteger i = 0; i < 200 && self.pendingCallbacks.count; ++i) {
    NSArray *event = self.pendingCallbacks.firstObject;
    [self.pendingCallbacks removeObjectAtIndex:0];
    NSError *error = nil;
    CMTime eventTime;
    [event[1] getValue:&eventTime];
    assert([self.plugin parameterChanged:[event[0] unsignedIntValue]
                                  atTime:eventTime
                                   error:&error]);
  }
  return self.pendingCallbacks.count == 0;
}
- (BOOL)startUndoGroup:(NSString *)name {
  self.undoGroupsStarted++; self.undoDepth++; return YES;
}
- (BOOL)endUndoGroup {
  assert(self.undoDepth > 0);
  self.undoGroupsEnded++; self.undoDepth--; return YES;
}
- (id)apiForProtocol:(Protocol *)protocol {
  return [self.missingProtocols containsObject:NSStringFromProtocol(protocol)]
             ? nil
             : self;
}
- (BOOL)addPopupMenuWithName:(NSString *)name parameterID:(UInt32)p defaultValue:(UInt32)value menuEntries:(NSArray *)entries parameterFlags:(FxParameterFlags)flags {
  self.definitions[@(p)] = @{@"name":name, @"kind":@"popup", @"entries":entries};
  self.flags[@(p)] = @(flags); self.editors[@(p)] = @(value);
  [self.registrationOrder addObject:@(p)];
  return YES;
}
- (BOOL)getIntValue:(int *)value fromParameter:(UInt32)p atTime:(CMTime)time {
  if (self.failReadParameter == p) return NO;
  if ([self.strictReadParameters containsObject:@(p)] && !_editors[@(p)]) return NO;
  *value = [self.editors[@(p)] intValue]; return YES;
}
- (BOOL)setIntValue:(int)value toParameter:(UInt32)p atTime:(CMTime)time {
  self.hostWrites++; self.editors[@(p)] = @(value);
  [self notifyParameter:p atTime:time]; return YES;
}
- (BOOL)getStringParameterValue:(NSString **)value fromParameter:(UInt32)p {
  *value = self.staticValues[@(p)];
  return *value != nil;
}
- (BOOL)setStringParameterValue:(NSString *)value toParameter:(UInt32)p {
  self.staticValues[@(p)] = value;
  [self notifyParameter:p atTime:kCMTimeZero];
  return YES;
}
- (BOOL)addStringParameterWithName:(NSString *)name parameterID:(UInt32)p defaultValue:(NSString *)value parameterFlags:(FxParameterFlags)flags {
  self.definitions[@(p)] = @{@"name":name, @"kind":@"string"};
  self.flags[@(p)] = @(flags);
  [self.registrationOrder addObject:@(p)];
  self.staticValues[@(p)] = value;
  return YES;
}
- (BOOL)addFloatSliderWithName:(NSString *)name
                   parameterID:(UInt32)p
                  defaultValue:(double)v
                  parameterMin:(double)lo
                  parameterMax:(double)hi
                     sliderMin:(double)slo
                     sliderMax:(double)shi
                         delta:(double)delta
                parameterFlags:(FxParameterFlags)flags {
  assert(!self.definitions[@(p)]);
  self.definitions[@(p)] = @{
    @"name" : name,
    @"kind" : @"float",
    @"default" : @(v),
    @"min" : @(lo),
    @"max" : @(hi)
  };
  self.flags[@(p)] = @(flags);
  [self.registrationOrder addObject:@(p)];
  self.staticValues[@(p)] = @(v);
  self.editors[@(p)] = @(v);
  return YES;
}
- (BOOL)addIntSliderWithName:(NSString *)name
                  parameterID:(UInt32)p
                 defaultValue:(int)v
                  parameterMin:(int)lo
                  parameterMax:(int)hi
                     sliderMin:(int)slo
                     sliderMax:(int)shi
                         delta:(int)delta
                parameterFlags:(FxParameterFlags)flags {
  assert(!self.definitions[@(p)]);
  self.definitions[@(p)] = @{
    @"name" : name,
    @"kind" : @"int",
    @"default" : @(v),
    @"min" : @(lo),
    @"max" : @(hi),
    @"delta" : @(delta)
  };
  self.flags[@(p)] = @(flags);
  [self.registrationOrder addObject:@(p)];
  self.editors[@(p)] = @(v);
  return YES;
}
- (BOOL)addToggleButtonWithName:(NSString *)name
                    parameterID:(UInt32)p
                   defaultValue:(BOOL)v
                 parameterFlags:(FxParameterFlags)flags {
  assert(!self.definitions[@(p)]);
  self.definitions[@(p)] =
      @{@"name" : name, @"kind" : @"toggle", @"default" : @(v)};
  self.flags[@(p)] = @(flags);
  [self.registrationOrder addObject:@(p)];
  self.editors[@(p)] = @(v);
  return YES;
}
- (BOOL)addCustomParameterWithName:(NSString *)name
                       parameterID:(UInt32)p
                      defaultValue:(id)v
                    parameterFlags:(FxParameterFlags)flags {
  assert(!self.definitions[@(p)]);
  self.definitions[@(p)] = @{@"name" : name, @"kind" : @"blob"};
  self.flags[@(p)] = @(flags);
  [self.registrationOrder addObject:@(p)];
  self.blobs[@(p)] = v;
  return YES;
}
- (NSMutableArray *)lane:(NSUInteger)p {
  if (!_lanes[@(p)])
    _lanes[@(p)] = [NSMutableArray new];
  return _lanes[@(p)];
}
- (void)sort:(NSUInteger)p {
  [[self lane:p] sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                         NSDictionary *b) {
    return [a[@"time"] compare:b[@"time"]];
  }];
}
- (NSError *)keyframeCount:(NSUInteger *)n
              forParameter:(NSUInteger)p
                andChannel:(NSUInteger)c {
  self.nativeKeyReads++;
  *n = [self lane:p].count;
  return nil;
}
- (NSError *)keyframe:(FxKeyframe *)k
         forParameter:(NSUInteger)p
              channel:(NSUInteger)c
             andIndex:(NSUInteger)i {
  self.nativeKeyReads++;
  [((NSDictionary *)[self lane:p][i])[@"key"] getValue:k];
  return nil;
}
- (BOOL)getFloatValue:(double *)v fromParameter:(UInt32)p atTime:(CMTime)t {
  if (self.failReadParameter == p)
    return NO;
  if ([self.strictReadParameters containsObject:@(p)] && !_editors[@(p)]) return NO;
  *v = [_editors[@(p)] doubleValue];
  return YES;
}
- (BOOL)getBoolValue:(BOOL *)v fromParameter:(UInt32)p atTime:(CMTime)t {
  if (self.failReadParameter == p)
    return NO;
  *v = [_editors[@(p)] boolValue];
  return YES;
}
- (BOOL)setBoolValue:(BOOL)v toParameter:(UInt32)p atTime:(CMTime)t {
  self.hostWrites++;
  _editors[@(p)] = @(v);
  [self notifyParameter:p atTime:t];
  return YES;
}
- (BOOL)setFloatValue:(double)v toParameter:(UInt32)p atTime:(CMTime)t {
  self.hostWrites++;
  _editors[@(p)] = @(v);
  [self notifyParameter:p atTime:t];
  return YES;
}
- (BOOL)getParameterFlags:(FxParameterFlags *)flags fromParameter:(UInt32)p {
  NSNumber *value = self.flags[@(p)];
  if (!value) return NO;
  *flags = value.unsignedIntValue;
  return YES;
}

- (BOOL)setParameterFlags:(FxParameterFlags)f toParameter:(UInt32)p {
  self.hostWrites++;
  self.flagWrites++;
  self.flags[@(p)] = @(f);
  return YES;
}
- (BOOL)getCustomParameterValue:
            (NSObject<NSSecureCoding, NSCopying> *_Nullable *)v
                  fromParameter:(UInt32)p
                         atTime:(CMTime)t {
  if (self.failReadParameter == p)
    return NO;
  *v = _blobs[@(p)];
  return YES;
}
- (BOOL)setCustomParameterValue:(id)v toParameter:(UInt32)p atTime:(CMTime)t {
  self.hostWrites++;
  self.blobWrites++;
  if (_failBlobOnce == p) {
    _failBlobOnce = 0;
    return NO;
  }
  _blobs[@(p)] = v;
  [self notifyParameter:p atTime:t];
  return YES;
}
- (NSError *)addKeyframe:(const FxKeyframe *)k
             toParameter:(NSUInteger)p
              andChannel:(NSUInteger)c {
  if (_failAddOnce) {
    _failAddOnce = NO;
    return [NSError errorWithDomain:@"MockHost" code:2 userInfo:nil];
  }
  double v = 0;
  [self getFloatValue:&v fromParameter:(UInt32)p atTime:k->time];
  [[self lane:p] addObject:[@{
                   @"time" : @(CMTimeGetSeconds(k->time)),
                   @"value" : @(v),
                   @"key" : [NSValue valueWithBytes:k
                                           objCType:@encode(FxKeyframe)]
                 } mutableCopy]];
  [self sort:p];
  _mutations++;
  [self notifyParameter:(UInt32)p atTime:k->time];
  return nil;
}
- (NSError *)setKeyframeIndex:(NSUInteger)i
                 withKeyframe:(const FxKeyframe *)k
                 forParameter:(NSUInteger)p
                   andChannel:(NSUInteger)c {
  if (_failMoveOnce) {
    _failMoveOnce = NO;
    return [NSError errorWithDomain:@"MockHost" code:1 userInfo:nil];
  }
  // The shipped remote FxPlug move wrapper drops the index. Native user
  // edits (helpers temporarily detach plugin) do not use that wrapper.
  if (_ignorePluginMoveIndex && self.plugin) i = 0;
  NSMutableDictionary *d = [self lane:p][i];
  d[@"time"] = @(CMTimeGetSeconds(k->time));
  d[@"key"] = [NSValue valueWithBytes:k objCType:@encode(FxKeyframe)];
  [self sort:p];
  _mutations++;
  [self notifyParameter:(UInt32)p atTime:k->time];
  return nil;
}
- (NSError *)removeKeyframeAtIndex:(NSUInteger)i
                     fromParameter:(NSUInteger)p
                        andChannel:(NSUInteger)c {
  [[self lane:p] removeObjectAtIndex:i];
  _mutations++;
  [self notifyParameter:(UInt32)p atTime:kCMTimeZero];
  return nil;
}
- (NSError *)removeAllKeyframesForParameter:(NSUInteger)p
                                 andChannel:(NSUInteger)c {
  [[self lane:p] removeAllObjects];
  _mutations++;
  return nil;
}
@end

CMTime TestTime(double t) { return CMTimeMakeWithSeconds(t, 600); }
