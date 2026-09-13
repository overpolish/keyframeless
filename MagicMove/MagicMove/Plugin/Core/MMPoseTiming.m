/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMPoseTiming.h"
#import <math.h>
@implementation MMPoseTiming
+ (BOOL)supportsSecureCoding {
  return YES;
}
- (instancetype)init {
  return [self initWithDuration:1.2 available:NO amount:1 speed:1];
}
- (instancetype)initWithDuration:(double)d
                       available:(BOOL)a
                          amount:(double)m
                           speed:(double)s {
  if (!isfinite(d) || d < 0 || !isfinite(m) || m < 0 || !isfinite(s) || s <= 0)
    return nil;
  if ((self = [super init])) {
    _duration = d;
    _available = a;
    _amount = m;
    _speed = s;
  }
  return self;
}
- (instancetype)initWithCoder:(NSCoder *)c {
  return [self initWithDuration:[c decodeDoubleForKey:@"duration"]
                      available:[c decodeBoolForKey:@"available"]
                         amount:[c decodeDoubleForKey:@"amount"]
                          speed:[c decodeDoubleForKey:@"speed"]];
}
- (void)encodeWithCoder:(NSCoder *)c {
  [c encodeDouble:_duration forKey:@"duration"];
  [c encodeBool:_available forKey:@"available"];
  [c encodeDouble:_amount forKey:@"amount"];
  [c encodeDouble:_speed forKey:@"speed"];
}
- (id)copyWithZone:(NSZone *)zone {
  return self;
}
- (BOOL)isEqual:(id)obj {
  if (![obj isKindOfClass:MMPoseTiming.class])
    return NO;
  MMPoseTiming *other = obj;
  return _duration == other.duration && _available == other.available &&
         _amount == other.amount && _speed == other.speed;
}
- (NSUInteger)hash {
  return @(_duration).hash ^ @(_amount).hash ^ @(_speed).hash ^ _available;
}
@end
