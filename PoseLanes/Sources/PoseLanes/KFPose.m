/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFPose.h"
#import <math.h>

@implementation KFPose
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithValues:(NSArray<NSNumber *> *)values authored:(BOOL)authored
                        easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion {
  if(!values.count || easing<MTEasingSmooth || easing>MTEasingEaseOut ||
      motion<MTAddedMotionNone || motion>MTAddedMotionHandheld) return nil;
  for(id value in values)
    if(![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) return nil;
  if((self=[super init])) {
    _values=[values copy]; _authored=authored; _easing=easing; _addedMotion=motion;
    _timing=[KFPoseTiming new];
  }
  return self;
}
- (double)value { return _values.firstObject.doubleValue; }
- (KFPose *)poseByReplacingTiming:(KFPoseTiming *)timing {
  if(!timing) return nil;
  KFPose *pose=[[KFPose alloc] initWithValues:_values authored:_authored easing:_easing addedMotion:_addedMotion];
  pose->_timing=timing; return pose;
}
- (id<KFPropertyPose>)poseByReplacingValues:(NSArray<NSNumber *> *)values authored:(BOOL)authored
    easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion timing:(KFPoseTiming *)timing {
  // A lane's component count is fixed, so a differing count is a caller bug.
  if(values.count!=_values.count) return nil;
  return [[[KFPose alloc] initWithValues:values authored:authored easing:easing addedMotion:motion]
      poseByReplacingTiming:timing];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
  // Validate at archive integer width before narrowing to the engine enums.
  NSInteger easing=[coder decodeIntegerForKey:@"easing"], motion=[coder decodeIntegerForKey:@"motion"];
  if(easing<MTEasingSmooth || easing>MTEasingEaseOut ||
      motion<MTAddedMotionNone || motion>MTAddedMotionHandheld) return nil;
  NSSet *classes=[NSSet setWithObjects:NSArray.class,NSNumber.class,nil];
  NSArray *values=[coder decodeObjectOfClasses:classes forKey:@"values"];
  if(![values isKindOfClass:NSArray.class]) return nil;
  self=[self initWithValues:values authored:[coder decodeBoolForKey:@"authored"]
      easing:(MTEasing)easing addedMotion:(MTAddedMotion)motion];
  if(self && [coder containsValueForKey:@"timing"]) {
    _timing=[coder decodeObjectOfClass:KFPoseTiming.class forKey:@"timing"];
    if(!_timing) return nil;
  }
  return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeObject:_values forKey:@"values"];
  [coder encodeBool:_authored forKey:@"authored"];
  [coder encodeInteger:_easing forKey:@"easing"];
  [coder encodeInteger:_addedMotion forKey:@"motion"];
  [coder encodeObject:_timing forKey:@"timing"];
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)other {
  if(![other isKindOfClass:KFPose.class]) return NO;
  KFPose *pose=other;
  return [_values isEqualToArray:pose.values] && _authored==pose.authored &&
         _easing==pose.easing && _addedMotion==pose.addedMotion && [_timing isEqual:pose.timing];
}
- (NSUInteger)hash {
  return _values.hash ^ _timing.hash ^ (NSUInteger)_authored ^ ((NSUInteger)_easing<<8) ^ ((NSUInteger)_addedMotion<<16);
}
- (NSObject<NSSecureCoding, NSCopying> *)interpolateBetween:(NSObject<NSSecureCoding, NSCopying> *)rightValue
                                                 withWeight:(float)weight {
  if(![rightValue isKindOfClass:KFPose.class] || !isfinite(weight)) return self;
  KFPose *right=(KFPose *)rightValue;
  if(right.values.count!=_values.count) return self;
  double w=fmax(0,fmin(1,weight));
  KFPose *metadata=w>=1 ? right:self;
  NSMutableArray *values=[NSMutableArray arrayWithCapacity:_values.count];
  for(NSUInteger i=0;i<_values.count;i++) {
    double from=_values[i].doubleValue, to=right.values[i].doubleValue;
    [values addObject:@(from+(to-from)*w)];
  }
  // A value between two keys belongs to neither link group.
  return [[[KFPose alloc] initWithValues:values authored:_authored||right.authored
      easing:metadata.easing addedMotion:metadata.addedMotion]
      poseByReplacingTiming:(w>0 && w<1) ? [metadata.timing timingByReplacingLinkID:@""]:metadata.timing];
}
@end
