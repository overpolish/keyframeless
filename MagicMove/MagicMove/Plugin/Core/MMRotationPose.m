/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMRotationPose.h"
#import "Constants.h"
#import <math.h>
@implementation MMRotationPose
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithX:(double)x y:(double)y z:(double)z authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion {
  if(!isfinite(x)||!isfinite(y)||!isfinite(z)||easing<MTEasingSmooth||easing>MTEasingEaseOut||motion<MTAddedMotionNone||motion>MTAddedMotionHandheld) return nil;
  if((self=[super init])) { _x=x; _y=y; _z=z; _authored=authored; _easing=easing; _addedMotion=motion; _timing=[MMPoseTiming new]; }
  return self;
}
- (NSArray<NSNumber *> *)values { return @[@(self.x),@(self.y),@(self.z)]; }
- (double)value { return self.x; }
- (MMRotationPose *)poseByReplacingTiming:(MMPoseTiming *)timing {
  if(!timing) return nil;
  MMRotationPose *pose=[[MMRotationPose alloc] initWithX:self.x y:self.y z:self.z authored:self.authored easing:self.easing addedMotion:self.addedMotion];
  pose->_timing=timing; return pose;
}
- (id<MMPropertyPose>)poseByReplacingValues:(NSArray<NSNumber *> *)values authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion timing:(MMPoseTiming *)timing {
  if(values.count!=3) return nil;
  return [[[MMRotationPose alloc] initWithX:values[0].doubleValue y:values[1].doubleValue z:values[2].doubleValue authored:authored easing:easing addedMotion:motion] poseByReplacingTiming:timing];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
  NSInteger easing=[coder decodeIntegerForKey:@"easing"], motion=[coder decodeIntegerForKey:@"motion"];
  if(easing<MTEasingSmooth||easing>MTEasingEaseOut||motion<MTAddedMotionNone||motion>MTAddedMotionHandheld) return nil;
  self=[self initWithX:[coder decodeDoubleForKey:@"x"] y:[coder decodeDoubleForKey:@"y"] z:[coder decodeDoubleForKey:@"z"] authored:[coder decodeBoolForKey:@"authored"] easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion];
  if(self && [coder containsValueForKey:@"timing"]) {
    _timing=[coder decodeObjectOfClass:MMPoseTiming.class forKey:@"timing"];
    if(!_timing) return nil;
  }
  return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeDouble:self.x forKey:@"x"]; [coder encodeDouble:self.y forKey:@"y"]; [coder encodeDouble:self.z forKey:@"z"];
  [coder encodeBool:self.authored forKey:@"authored"]; [coder encodeInteger:self.easing forKey:@"easing"];
  [coder encodeInteger:self.addedMotion forKey:@"motion"]; [coder encodeObject:self.timing forKey:@"timing"];
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)other {
  if(![other isKindOfClass:MMRotationPose.class]) return NO;
  MMRotationPose *p=other;
  return self.x==p.x && self.y==p.y && self.z==p.z && self.authored==p.authored && self.easing==p.easing && self.addedMotion==p.addedMotion && [self.timing isEqual:p.timing];
}
- (NSUInteger)hash { return @(self.x).hash ^ @(self.y).hash ^ @(self.z).hash ^ self.timing.hash ^ self.authored ^ (self.easing<<8) ^ (self.addedMotion<<16); }
- (NSObject<NSSecureCoding,NSCopying> *)interpolateBetween:(NSObject<NSSecureCoding,NSCopying> *)rightValue withWeight:(float)weight {
  if(![rightValue isKindOfClass:MMRotationPose.class]||!isfinite(weight)) return self;
  MMRotationPose *right=(MMRotationPose *)rightValue; double w=fmax(0,fmin(1,weight));
  MMRotationPose *metadata=w>=1 ? right:self;
  return [[[MMRotationPose alloc] initWithX:self.x+(right.x-self.x)*w y:self.y+(right.y-self.y)*w z:self.z+(right.z-self.z)*w authored:self.authored||right.authored easing:metadata.easing addedMotion:metadata.addedMotion] poseByReplacingTiming:metadata.timing];
}
@end
MMPropertyLane *MMRotationLane(void) {
  static MMPropertyLane *lane; static dispatch_once_t once;
  dispatch_once(&once,^{
    MMRotationPose *pose=[[MMRotationPose alloc] initWithX:0 y:0 z:0 authored:NO easing:MTEasingSmooth addedMotion:MTAddedMotionNone];
    // Limits define the added-motion amplitude, not the permitted turn count.
    lane=[[MMPropertyLane alloc] initWithParameterID:MMRotationControls cacheTokenID:MMRotationCacheToken defaultPose:pose minimum:-180 maximum:180 boundsValues:NO];
  }); return lane;
}
