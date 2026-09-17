/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "TestLanes.h"
#import <assert.h>
#import <math.h>
#import <stdio.h>

static KFPose *Pose(NSArray<NSNumber *> *values, MTEasing easing, MTAddedMotion motion) {
  return [[KFPose alloc] initWithValues:values authored:YES easing:easing addedMotion:motion];
}

// Enum fields are archived at integer width, so validation has to reject values
// that would only look valid after narrowing.
@interface EnumCoder : NSCoder
@property NSInteger easing;
@property NSInteger motion;
@end
@implementation EnumCoder
- (NSInteger)decodeIntegerForKey:(NSString *)key { return [key isEqualToString:@"easing"] ? self.easing : self.motion; }
- (BOOL)decodeBoolForKey:(NSString *)key { return YES; }
- (BOOL)containsValueForKey:(NSString *)key { return NO; }
- (id)decodeObjectOfClasses:(NSSet *)classes forKey:(NSString *)key { return @[@50]; }
@end

static void testValidation(void) {
  assert(!Pose(@[], MTEasingSmooth, MTAddedMotionNone));
  assert(!Pose(@[@(NAN)], MTEasingSmooth, MTAddedMotionNone));
  assert(!Pose(@[@0, @(INFINITY)], MTEasingSmooth, MTAddedMotionNone));
  assert(!Pose((id) @[@"x"], MTEasingSmooth, MTAddedMotionNone));
  assert(!Pose(@[@1], (MTEasing)99, MTAddedMotionNone));
  assert(!Pose(@[@1], MTEasingSmooth, (MTAddedMotion)99));
  assert(![Pose(@[@1], MTEasingSmooth, MTAddedMotionNone) poseByReplacingTiming:nil]);
  // A lane's component count is fixed: a differing count is a caller bug.
  KFPose *pair = Pose(@[@1, @2], MTEasingSmooth, MTAddedMotionNone);
  assert(![pair poseByReplacingValues:@[@1] authored:YES easing:MTEasingSmooth
                          addedMotion:MTAddedMotionNone timing:[KFPoseTiming new]]);
  EnumCoder *coder = [EnumCoder new];
  coder.easing = MTEasingSmooth; coder.motion = MTAddedMotionNone;
  assert([[KFPose alloc] initWithCoder:coder]);
  coder.easing = ((NSInteger)1 << 32) + MTEasingSmooth;
  assert(![[KFPose alloc] initWithCoder:coder]);
  coder.easing = MTEasingSmooth; coder.motion = ((NSInteger)1 << 32) + MTAddedMotionNone;
  assert(![[KFPose alloc] initWithCoder:coder]);
}

static void testSecureCoding(void) {
  KFPoseTiming *timing = [[[KFPoseTiming alloc] initWithDuration:0.8 available:YES amount:2 speed:3]
      timingByReplacingLinkID:@"pair"];
  timing = [timing timingByReplacingMotionSeed:123 linked:NO componentMask:2];
  KFPose *pose = [Pose(@[@360, @720, @(-450)], MTEasingEaseIn, MTAddedMotionWave) poseByReplacingTiming:timing];
  NSError *error = nil;
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:pose requiringSecureCoding:YES error:&error];
  assert(data && !error);
  KFPose *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:KFPose.class fromData:data error:&error];
  assert(decoded && !error && [decoded isEqual:pose] && decoded.hash == pose.hash);
  assert([decoded.values isEqualToArray:(@[@360, @720, @(-450)])]);
  assert(decoded.value == 360 && decoded.authored);
  assert(decoded.easing == MTEasingEaseIn && decoded.addedMotion == MTAddedMotionWave);
  assert([decoded.timing isEqual:timing]);
  assert([pose copy] == pose);
  assert(![pose isEqual:Pose(@[@360, @720, @(-450)], MTEasingEaseIn, MTAddedMotionWave)]);
  NSData *foreign = [NSKeyedArchiver archivedDataWithRootObject:@{@"values" : @[@1]}
                                          requiringSecureCoding:YES error:nil];
  assert(![NSKeyedUnarchiver unarchivedObjectOfClass:KFPose.class fromData:foreign error:nil]);
}

static void testInterpolation(void) {
  KFPoseTiming *linked = [[KFPoseTiming new] timingByReplacingLinkID:@"pair"];
  KFPose *left = [Pose(@[@0, @10], MTEasingLinear, MTAddedMotionWave) poseByReplacingTiming:linked];
  KFPose *right = [Pose(@[@100, @50], MTEasingEaseOut, MTAddedMotionWiggle) poseByReplacingTiming:linked];
  KFPose *quarter = (KFPose *)[left interpolateBetween:right withWeight:0.25];
  assert(quarter.values[0].doubleValue == 25 && quarter.values[1].doubleValue == 20);
  // A value between two keys belongs to neither link group, and keeps the
  // metadata of the key it is leaving.
  assert(quarter.timing.linkID.length == 0);
  assert(quarter.easing == MTEasingLinear && quarter.addedMotion == MTAddedMotionWave);
  KFPose *end = (KFPose *)[left interpolateBetween:right withWeight:1];
  assert(end.easing == MTEasingEaseOut && end.addedMotion == MTAddedMotionWiggle);
  assert([end.timing.linkID isEqualToString:@"pair"]);
  // Weights are clamped, and a mismatched or foreign right value is ignored.
  assert([(KFPose *)[left interpolateBetween:right withWeight:-1] isEqual:left]);
  assert([(KFPose *)[left interpolateBetween:right withWeight:(float)NAN] isEqual:left]);
  assert([(KFPose *)[left interpolateBetween:Pose(@[@1], MTEasingSmooth, MTAddedMotionNone) withWeight:0.5] isEqual:left]);
  assert([(KFPose *)[left interpolateBetween:(id) @"other" withWeight:0.5] isEqual:left]);
  // An unauthored pose becomes authored as soon as either side is.
  KFPose *unauthored = [[KFPose alloc] initWithValues:@[@0, @0] authored:NO
                                               easing:MTEasingSmooth addedMotion:MTAddedMotionNone];
  assert([(KFPose *)[unauthored interpolateBetween:right withWeight:0.5] authored]);
}

static void testLaneDefaults(void) {
  for (KFPropertyLane *lane in KFPropertyLanes()) {
    id<KFPropertyPose> pose = lane.defaultPose;
    assert([pose isKindOfClass:KFPose.class]);
    assert(pose.values.count == lane.componentCount && !pose.authored);
    assert(pose.easing == MTEasingSmooth && pose.addedMotion == MTAddedMotionNone);
    assert(pose.value == lane.defaultValue);
  }
}

int main(void) {
  @autoreleasepool {
    KFTestRegisterLanes(); testValidation(); testSecureCoding(); testInterpolation(); testLaneDefaults(); }
  puts("Pose: validation, secure coding, interpolation metadata and lane defaults passed");
  return 0;
}
