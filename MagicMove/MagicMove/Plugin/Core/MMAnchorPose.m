/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMAnchorPose.h"
#import "Constants.h"
#import <math.h>
@implementation MMAnchorPose
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithX:(double)x y:(double)y authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion {
  if(!isfinite(x)||!isfinite(y)||easing<MTEasingSmooth||easing>MTEasingEaseOut||motion<MTAddedMotionNone||motion>MTAddedMotionHandheld) return nil;
  if((self=[super init])) { _x=x; _y=y; _authored=authored; _easing=easing; _addedMotion=motion; _timing=[MMPoseTiming new]; }
  return self;
}
- (NSArray<NSNumber *> *)values { return @[@(self.x),@(self.y)]; }
- (double)value { return self.x; }
- (MMAnchorPose *)poseByReplacingTiming:(MMPoseTiming *)timing {
  if(!timing) return nil;
  MMAnchorPose *pose=[[MMAnchorPose alloc] initWithX:self.x y:self.y authored:self.authored easing:self.easing addedMotion:self.addedMotion];
  pose->_timing=timing; return pose;
}
- (id<MMPropertyPose>)poseByReplacingValues:(NSArray<NSNumber *> *)values authored:(BOOL)authored easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion timing:(MMPoseTiming *)timing {
  if(values.count!=2) return nil;
  return [[[MMAnchorPose alloc] initWithX:values[0].doubleValue y:values[1].doubleValue authored:authored easing:easing addedMotion:motion] poseByReplacingTiming:timing];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
  NSInteger easing=[coder decodeIntegerForKey:@"easing"], motion=[coder decodeIntegerForKey:@"motion"];
  if(easing<MTEasingSmooth||easing>MTEasingEaseOut||motion<MTAddedMotionNone||motion>MTAddedMotionHandheld) return nil;
  self=[self initWithX:[coder decodeDoubleForKey:@"x"] y:[coder decodeDoubleForKey:@"y"] authored:[coder decodeBoolForKey:@"authored"] easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion];
  if(self && [coder containsValueForKey:@"timing"]) {
    _timing=[coder decodeObjectOfClass:MMPoseTiming.class forKey:@"timing"];
    if(!_timing) return nil;
  }
  return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeDouble:self.x forKey:@"x"]; [coder encodeDouble:self.y forKey:@"y"];
  [coder encodeBool:self.authored forKey:@"authored"]; [coder encodeInteger:self.easing forKey:@"easing"];
  [coder encodeInteger:self.addedMotion forKey:@"motion"]; [coder encodeObject:self.timing forKey:@"timing"];
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)other {
  if(![other isKindOfClass:MMAnchorPose.class]) return NO;
  MMAnchorPose *p=other;
  return self.x==p.x && self.y==p.y && self.authored==p.authored && self.easing==p.easing && self.addedMotion==p.addedMotion && [self.timing isEqual:p.timing];
}
- (NSUInteger)hash { return @(self.x).hash ^ @(self.y).hash ^ self.timing.hash ^ self.authored ^ (self.easing<<8) ^ (self.addedMotion<<16); }
- (NSObject<NSSecureCoding,NSCopying> *)interpolateBetween:(NSObject<NSSecureCoding,NSCopying> *)rightValue withWeight:(float)weight {
  if(![rightValue isKindOfClass:MMAnchorPose.class]||!isfinite(weight)) return self;
  MMAnchorPose *right=(MMAnchorPose *)rightValue; double w=fmax(0,fmin(1,weight));
  MMAnchorPose *metadata=w>=1 ? right:self;
  return [[[MMAnchorPose alloc] initWithX:self.x+(right.x-self.x)*w y:self.y+(right.y-self.y)*w authored:self.authored||right.authored easing:metadata.easing addedMotion:metadata.addedMotion] poseByReplacingTiming:(w>0 && w<1) ? [metadata.timing timingByReplacingLinkID:@""]:metadata.timing];
}
@end
MMPropertyLane *MMAnchorLane(void) {
  static MMPropertyLane *lane; static dispatch_once_t once;
  dispatch_once(&once,^{
    MMAnchorPose *pose=[[MMAnchorPose alloc] initWithX:0 y:0 authored:NO easing:MTEasingSmooth addedMotion:MTAddedMotionNone];
    // Limits define added-motion amplitude, not the editable pixel range.
    lane=[[MMPropertyLane alloc] initWithParameterID:MMAnchorControls cacheTokenID:MMAnchorCacheToken defaultPose:pose minimum:-1000 maximum:1000 boundsValues:NO];
  }); return lane;
}
