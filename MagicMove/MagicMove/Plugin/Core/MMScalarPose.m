/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMScalarPose.h"
#import "Constants.h"
#import <math.h>

@implementation MMScalarPose
- (NSArray<NSNumber *> *)values { return @[@(self.value)]; }
- (id<MMPropertyPose>)poseByReplacingValues:(NSArray<NSNumber *> *)values authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion timing:(MMPoseTiming *)timing {
  if(values.count!=1) return nil;
  return [[[MMScalarPose alloc] initWithValue:values[0].doubleValue authored:authored easing:easing addedMotion:motion] poseByReplacingTiming:timing];
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithValue:(double)value authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion {
  if(!isfinite(value) || easing<MTEasingSmooth || easing>MTEasingEaseOut || motion<MTAddedMotionNone || motion>MTAddedMotionHandheld) return nil;
  if((self=[super init])) { _value=value; _authored=authored; _easing=easing; _addedMotion=motion; _timing=[MMPoseTiming new]; }
  return self;
}
- (MMScalarPose *)poseByReplacingTiming:(MMPoseTiming *)timing {
  if(!timing) return nil;
  MMScalarPose *pose=[[MMScalarPose alloc] initWithValue:self.value authored:self.authored easing:self.easing addedMotion:self.addedMotion];
  pose->_timing=timing; return pose;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
  NSInteger easing=[coder decodeIntegerForKey:@"easing"];
  NSInteger motion=[coder decodeIntegerForKey:@"motion"];
  // Validate at archive integer width before narrowing to the engine enums.
  if(easing<MTEasingSmooth || easing>MTEasingEaseOut ||
      motion<MTAddedMotionNone || motion>MTAddedMotionHandheld) return nil;
  self=[self initWithValue:[coder decodeDoubleForKey:@"value"]
      authored:[coder decodeBoolForKey:@"authored"]
      easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion];
  if(self && [coder containsValueForKey:@"timing"]) {
    _timing=[coder decodeObjectOfClass:MMPoseTiming.class forKey:@"timing"];
    if(!_timing) return nil;
  }
  return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeDouble:self.value forKey:@"value"]; [coder encodeBool:self.authored forKey:@"authored"];
  [coder encodeInteger:self.easing forKey:@"easing"]; [coder encodeInteger:self.addedMotion forKey:@"motion"];
  [coder encodeObject:self.timing forKey:@"timing"];
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)other {
  if(![other isKindOfClass:MMScalarPose.class]) return NO;
  MMScalarPose *p=other;
  return self.value==p.value && self.authored==p.authored && self.easing==p.easing && self.addedMotion==p.addedMotion && [self.timing isEqual:p.timing];
}
- (NSUInteger)hash { return @(self.value).hash ^ self.timing.hash ^ self.authored ^ (self.easing<<8) ^ (self.addedMotion<<16); }
- (NSObject<NSSecureCoding, NSCopying> *)interpolateBetween:(NSObject<NSSecureCoding, NSCopying> *)rightValue withWeight:(float)weight {
  if(![rightValue isKindOfClass:MMScalarPose.class] || !isfinite(weight)) return self;
  MMScalarPose *right=(MMScalarPose *)rightValue; double w=fmax(0,fmin(1,weight));
  MMScalarPose *metadata=w>=1 ? right:self;
  return [[[MMScalarPose alloc] initWithValue:self.value+(right.value-self.value)*w authored:self.authored||right.authored easing:metadata.easing addedMotion:metadata.addedMotion] poseByReplacingTiming:(w>0 && w<1) ? [metadata.timing timingByReplacingLinkID:@""]:metadata.timing];
}
@end

MMPropertyLane *MMOpacityLane(void) {
  static MMPropertyLane *lane; static dispatch_once_t once;
  dispatch_once(&once,^{ lane=[[MMPropertyLane alloc] initWithParameterID:MMOpacityControls cacheTokenID:MMOpacityCacheToken defaultPose:[[MMScalarPose alloc] initWithValue:100 authored:NO easing:MTEasingSmooth addedMotion:MTAddedMotionNone] minimum:0 maximum:100 boundsValues:YES]; }); return lane;
}

MMPropertyLane *MMBlurLane(void) {
  static MMPropertyLane *lane; static dispatch_once_t once;
  dispatch_once(&once,^{ lane=[[MMPropertyLane alloc] initWithParameterID:MMBlurControls cacheTokenID:MMBlurCacheToken defaultPose:[[MMScalarPose alloc] initWithValue:0 authored:NO easing:MTEasingSmooth addedMotion:MTAddedMotionNone] minimum:0 maximum:100 boundsValues:YES]; }); return lane;
}
